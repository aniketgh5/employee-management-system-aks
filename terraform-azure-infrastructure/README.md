# Azure infrastructure for the Employee Management System

Terraform provisions a resource group, AKS cluster, Basic Azure Container Registry
(ACR), and Standard Azure Key Vault. The folder was renamed from
`terraform-aks-practice` to `terraform-azure-infrastructure`.

## Resources and permissions

- AKS uses a system-assigned identity and the existing kubenet network setup.
- The AKS kubelet identity receives `AcrPull` on ACR. Registry admin credentials
  are disabled; no image-pull password is needed in Kubernetes.
- AKS enables the Key Vault Secrets Store CSI add-on with secret rotation.
  Its identity receives `Key Vault Secrets User` on this vault only.
- Key Vault uses Azure RBAC, seven-day soft-delete retention and purge protection.
  After deletion, its name remains reserved during the retention period.
- ACR and Key Vault use public endpoints with authentication. Private endpoints
  and a remote Terraform state backend are not included.

Terraform does not upload images, populate vault secrets, install ingress or
cert-manager, or deploy application manifests. The application continues using
its existing Kubernetes Secret until a SecretProviderClass and CSI volume are
configured. The CSI client ID is available as a Terraform output. Creating the
vault does not automatically move PostgreSQL credentials or TLS certificates.

## Configure

Requirements: Terraform >= 1.5, Azure CLI, and permissions to create resources
and role assignments (for example Contributor plus User Access Administrator
at the deployment scope).

```bash
cd terraform-azure-infrastructure
az login
# For a fresh checkout only; do not overwrite an existing configured file:
cp -n terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`: set the subscription, resource group, cluster name,
region, DNS prefix, node size/count, and globally unique ACR and Key Vault names.
Your existing local subscription, resource names and region were preserved.
The local configuration names ACR `aniketghoshacr` and Key Vault
`aniketghosh-ems-kv`; verify ownership/name availability before applying.

Personal `.tfvars`, state files and plans are ignored. Commit the provider lock
file and use the example file to share configuration without local values.

## Existing Azure resources: import before applying

A matching name does not automatically adopt an existing Azure resource.
This folder has no existing state checked in. If you already manage these
resources with Terraform, use that original state/backend; do not import them
into a second state. A folder rename does not change resource addresses:
`azurerm_resource_group.main` and `azurerm_kubernetes_cluster.main` are retained.

The previously inspected live AKS cluster was in `eastus`, while the local
`terraform.tfvars` says `centralindia`. Match the existing resource location,
node pool name, networking, node size and other settings before planning an
imported cluster. Location/network changes can require replacement.

For resources currently managed outside Terraform, first initialize, then
import only resources that already exist (replace all placeholders):

```bash
terraform init
terraform import azurerm_resource_group.main "/subscriptions/<subscription-id>/resourceGroups/<resource-group>"
terraform import azurerm_kubernetes_cluster.main "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.ContainerService/managedClusters/<aks-name>"
terraform import azurerm_container_registry.main "/subscriptions/<subscription-id>/resourceGroups/<acr-resource-group>/providers/Microsoft.ContainerRegistry/registries/<acr-name>"
# Only if this vault already exists:
terraform import azurerm_key_vault.main "/subscriptions/<subscription-id>/resourceGroups/<vault-resource-group>/providers/Microsoft.KeyVault/vaults/<vault-name>"
```

This configuration places all resources in one resource group. If an existing
ACR/vault is elsewhere, adapt the configuration to its group before importing.
Existing equivalent role assignments also need importing by their full Azure
role-assignment IDs into `azurerm_role_assignment.aks_acr_pull` or
`azurerm_role_assignment.aks_key_vault_secrets` to avoid duplicate assignments.

## Validate, review and deploy

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan -out=infrastructure.tfplan
# Review the plan, especially any replacements of existing resources.
terraform apply infrastructure.tfplan
```

The plan checks your subscription, regional availability, permissions and live
resource differences. Local validation alone does not check these.

## Use the outputs

```bash
terraform output get_credentials_command
# Run the displayed az aks get-credentials command.
terraform output acr_name
terraform output acr_login_server
terraform output key_vault_name
terraform output key_vault_uri
terraform output key_vault_csi_client_id
```

Use the ACR login server to tag/push frontend and backend images and update
`../aks/kustomization.yaml`. To create vault secrets manually, grant the
appropriate operator `Key Vault Secrets Officer` at the vault scope; this
configuration grants only the CSI identity read access and creates no secrets.
