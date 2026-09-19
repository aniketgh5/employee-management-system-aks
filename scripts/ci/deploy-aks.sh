#!/usr/bin/env bash
set -Eeuo pipefail
: "${AKS_RESOURCE_GROUP:?}" "${AKS_CLUSTER_NAME:?}" "${MANIFEST_DIR:?}"
: "${BACKEND_REF:?}" "${FRONTEND_REF:?}" "${KUBECONFIG:?}"
namespace=employee-app

cleanup() { rm -f "$KUBECONFIG"; }
diagnostics() {
  local code=$?
  trap - ERR
  echo "Deployment failed; collecting pod status and events (no Secret values)."
  kubectl get pods,deployments,ingress -n "$namespace" || true
  kubectl get events -n "$namespace" --sort-by=.lastTimestamp || true
  exit "$code"
}
trap cleanup EXIT
trap diagnostics ERR

az aks get-credentials --resource-group "$AKS_RESOURCE_GROUP" \
  --name "$AKS_CLUSTER_NAME" --file "$KUBECONFIG" --overwrite-existing
# Supports both the current local-account cluster and Entra-enabled AKS.
if kubectl config view -o json | python3 -c \
  'import json,sys; sys.exit(not any(u.get("user", {}).get("exec") for u in json.load(sys.stdin).get("users", [])))'; then
  if ! command -v kubelogin >/dev/null; then
    tools_dir=$(mktemp -d)
    az aks install-cli --install-location "$tools_dir/kubectl" \
      --kubelogin-install-location "$tools_dir/kubelogin"
    export PATH="$tools_dir:$PATH"
  fi
  kubelogin convert-kubeconfig -l azurecli
fi

kubectl get ingressclass webapprouting.kubernetes.azure.com >/dev/null
kubectl get crd clusterissuers.cert-manager.io >/dev/null
# Preserve the credentials already used by the PostgreSQL PVC. Changing a
# Secret does not change the password inside an initialized PostgreSQL database.
kubectl get secret employee-secret -n "$namespace" -o name >/dev/null
kubectl apply --dry-run=server -f "$MANIFEST_DIR/rendered.yaml" >/dev/null
kubectl apply -f "$MANIFEST_DIR/rendered.yaml"
for deployment in postgresql backend frontend; do
  kubectl rollout status "deployment/$deployment" -n "$namespace" --timeout=300s
done

test "$(kubectl get deployment backend -n "$namespace" -o jsonpath='{.spec.template.spec.containers[0].image}')" = "$BACKEND_REF"
test "$(kubectl get deployment frontend -n "$namespace" -o jsonpath='{.spec.template.spec.containers[0].image}')" = "$FRONTEND_REF"

# Use the hostless HTTP route, so deployment does not depend on DNS/TLS setup.
endpoint=''
for attempt in {1..30}; do
  endpoint=$(kubectl get ingress employee-ingress -n "$namespace" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  if [[ -n "$endpoint" ]]; then break; fi
  sleep 5
done
if [[ -z "$endpoint" ]]; then
  echo 'Ingress did not receive a public IP.' >&2
  exit 1
fi
for path in / /health /health/db /api/employees; do
  code=$(curl --silent --show-error --fail --retry 12 --retry-all-errors \
    --retry-delay 5 --connect-timeout 10 --max-time 20 \
    --output /dev/null --write-out '%{http_code}' "http://$endpoint$path")
  test "$code" = 200
  echo "HTTP $code: $path"
done
kubectl get pods -n "$namespace"
echo "Application URL: http://$endpoint"
