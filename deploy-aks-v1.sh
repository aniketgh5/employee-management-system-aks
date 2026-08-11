#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# EMPLOYEE MANAGEMENT SYSTEM - AKS LAB v1
# Local Docker Build -> ACR -> AKS
# ============================================================

RG="rg-employee-app-v1"
LOCATION="eastus"
AKS="aks-employee-v1"

# Globally unique ACR name
ACR="acremployeev1$(date +%m%d%H%M%S)"

# Keep these aligned with existing aks/ manifests
NAMESPACE="employee-app"
INGRESS_NAMESPACE="ingress-nginx"

IMAGE_TAG="v1"
APP_HOST="employee.example.com"

BACKEND_REPO="employee-api-v1"
FRONTEND_REPO="employee-frontend-v1"

echo
echo "============================================================"
echo " Employee Management System - AKS v1"
echo "============================================================"
echo "RG        : $RG"
echo "AKS       : $AKS"
echo "ACR       : $ACR"
echo "Namespace : $NAMESPACE"
echo "============================================================"

# ============================================================
# 0. PRE-CHECKS
# ============================================================

echo
echo ">>> 0. PRE-CHECKS"

command -v az >/dev/null 2>&1 || {
    echo "ERROR: Azure CLI not installed"
    exit 1
}

command -v kubectl >/dev/null 2>&1 || {
    echo "ERROR: kubectl not installed"
    exit 1
}

command -v helm >/dev/null 2>&1 || {
    echo "ERROR: Helm not installed"
    exit 1
}

command -v docker >/dev/null 2>&1 || {
    echo "ERROR: Docker not installed"
    exit 1
}

docker info >/dev/null 2>&1 || {
    echo "ERROR: Docker daemon is not running"
    exit 1
}

az account show >/dev/null 2>&1 || {
    echo "ERROR: Run az login first"
    exit 1
}

echo "Azure CLI : OK"
echo "kubectl   : OK"
echo "Helm      : OK"
echo "Docker    : OK"

# ============================================================
# 1. RESOURCE GROUP
# ============================================================

echo
echo ">>> 1. CREATING RESOURCE GROUP"

az group create \
    --name "$RG" \
    --location "$LOCATION" \
    -o table

# ============================================================
# 2. ACR
# ============================================================

echo
echo ">>> 2. CREATING ACR"

az acr create \
    --resource-group "$RG" \
    --name "$ACR" \
    --sku Basic \
    --admin-enabled false \
    -o table

ACR_LOGIN_SERVER=$(az acr show \
    --resource-group "$RG" \
    --name "$ACR" \
    --query loginServer \
    -o tsv)

echo
echo "ACR LOGIN SERVER:"
echo "$ACR_LOGIN_SERVER"

# ============================================================
# 3. AKS
# ============================================================

echo
echo ">>> 3. CREATING AKS"

az aks create \
    --resource-group "$RG" \
    --name "$AKS" \
    --location "$LOCATION" \
    --node-count 2 \
    --node-vm-size Standard_D2ds_v7 \
    --network-plugin azure \
    --network-plugin-mode overlay \
    --load-balancer-sku standard \
    --enable-managed-identity \
    --attach-acr "$ACR" \
    --generate-ssh-keys \
    -o table

# ============================================================
# 4. KUBECTL
# ============================================================

echo
echo ">>> 4. CONFIGURING KUBECTL"

az aks get-credentials \
    --resource-group "$RG" \
    --name "$AKS" \
    --overwrite-existing

kubectl get nodes -o wide

# ============================================================
# 5. ATTACH ACR
# ============================================================

echo
echo ">>> 5. ATTACHING ACR TO AKS"

az aks update \
    --resource-group "$RG" \
    --name "$AKS" \
    --attach-acr "$ACR" \
    -o none

echo "ACR attached successfully."

# ============================================================
# 6. CHECK DOCKERFILES
# ============================================================

echo
echo ">>> 6. CHECKING APPLICATION FILES"

test -f backend/Dockerfile || {
    echo "ERROR: backend/Dockerfile not found"
    exit 1
}

test -f frontend/Dockerfile || {
    echo "ERROR: frontend/Dockerfile not found"
    exit 1
}

test -f frontend/nginx.aks.conf || {
    echo "ERROR: frontend/nginx.aks.conf not found"
    exit 1
}

# Ensure nginx config is included in Docker context
if [ -f frontend/.dockerignore ]; then
    sed -i '/^nginx\.aks\.conf$/d' frontend/.dockerignore
fi

echo "Application build files OK."

# ============================================================
# 7. LOGIN TO ACR
# ============================================================

echo
echo ">>> 7. DOCKER LOGIN TO ACR"

az acr login --name "$ACR"

# ============================================================
# 8. BACKEND IMAGE
# ============================================================

echo
echo ">>> 8. BUILDING BACKEND IMAGE"

BACKEND_IMAGE="${ACR_LOGIN_SERVER}/${BACKEND_REPO}:${IMAGE_TAG}"

echo "IMAGE: $BACKEND_IMAGE"

docker build \
    -t "$BACKEND_IMAGE" \
    -f backend/Dockerfile \
    backend

echo
echo ">>> PUSHING BACKEND IMAGE"

docker push "$BACKEND_IMAGE"

# ============================================================
# 9. FRONTEND IMAGE
# ============================================================

echo
echo ">>> 9. BUILDING FRONTEND IMAGE"

FRONTEND_IMAGE="${ACR_LOGIN_SERVER}/${FRONTEND_REPO}:${IMAGE_TAG}"

echo "IMAGE: $FRONTEND_IMAGE"

docker build \
    -t "$FRONTEND_IMAGE" \
    -f frontend/Dockerfile \
    frontend

echo
echo ">>> PUSHING FRONTEND IMAGE"

docker push "$FRONTEND_IMAGE"

# ============================================================
# 10. VERIFY ACR
# ============================================================

echo
echo ">>> 10. VERIFYING ACR IMAGES"

echo
echo "BACKEND TAGS:"
az acr repository show-tags \
    --name "$ACR" \
    --repository "$BACKEND_REPO" \
    -o table

echo
echo "FRONTEND TAGS:"
az acr repository show-tags \
    --name "$ACR" \
    --repository "$FRONTEND_REPO" \
    -o table

# ============================================================
# 11. UPDATE KUSTOMIZATION
# ============================================================

echo
echo ">>> 11. UPDATING KUSTOMIZATION"

python3 - "$ACR_LOGIN_SERVER" "$IMAGE_TAG" "$BACKEND_REPO" "$FRONTEND_REPO" <<'PY'
import sys
import re
from pathlib import Path

acr = sys.argv[1]
tag = sys.argv[2]
backend_repo = sys.argv[3]
frontend_repo = sys.argv[4]

path = Path("aks/kustomization.yaml")

if not path.exists():
    raise SystemExit("ERROR: aks/kustomization.yaml not found")

text = path.read_text()

# Backend
text = re.sub(
    r'(- name:\s*employee-backend-image\s*\n\s*newName:\s*)[^\n]+',
    rf'\1{acr}/{backend_repo}',
    text
)

text = re.sub(
    r'(name:\s*employee-backend-image\s*\n\s*newName:[^\n]+\n\s*newTag:\s*)["\']?.*?["\']?$',
    rf'\1"{tag}"',
    text,
    flags=re.MULTILINE
)

# Frontend
text = re.sub(
    r'(- name:\s*employee-frontend-image\s*\n\s*newName:\s*)[^\n]+',
    rf'\1{acr}/{frontend_repo}',
    text
)

text = re.sub(
    r'(name:\s*employee-frontend-image\s*\n\s*newName:[^\n]+\n\s*newTag:\s*)["\']?.*?["\']?$',
    rf'\1"{tag}"',
    text,
    flags=re.MULTILINE
)

path.write_text(text)
PY

echo
echo "KUSTOMIZATION IMAGES:"
grep -n -A3 "employee-backend-image" aks/kustomization.yaml || true
grep -n -A3 "employee-frontend-image" aks/kustomization.yaml || true

# ============================================================
# 12. DATABASE PASSWORD
# ============================================================

echo
echo ">>> 12. PREPARING DATABASE SECRET"

if grep -q "REPLACE_ME_BEFORE_APPLYING" aks/secret.yaml; then
    sed -i \
        's/REPLACE_ME_BEFORE_APPLYING/Employee@2026v1/g' \
        aks/secret.yaml
fi

grep -n 'DATABASE_' aks/secret.yaml

# ============================================================
# 13. POSTGRES SECURITY
# ============================================================

echo
echo ">>> 13. PREPARING POSTGRES"

if grep -q "allowPrivilegeEscalation" aks/database/deployment.yaml; then

    sed -i \
        '/^[[:space:]]*allowPrivilegeEscalation:/d' \
        aks/database/deployment.yaml

    sed -i \
        '/^[[:space:]]*capabilities:$/d' \
        aks/database/deployment.yaml

    sed -i \
        '/^[[:space:]]*drop: \["ALL"\]$/d' \
        aks/database/deployment.yaml

fi

# ============================================================
# 14. KUSTOMIZE VALIDATION
# ============================================================

echo
echo ">>> 14. KUSTOMIZE VALIDATION"

kubectl kustomize aks/ >/tmp/employee-aks-v1.yaml

echo
echo "DEPLOYMENT IMAGES:"
grep -n "image:" /tmp/employee-aks-v1.yaml

# ============================================================
# 15. SERVER DRY RUN
# ============================================================

echo
echo ">>> 15. SERVER DRY RUN"

kubectl apply -k aks/ --dry-run=server

# ============================================================
# 16. DEPLOY APPLICATION
# ============================================================

echo
echo ">>> 16. DEPLOYING APPLICATION"

kubectl apply -k aks/

# ============================================================
# 17. POSTGRES
# ============================================================

echo
echo ">>> 17. WAITING FOR POSTGRES"

kubectl rollout status \
    deployment/postgresql \
    -n "$NAMESPACE" \
    --timeout=180s

# ============================================================
# 18. BACKEND
# ============================================================

echo
echo ">>> 18. WAITING FOR BACKEND"

kubectl rollout status \
    deployment/backend \
    -n "$NAMESPACE" \
    --timeout=180s

# ============================================================
# 19. FRONTEND
# ============================================================

echo
echo ">>> 19. WAITING FOR FRONTEND"

kubectl rollout status \
    deployment/frontend \
    -n "$NAMESPACE" \
    --timeout=180s

# ============================================================
# 20. NGINX INGRESS
# ============================================================

echo
echo ">>> 20. INSTALLING NGINX INGRESS"

helm repo add ingress-nginx \
    https://kubernetes.github.io/ingress-nginx \
    2>/dev/null || true

helm repo update

helm upgrade --install ingress-nginx-v1 \
    ingress-nginx/ingress-nginx \
    --namespace "$INGRESS_NAMESPACE" \
    --create-namespace \
    --set controller.service.type=LoadBalancer \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz

# ============================================================
# 21. WAIT FOR INGRESS
# ============================================================

echo
echo ">>> 21. WAITING FOR NGINX INGRESS"

kubectl rollout status \
    deployment/ingress-nginx-v1-controller \
    -n "$INGRESS_NAMESPACE" \
    --timeout=180s

# ============================================================
# 22. APPLY INGRESS
# ============================================================

echo
echo ">>> 22. APPLYING APPLICATION INGRESS"

kubectl apply -k aks/

# ============================================================
# 23. PUBLIC IP
# ============================================================

echo
echo ">>> 23. WAITING FOR PUBLIC IP"

PUBLIC_IP=""

for i in {1..30}; do

    PUBLIC_IP=$(kubectl get svc \
        ingress-nginx-v1-controller \
        -n "$INGRESS_NAMESPACE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' \
        2>/dev/null || true)

    if [ -n "$PUBLIC_IP" ]; then
        break
    fi

    echo "Waiting for Public IP... $i/30"
    sleep 10

done

if [ -z "$PUBLIC_IP" ]; then
    echo "ERROR: Public IP was not assigned."
    kubectl get svc -n "$INGRESS_NAMESPACE"
    exit 1
fi

echo
echo "PUBLIC IP:"
echo "$PUBLIC_IP"

# ============================================================
# 24. APPLICATION STATUS
# ============================================================

echo
echo ">>> 24. APPLICATION STATUS"

kubectl get pods \
    -n "$NAMESPACE" \
    -o wide

echo
kubectl get svc \
    -n "$NAMESPACE" \
    -o wide

echo
kubectl get pvc \
    -n "$NAMESPACE"

echo
kubectl get hpa \
    -n "$NAMESPACE"

echo
kubectl get ingress \
    -n "$NAMESPACE" \
    -o wide

# ============================================================
# 25. INGRESS STATUS
# ============================================================

echo
echo ">>> 25. INGRESS STATUS"

kubectl get pods \
    -n "$INGRESS_NAMESPACE" \
    -o wide

echo
kubectl get svc \
    -n "$INGRESS_NAMESPACE" \
    -o wide

# ============================================================
# 26. WAIT FOR AZURE LOAD BALANCER
# ============================================================

echo
echo ">>> 26. WAITING FOR AZURE LOAD BALANCER"

sleep 30

# ============================================================
# 27. HEALTH TEST
# ============================================================

echo
echo ">>> 27. EXTERNAL HEALTH TEST"

curl -v \
    --connect-timeout 10 \
    --max-time 20 \
    -H "Host: $APP_HOST" \
    "http://${PUBLIC_IP}/health"

# ============================================================
# 28. FINAL ENDPOINT TEST
# ============================================================

echo
echo ">>> 28. FINAL ENDPOINT TEST"

for path in "/" "/health" "/docs" "/openapi.json"; do

    echo
    echo "===== $path ====="

    curl -sS \
        --connect-timeout 10 \
        --max-time 20 \
        -o /dev/null \
        -w "HTTP %{http_code}\n" \
        -H "Host: $APP_HOST" \
        "http://${PUBLIC_IP}${path}"

done

# ============================================================
# 29. /etc/hosts
# ============================================================

echo
echo ">>> 29. CONFIGURING LOCAL HOST"

if ! grep -qE "[[:space:]]${APP_HOST}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    echo "${PUBLIC_IP} ${APP_HOST}" | sudo tee -a /etc/hosts >/dev/null
else
    echo "$APP_HOST already exists in /etc/hosts"
fi

# ============================================================
# FINAL
# ============================================================

echo
echo "============================================================"
echo "              DEPLOYMENT SUCCESSFUL"
echo "============================================================"

echo
echo "Resource Group:"
echo "  $RG"

echo
echo "AKS:"
echo "  $AKS"

echo
echo "ACR:"
echo "  $ACR_LOGIN_SERVER"

echo
echo "Public IP:"
echo "  $PUBLIC_IP"

echo
echo "Application:"
echo "  http://${APP_HOST}"

echo
echo "Direct IP:"
echo "  http://${PUBLIC_IP}"

echo
echo "Health:"
echo "  http://${APP_HOST}/health"

echo
echo "Swagger:"
echo "  http://${APP_HOST}/docs"

echo
echo "Frontend:"
echo "  http://${APP_HOST}/"

echo
echo "============================================================"
echo "Useful commands:"
echo "============================================================"

echo "kubectl get pods -n $NAMESPACE -o wide"
echo "kubectl get svc -n $NAMESPACE"
echo "kubectl get ingress -n $NAMESPACE"
echo "kubectl get pods -n $INGRESS_NAMESPACE"
echo "kubectl get svc -n $INGRESS_NAMESPACE"

echo
echo "============================================================"
echo "                    DONE"
echo "============================================================"