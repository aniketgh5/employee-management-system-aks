#!/bin/bash

set -euo pipefail

# ============================================================
# REQUIRED INPUTS
# ============================================================

SUBSCRIPTION_ID="d0200003-d736-4f7e-aeba-1c554da49b47"
RESOURCE_GROUP="rg-employee-app"
ACR_NAME="acremployeeapp20260810"
AKS_CLUSTER="aks-employee-app"
LOCATION="eastus"

# If script is already inside the project directory, use "."
PROJECT_DIR="."

# ============================================================
# HELPER FUNCTIONS
# ============================================================

info() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

fail() {
    echo
    echo "ERROR: $1"
    exit 1
}

# ============================================================
# 1. BASIC SYSTEM CHECK
# ============================================================

info "Checking system architecture"

ARCH="$(uname -m)"

echo "System architecture: $ARCH"

if [[ "$ARCH" != "x86_64" ]]; then
    echo
    echo "WARNING: This machine is not AMD64/x86_64."
    echo "Your AKS nodes are AMD64."
    echo "Recommended architecture: x86_64"
else
    echo "AMD64/x86_64 architecture: OK"
fi

# ============================================================
# 2. CHECK AZURE CLI
# ============================================================

info "Checking Azure CLI"

command -v az >/dev/null 2>&1 || fail "Azure CLI is not installed."

echo "Azure CLI:"
az version

# ============================================================
# 3. CHECK DOCKER
# ============================================================

info "Checking Docker"

command -v docker >/dev/null 2>&1 || fail "Docker is not installed."

echo "Docker version:"
docker --version

echo
echo "Checking Docker Engine..."

docker info >/dev/null 2>&1 || fail "Docker Engine is not running."

echo "Docker Engine: OK"

echo
echo "Docker architecture:"
docker info --format '{{.Architecture}}'

# ============================================================
# 4. CHECK KUBECTL
# ============================================================

info "Checking kubectl"

command -v kubectl >/dev/null 2>&1 || fail "kubectl is not installed."

echo "kubectl:"
kubectl version --client

# ============================================================
# 5. AZURE LOGIN
# ============================================================

info "Checking Azure login"

if ! az account show >/dev/null 2>&1; then
    echo "You are not logged in to Azure."
    echo "Opening Azure login..."
    az login
fi

echo
echo "Current Azure account:"
az account show --output table

# ============================================================
# 6. SELECT SUBSCRIPTION
# ============================================================

info "Selecting Azure subscription"

az account set --subscription "$SUBSCRIPTION_ID"

echo "Selected subscription:"

az account show \
    --query "{Name:name,SubscriptionId:id,TenantId:tenantId}" \
    --output table

# ============================================================
# 7. VERIFY RESOURCE GROUP
# ============================================================

info "Verifying Resource Group"

az group show \
    --name "$RESOURCE_GROUP" \
    --output table \
    || fail "Resource Group '$RESOURCE_GROUP' does not exist."

echo "Resource Group: OK"

# ============================================================
# 8. VERIFY ACR
# ============================================================

info "Verifying Azure Container Registry"

az acr show \
    --name "$ACR_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --output table \
    || fail "ACR '$ACR_NAME' does not exist."

ACR_LOGIN_SERVER="$(
    az acr show \
        --name "$ACR_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query loginServer \
        --output tsv
)"

echo
echo "ACR Name:         $ACR_NAME"
echo "ACR Login Server: $ACR_LOGIN_SERVER"

# ============================================================
# 9. VERIFY AKS
# ============================================================

info "Verifying AKS Cluster"

az aks show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AKS_CLUSTER" \
    --output table \
    || fail "AKS cluster '$AKS_CLUSTER' does not exist."

echo "AKS Cluster: OK"

# ============================================================
# 10. GET AKS CREDENTIALS
# ============================================================

info "Configuring kubectl for AKS"

mkdir -p "$HOME/.kube"

az aks get-credentials \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AKS_CLUSTER" \
    --overwrite-existing

echo
echo "Current Kubernetes context:"

kubectl config current-context

# ============================================================
# 11. CHECK AKS NODES
# ============================================================

info "Checking AKS nodes"

kubectl get nodes -o wide

echo
echo "Checking node architectures:"

kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.status.nodeInfo.architecture}{"\n"}{end}'

# ============================================================
# 12. ACR LOGIN
# ============================================================

info "Logging in to Azure Container Registry"

az acr login --name "$ACR_NAME"

echo
echo "ACR login successful."

# ============================================================
# 13. PROJECT DIRECTORY
# ============================================================

info "Checking project directory"

if [[ "$PROJECT_DIR" != "." ]]; then
    cd "$PROJECT_DIR"
fi

echo "Current directory:"
pwd

echo
echo "Project files:"
ls -la

# ============================================================
# 14. VERIFY DOCKER COMPOSE FILE
# ============================================================

if [[ -f "docker-compose.yml" ]]; then
    echo
    echo "docker-compose.yml: FOUND"
else
    echo
    echo "WARNING: docker-compose.yml not found."
fi

# ============================================================
# 15. FINAL STATUS
# ============================================================

info "SETUP COMPLETE"

echo "Azure Subscription : $SUBSCRIPTION_ID"
echo "Resource Group     : $RESOURCE_GROUP"
echo "ACR                : $ACR_NAME"
echo "ACR Login Server   : $ACR_LOGIN_SERVER"
echo "AKS Cluster        : $AKS_CLUSTER"
echo "Location           : $LOCATION"

echo
echo "Kubernetes Context:"
kubectl config current-context

echo
echo "AKS Nodes:"
kubectl get nodes

echo
echo "ACR Repositories:"
az acr repository list \
    --name "$ACR_NAME" \
    --output table 2>/dev/null || true

echo
echo "============================================================"
echo "SETUP COMPLETE"
echo "Existing Azure resources were NOT recreated."
echo "Next step: Build native AMD64 Docker images and push to ACR."
echo "============================================================"
