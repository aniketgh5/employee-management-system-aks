# AKS Practice Cluster Terraform

Small AKS cluster for practice.

## Prerequisites

- Azure CLI logged in: `az login`
- Terraform installed
- An Azure subscription selected: `az account set --subscription "<subscription-id>"`

## Deploy

```bash
terraform init
terraform plan
terraform apply
```

## Connect kubectl

```bash
az aks get-credentials \
  --resource-group aks-practice-rg \
  --name aks-practice-cluster
```

## Destroy

```bash
terraform destroy
```

