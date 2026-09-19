# Deploy this application with Azure DevOps

Pipeline: `.azure-pipelines/aks-deploy.yml`.

Every successful `main` build tests the backend, builds and pushes both images,
then deploys the manifests from that same build to the existing AKS cluster.
It waits for PostgreSQL/backend/frontend and checks `/`, `/health`, `/health/db`
and `/api/employees` through the ingress public IP. PRs run tests and Docker
builds without pushing or deploying. For Azure Repos Git, configure a **Build
validation** branch policy on `main`; YAML `pr:` triggers apply to GitHub and
Bitbucket repositories.

This is application delivery to your existing infrastructure, not a Terraform
pipeline. It does not recreate AKS, ACR, the public IP, or database storage.

## 1. Create the Azure service connection

Azure DevOps → Project settings → Service connections → New service connection
→ Azure Resource Manager → workload identity federation. Name it exactly
`azure-employee-aks` (or update `azureServiceConnection` in the YAML).
Authorize this pipeline to use the connection. A separate Docker registry
connection or saved Azure client secret is not required.

Have an Azure administrator grant the connection's service principal:

- `AcrPush` on `aniketghoshacr` for a registry using standard RBAC. For an
  ABAC-enabled registry, use `Container Registry Repository Writer` instead.
- `Azure Kubernetes Service Cluster User Role` on `aniketghosh-aks` to retrieve
  the user kubeconfig.
- For an Entra/Azure-RBAC-enabled cluster: Kubernetes data-plane permissions
  as well. The full manifest set creates a Namespace and a ClusterIssuer, so
  `Azure Kubernetes Service RBAC Cluster Admin` at cluster scope is a simple
  lab setup. For tighter permissions, provision those cluster resources
  separately and scope application access to `employee-app`.

Your current cluster has no Entra integration and has local accounts enabled.
The pipeline uses `az aks get-credentials` without `--admin`, matching that
configuration. On an Entra-enabled cluster it converts the kubeconfig using
`kubelogin -l azurecli` within the authenticated Azure CLI task. With Kubernetes
RBAC instead of Azure RBAC, an administrator must create the corresponding
RoleBindings/ClusterRoleBindings for the connection identity.

The AKS kubelet identity also needs permission to pull images from ACR. Your
existing frontend already pulls from this registry. If setting up a different
cluster with standard ACR RBAC, an administrator can connect it with:

```bash
az aks update --resource-group aniketghosh-aks-rg \
  --name aniketghosh-aks --attach-acr aniketghoshacr
```

For ABAC-enabled ACR, assign the kubelet identity `Container Registry Repository
Reader` instead. Pipeline push access and kubelet pull access are separate.

## 2. Check the existing cluster prerequisites

These are already present in the cluster used in this conversation:

- AKS and ACR, with network access from the pipeline agent.
- Application routing ingress class `webapprouting.kubernetes.azure.com`.
- cert-manager and its ClusterIssuer CRD.
- Namespace `employee-app` and Secret `employee-secret` with `DATABASE_USER`
  and `DATABASE_PASSWORD` matching the initialized PostgreSQL database.

The pipeline intentionally excludes `aks/secret.yaml` from both the deployment
and published artifacts. It preserves the live Secret. No database password
needs to be placed in pipeline YAML or printed in logs. For a fresh installation,
create that Secret through your secret-management process before running this
pipeline; do not apply the committed example credentials. Changing the Secret
alone does not rotate a password in an existing PostgreSQL PVC.

The manifests retain the hostless HTTP ingress rule, so the public IP works
without DNS. Domain routes remain available, but certificates require DNS.

The hosted `ubuntu-24.04` agent needs access to the AKS API, ACR, and application
public IP. If using a private cluster, restricted registry, or API IP allowlist,
use a self-hosted agent with the appropriate network access and change `pool`.

## 3. Create the environment and pipeline

1. Push these files to your repository.
2. Azure DevOps → Pipelines → Environments → create `aks-employee-app`.
3. On that environment, add an **Exclusive lock** check. The YAML uses
   `lockBehavior: sequential`; the check is required to serialize deployments
   and avoid simultaneous runs changing the same cluster. Optionally configure
   an approval check if your team requires one.
4. Pipelines → New pipeline → select your repository → Existing Azure Pipelines
   YAML file → `.azure-pipelines/aks-deploy.yml`.
5. Save and run from `main`. Authorize the service connection and environment
   for this pipeline when Azure DevOps requests it.

Resource values are already filled in:

| Setting | Value |
|---|---|
| ARM service connection | `azure-employee-aks` |
| AKS resource group | `aniketghosh-aks-rg` |
| AKS cluster | `aniketghosh-aks` |
| ACR | `aniketghoshacr.azurecr.io` |
| Backend repository | `employee-api` |
| Frontend repository | `employee-frontend` |
| Environment | `aks-employee-app` |
| kubectl version | `1.35.0`, matching the current AKS minor version |

Each image is tagged `Build.BuildId-Build.SourceVersion`. The build uses
`backend/Dockerfile` with context `backend/`, and **`frontend/Dockerfile` with
context `frontend/`**. It never builds the VM's `nginx/Dockerfile`. Build and
push share one job so images are available when pushed. Deployment downloads
the rendered artifact from the same pipeline run rather than deploying the
fixed local `v1`/`v2` tags. Keep the kubectl version compatible when upgrading AKS.

## 4. Verify and handle failures

The final deployment log prints `Application URL: http://<public-ip>`.
A successful deployment requires all rollout waits and four HTTP checks to
pass, including database connectivity. A failure prints pod/deployment/ingress
status and events without dumping Secrets. Old resources are not pruned and
PVCs are preserved. A failed smoke test fails the pipeline; it does not
silently roll back application images or database data.

To investigate:

```bash
kubectl get pods -n employee-app
kubectl get events -n employee-app --sort-by=.lastTimestamp
kubectl logs -n employee-app deployment/backend --tail=50
kubectl logs -n employee-app deployment/frontend --tail=50
```

To return the application images to a known release, take the tag from a
previous successful pipeline run and replace `<previous-tag>` below:

```bash
kubectl set image deployment/backend \
  backend=aniketghoshacr.azurecr.io/employee-api:<previous-tag> -n employee-app
kubectl set image deployment/frontend \
  frontend=aniketghoshacr.azurecr.io/employee-frontend:<previous-tag> -n employee-app
kubectl rollout status deployment/backend -n employee-app
kubectl rollout status deployment/frontend -n employee-app
```

This restores images only. Revert any incompatible manifest/code change before
running a new pipeline. Do not delete PostgreSQL's PVC as part of a rollback.

## References

- [Azure Resource Manager service connections](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/connect-to-azure?view=azure-devops)
- [AKS kubelogin authentication](https://learn.microsoft.com/en-us/azure/aks/kubelogin-authentication)
- [Azure Pipelines exclusive lock checks](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/approvals?view=azure-devops)
