# AKS Deployment Guide

Complete, ordered, copy-pasteable procedure for deploying the Employee
Management System to Azure Kubernetes Service. Pairs with
`docs/aks-architecture.md` (concepts/diagrams) and `docs/vm-vs-aks.md`
(comparison with the existing VM deployment).

Every `<PLACEHOLDER>` below must be replaced with a real value. No
subscription IDs, resource names, or credentials are assumed - fill in
your own throughout.

---

## 0. Prerequisites

- Azure CLI (`az`), logged in, with permission to create resource groups, ACR, and AKS.
- `kubectl` (or let `az aks install-cli` install it for you).
- `helm` (for the Ingress controller).
- Docker, to build the two images locally (or let Azure Pipelines do it - see README "CI/CD").
- This repository, with `backend/`, `frontend/`, and `aks/` present.

```bash
az --version
kubectl version --client
helm version
docker --version
```

---

## 1. Azure CLI setup

```bash
# Variables - fill these in once, reuse everywhere below
LOCATION="eastus"                       # pick your region
RESOURCE_GROUP="<RESOURCE_GROUP_NAME>"
ACR_NAME="<ACR_NAME>"                   # must be globally unique, alphanumeric only
AKS_CLUSTER="<AKS_CLUSTER_NAME>"
NODE_COUNT=2

# 1. Login
az login

# 2. List and select the correct subscription
az account list --output table
az account set --subscription "<SUBSCRIPTION_ID_OR_NAME>"

# 3. Create the Resource Group
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
```

---

## 2. Create Azure Container Registry (ACR)

```bash
# 4. Create ACR
az acr create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --sku Basic

# Grab the login server for later steps (e.g. myacrname.azurecr.io)
ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv)
echo "$ACR_LOGIN_SERVER"
```

---

## 3. Create AKS and attach ACR

```bash
# 5. Create AKS
#    - 1 system node pool, sized for a small learning cluster
#    - see docs/aks-architecture.md if you want to add a separate user
#      node pool later (`az aks nodepool add`)
az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_CLUSTER" \
  --node-count "$NODE_COUNT" \
  --node-vm-size Standard_B2s \
  --generate-ssh-keys \
  --enable-managed-identity

# 6. Attach ACR to AKS (grants the cluster's managed identity the
#    "AcrPull" role on the registry - no registry password ever touches
#    a Kubernetes Secret; see README "AKS Image Pull" for why this
#    matters)
az aks update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_CLUSTER" \
  --attach-acr "$ACR_NAME"

# 7. Get credentials (writes/merges into ~/.kube/config)
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_CLUSTER" \
  --overwrite-existing

kubectl get nodes
```

---

## 4. Build, tag, and push the images

Uses the SAME application source as the VM deployment
(`backend/Dockerfile` is untouched; `frontend/Dockerfile` is a new,
AKS-only static-serving image - see `docs/aks-architecture.md`).

```bash
TAG="v1"   # or a git commit SHA / pipeline build id for a real release

# Login to ACR
az acr login --name "$ACR_NAME"

# Build backend
docker build -t "$ACR_LOGIN_SERVER/employee-backend:$TAG" ./backend

# Build frontend
docker build -t "$ACR_LOGIN_SERVER/employee-frontend:$TAG" ./frontend

# Push both
docker push "$ACR_LOGIN_SERVER/employee-backend:$TAG"
docker push "$ACR_LOGIN_SERVER/employee-frontend:$TAG"

# Verify
az acr repository list --name "$ACR_NAME" --output table
az acr repository show-tags --name "$ACR_NAME" --repository employee-backend --output table
az acr repository show-tags --name "$ACR_NAME" --repository employee-frontend --output table
```

---

## 5. Install an Ingress controller (learning version)

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace

# Wait for the controller's public IP to be assigned
kubectl get svc -n ingress-nginx -w
```

Note the `EXTERNAL-IP` once it appears - you'll use it in step 8.

(For the enterprise alternative - AKS "App Routing" add-on or Application
Gateway for Containers - see `docs/aks-architecture.md` section 7. Don't
mix the two approaches.)

---

## 6. Point the manifests at your ACR images

```bash
cd aks
kustomize edit set image \
  employee-backend-image="$ACR_LOGIN_SERVER/employee-backend:$TAG" \
  employee-frontend-image="$ACR_LOGIN_SERVER/employee-frontend:$TAG"
cd ..
```

No `kustomize` binary? Just hand-edit the `images:` section at the
bottom of `aks/kustomization.yaml` instead - replace `<ACR_LOGIN_SERVER>`
and `<TAG>` with your real values.

---

## 7. Set a real database password before applying

`aks/secret.yaml` ships with a placeholder password. Generate the Secret
at apply-time instead of committing real credentials:

```bash
kubectl create namespace employee-app --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic employee-secret \
  --namespace employee-app \
  --from-literal=DATABASE_USER=empadmin \
  --from-literal=DATABASE_PASSWORD="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

This applies a Secret with the same name/keys `aks/kustomization.yaml`
expects, so you can skip `aks/secret.yaml` entirely when you run the next
step (Kustomize will simply reuse the Secret already in the cluster - or
remove `secret.yaml` from `aks/kustomization.yaml`'s `resources:` list to
avoid it being reapplied with placeholder values).

---

## 8. Deploy everything

```bash
kubectl apply -k aks/
```

This applies, in the correct dependency order (Kustomize doesn't require
manual ordering, but conceptually):
namespace → configmap → secret → PVC → init-script ConfigMap →
PostgreSQL → backend → frontend → HPA → Ingress.

---

## 9. Verify

```bash
kubectl get pods -n employee-app
kubectl get svc -n employee-app
kubectl get ingress -n employee-app
kubectl get deployments -n employee-app
kubectl get hpa -n employee-app

# Wait for all Pods to report Running/Ready and 3 Deployments Available:
kubectl get pods -n employee-app -w
```

If something isn't healthy:

```bash
kubectl describe pod <pod-name> -n employee-app
kubectl logs <pod-name> -n employee-app
```

See the README "Troubleshooting (AKS)" table for specific symptoms.

---

## 10. Test the application

**With a real domain:** point `employee.example.com` (or your own host in
`aks/ingress/ingress.yaml`) at the Ingress controller's external IP via a
DNS A record, then:

```bash
curl http://employee.example.com/health
curl http://employee.example.com/api/employees
```

**No domain yet?** Use the Ingress controller's external IP directly with
an explicit `Host` header (since the Ingress rule is host-based):

```bash
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

curl -H "Host: employee.example.com" "http://$INGRESS_IP/health"
curl -H "Host: employee.example.com" "http://$INGRESS_IP/api/employees"
```

Or use a wildcard DNS service like **nip.io** so a real `Host` header
isn't needed at all - update `aks/ingress/ingress.yaml`'s `host:` to
`<INGRESS_IP>.nip.io` and reapply, then browse to
`http://<INGRESS_IP>.nip.io/`.

**From a browser:** open `http://employee.example.com/` (or the
`nip.io` address) once DNS/hosts resolves - you should see the same
dashboard UI as the VM deployment.

---

## 11. Exercise rolling updates and autoscaling (optional, hands-on)

```bash
# Rolling update: build+push a new backend tag, then:
kubectl set image deployment/backend \
  backend="$ACR_LOGIN_SERVER/employee-backend:v2" \
  -n employee-app
kubectl rollout status deployment/backend -n employee-app

# Roll back if needed
kubectl rollout undo deployment/backend -n employee-app

# Watch the HPA (generate load against the backend to see it scale)
kubectl get hpa -n employee-app -w
```

---

## 12. Clean up (avoid ongoing charges)

```bash
# Remove just the application
kubectl delete -k aks/

# Or remove everything, including the cluster and registry
az aks delete --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER" --yes --no-wait
az acr delete --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --yes
az group delete --name "$RESOURCE_GROUP" --yes --no-wait
```

---

## Quick reference: full command sequence

```bash
az login
az account set --subscription "<SUBSCRIPTION_ID_OR_NAME>"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
az acr create --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --sku Basic
az aks create --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER" \
  --node-count 2 --node-vm-size Standard_B2s --generate-ssh-keys --enable-managed-identity
az aks update --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER" --attach-acr "$ACR_NAME"
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER" --overwrite-existing

az acr login --name "$ACR_NAME"
docker build -t "$ACR_LOGIN_SERVER/employee-backend:$TAG" ./backend
docker build -t "$ACR_LOGIN_SERVER/employee-frontend:$TAG" ./frontend
docker push "$ACR_LOGIN_SERVER/employee-backend:$TAG"
docker push "$ACR_LOGIN_SERVER/employee-frontend:$TAG"

helm install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace

kubectl create namespace employee-app
kubectl create secret generic employee-secret -n employee-app \
  --from-literal=DATABASE_USER=empadmin \
  --from-literal=DATABASE_PASSWORD="$(openssl rand -base64 24)"

cd aks && kustomize edit set image \
  employee-backend-image="$ACR_LOGIN_SERVER/employee-backend:$TAG" \
  employee-frontend-image="$ACR_LOGIN_SERVER/employee-frontend:$TAG" && cd ..
kubectl apply -k aks/

kubectl get pods -n employee-app
kubectl get ingress -n employee-app
```
