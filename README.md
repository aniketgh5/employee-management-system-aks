# Employee Management System

A small, realistic, enterprise-style application deployed **two different
ways from the same source code**: a single Azure Ubuntu VM running Docker
Compose, and Azure Kubernetes Service (AKS). Built as a hands-on DevOps
portfolio project covering the full lifecycle from Terraform-provisioned
infrastructure through containers, orchestration, and CI/CD.

> **Same app, two platforms.** `backend/`, `frontend/`, and
> `database/init.sql` are identical in both deployments. Only the
> deployment artifacts differ: `docker-compose.yml` + `nginx/` for the VM,
> `aks/` (Kubernetes manifests) for AKS.

---

## Table of Contents

1. [Application Overview](#1-application-overview)
2. [VM Architecture](#2-vm-architecture)
3. [AKS Architecture](#3-aks-architecture)
4. [Docker Architecture](#4-docker-architecture)
5. [ACR Architecture](#5-acr-architecture)
6. [Kubernetes Architecture](#6-kubernetes-architecture)
7. [VM Deployment](#7-vm-deployment)
8. [AKS Deployment](#8-aks-deployment)
9. [ACR Setup](#9-acr-setup)
10. [Kubernetes Commands](#10-kubernetes-commands)
11. [Troubleshooting](#11-troubleshooting)
12. [CI/CD](#12-cicd)
13. [Security](#13-security)
14. [Monitoring](#14-monitoring)
15. [VM vs AKS Comparison](#15-vm-vs-aks-comparison)
16. [Production Architecture Evolution](#16-production-architecture-evolution)
17. [Interview Talking Points](#17-interview-talking-points)

Deeper references: `docs/vm-architecture.md`, `docs/aks-architecture.md`,
`docs/vm-vs-aks.md`, and the standalone `AKS_DEPLOYMENT_GUIDE.md`.

---

## 1. Application Overview

**Employee Management System** - a small internal HR-style tool: a
dashboard, a searchable/filterable employee table, and full CRUD via a
REST API.

| Layer | Technology |
|---|---|
| Frontend | HTML5, CSS3, vanilla JavaScript (no build step) |
| Backend | Python 3.12, FastAPI, Uvicorn |
| ORM | SQLAlchemy 2.x |
| Database | PostgreSQL 16 |
| Validation | Pydantic v2 / pydantic-settings |
| Testing | Pytest + FastAPI `TestClient` (SQLite in-memory, no DB dependency) |
| VM deployment | Docker, Docker Compose, Nginx |
| AKS deployment | Kubernetes, Kustomize, Ingress-nginx, ACR |
| CI/CD | Azure Pipelines (two pipelines - VM and AKS) |

### API endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Liveness check (no DB access) |
| GET | `/health/db` | Readiness check - verifies DB connectivity |
| GET | `/api/employees` | List employees (`search`, `department`, `status`, `skip`, `limit`) |
| GET | `/api/employees/{id}` | Get one employee |
| POST | `/api/employees` | Create an employee |
| PUT | `/api/employees/{id}` | Update an employee (partial) |
| DELETE | `/api/employees/{id}` | Delete an employee |
| GET | `/api/dashboard/stats` | Totals, active count, department count, recent employees |

Full interactive docs at `/docs` (Swagger UI) on either deployment.

### Project structure

```
employee-management-system/
├── backend/                    # FastAPI app - SHARED by both deployments
│   ├── app/
│   ├── tests/
│   ├── requirements.txt
│   └── Dockerfile              # used by both docker-compose and AKS
│
├── frontend/                   # Static site - SHARED by both deployments
│   ├── index.html
│   ├── css/style.css
│   ├── js/app.js
│   ├── Dockerfile              # AKS-only: serves static files behind Ingress
│   └── nginx.aks.conf
│
├── nginx/                      # VM-only: reverse proxy + static serving in one container
│   ├── Dockerfile
│   └── nginx.conf
│
├── database/
│   └── init.sql                # SHARED schema + seed data (also reused by aks/)
│
├── docker-compose.yml          # VM deployment
├── .env.example
│
├── aks/                        # AKS deployment (Kustomize)
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── secret.yaml
│   ├── frontend/{deployment,service}.yaml
│   ├── backend/{deployment,service,hpa}.yaml
│   ├── database/{deployment,service,pvc,init-configmap}.yaml
│   ├── ingress/ingress.yaml
│   └── kustomization.yaml
│
├── .azure-pipelines/
│   ├── vm-deploy.yml
│   └── aks-deploy.yml
│
├── docs/
│   ├── vm-architecture.md
│   ├── aks-architecture.md
│   └── vm-vs-aks.md
│
├── README.md                   # this file
├── AKS_DEPLOYMENT_GUIDE.md
└── .gitignore
```

---

## 2. VM Architecture

```
Browser --:80--> Nginx (container) --/api/*--> FastAPI (container) --> PostgreSQL (container)
```

One Azure Ubuntu VM (`vm-alzvm-app01`, `Standard_B1s`) runs all three
containers via Docker Compose. Nginx both serves the static frontend
*and* reverse-proxies `/api`, `/health`, `/docs` to the backend. Only
port 80 is published to the host; PostgreSQL and the backend are only
reachable on the internal Docker network.

Full diagrams and request-flow walkthrough: **`docs/vm-architecture.md`**.

---

## 3. AKS Architecture

```
Internet -> Ingress -> {Frontend Service -> Frontend Pods, Backend Service -> Backend Pods -> PostgreSQL Service -> PostgreSQL Pod}
```

Frontend and backend now run as **separate** Deployments/Services/Pods
(unlike the VM's single Nginx container), with a Kubernetes **Ingress**
doing the path-based routing that Nginx used to do itself. The backend
autoscales 2→5 replicas via an HPA; PostgreSQL runs as a single
PVC-backed Pod, clearly documented as a learning-environment choice (see
below).

Full diagrams, the full list of Kubernetes objects explained in plain
language, DNS, storage lifecycle, and security notes:
**`docs/aks-architecture.md`**.

---

## 4. Docker Architecture

Three Docker images total, two of them (`backend`, VM's `nginx`) reused
as-is between local dev and the VM; a fourth, `frontend`, exists only for
AKS:

| Image | Dockerfile | Used by | Notes |
|---|---|---|---|
| `employee-backend` | `backend/Dockerfile` | VM + AKS | Identical for both - Python 3.12-slim, non-root `appuser`, Uvicorn, `/health` healthcheck. **No changes between deployments.** |
| `employee-nginx` (VM only) | `nginx/Dockerfile` | VM | Serves the static frontend AND reverse-proxies to the backend in one container. |
| `employee-frontend` (AKS only) | `frontend/Dockerfile` | AKS | Serves ONLY the static frontend (same `index.html`/`css`/`js` as the VM), using `nginxinc/nginx-unprivileged` so it satisfies Kubernetes' non-root SecurityContext out of the box. Ingress handles `/api` routing instead. |
| `postgres:16-alpine` (official) | n/a | VM + AKS | Same official image both places; same `database/init.sql` schema/seed data mounted in both. |

Build contexts:

```bash
# Backend (identical command for both deployment targets)
docker build -t employee-backend:local ./backend

# VM's combined nginx+frontend image (build context = repo root)
docker build -t employee-nginx:local -f nginx/Dockerfile .

# AKS-only static frontend image
docker build -t employee-frontend:local ./frontend
```

---

## 5. ACR Architecture

Azure Container Registry is the private registry AKS pulls images from -
the AKS equivalent of "where do the Docker images live" (the VM
deployment doesn't need one; images are built directly on/for the VM).

```
docker build -> local image -> docker push -> ACR -> AKS pulls via AcrPull (managed identity)
```

Image naming convention used throughout `aks/`:

```
<ACR_LOGIN_SERVER>/employee-backend:<TAG>
<ACR_LOGIN_SERVER>/employee-frontend:<TAG>
```

`<TAG>` should be an immutable identifier (git commit SHA or CI build
ID) - see [CI/CD](#12-cicd) for why `latest` alone is not enough for a
real deployment.

---

## 6. Kubernetes Architecture

Namespace `employee-app` contains every resource. Object types used and
what each one does, briefly (full explanations in
`docs/aks-architecture.md` section 3):

- **Deployment** (`frontend`, `backend`, `postgresql`) - desired replica count + rollout strategy.
- **Service** (`frontend`, `backend`, `postgresql`, all `ClusterIP`) - stable internal DNS name/IP in front of a Deployment's Pods.
- **ConfigMap** (`employee-config`, `postgres-init-script`) - non-secret configuration and the reused `database/init.sql`.
- **Secret** (`employee-secret`) - `DATABASE_USER` / `DATABASE_PASSWORD`.
- **PersistentVolumeClaim** (`postgresql-pvc`) - durable storage for PostgreSQL, backed by an Azure Managed Disk.
- **Ingress** (`employee-ingress`) - the single public entry point; routes `/api` and `/health` to the backend, `/` to the frontend.
- **HorizontalPodAutoscaler** (`backend-hpa`) - scales the backend 2-5 replicas on CPU.
- **Liveness/Readiness Probes** - on `/health` for both backend and frontend containers.
- **SecurityContext** - non-root, read-only root filesystem, dropped Linux capabilities, on every container.

---

## 7. VM Deployment

### Local development

```bash
git clone <your-repo-url> employee-management-system
cd employee-management-system
cp .env.example .env          # set a real DATABASE_PASSWORD

docker compose build
docker compose up -d
docker compose ps
docker compose logs -f
```

| What | URL |
|---|---|
| Application (UI) | http://localhost |
| REST API | http://localhost/api/employees |
| Health check | http://localhost/health |
| Swagger / OpenAPI | http://localhost/docs |

### Backend tests

```bash
cd backend
pip install -r requirements.txt
pytest -v
```

### Azure VM deployment

```bash
ssh -i /path/to/key.pem azureuser@<VM_PUBLIC_IP>

# Install Docker Engine + Compose plugin
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker $USER   # log out/in after this

git clone <your-repo-url> employee-management-system
cd employee-management-system
cp .env.example .env
nano .env   # strong DATABASE_PASSWORD, CORS_ORIGINS=http://<VM_PUBLIC_IP>

docker compose build
docker compose up -d
docker compose ps
docker compose logs -f
curl http://localhost/health
```

Then browse to `http://<VM_PUBLIC_IP>/`. Ensure the NSG allows inbound
TCP 80. Nginx runs **containerized** here, not host-installed - see
`docs/vm-architecture.md` for the reasoning.

### Environment variables (VM)

| Variable | Description |
|---|---|
| `APP_NAME`, `APP_ENV`, `LOG_LEVEL` | App identity/logging |
| `CORS_ORIGINS` | Comma-separated allowed origins |
| `DATABASE_HOST` / `PORT` / `NAME` / `USER` / `PASSWORD` | Postgres connection (used by both the backend and the `postgres` container itself) |

`.env` is git-ignored; only `.env.example` (placeholders) is committed.

---

## 8. AKS Deployment

Condensed version - the full, ordered, copy-pasteable procedure (Azure
CLI setup through cleanup) lives in **`AKS_DEPLOYMENT_GUIDE.md`**.

```bash
# 1. Azure plumbing
az login
az account set --subscription "<SUBSCRIPTION_ID_OR_NAME>"
az group create --name "<RESOURCE_GROUP>" --location "<LOCATION>"
az acr create --resource-group "<RESOURCE_GROUP>" --name "<ACR_NAME>" --sku Basic
az aks create --resource-group "<RESOURCE_GROUP>" --name "<AKS_CLUSTER>" \
  --node-count 2 --node-vm-size Standard_B2s --generate-ssh-keys --enable-managed-identity
az aks update --resource-group "<RESOURCE_GROUP>" --name "<AKS_CLUSTER>" --attach-acr "<ACR_NAME>"
az aks get-credentials --resource-group "<RESOURCE_GROUP>" --name "<AKS_CLUSTER>"

# 2. Build & push images (see section 9)
# 3. Install ingress-nginx (see docs/aks-architecture.md section 7)
helm install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace

# 4. Point manifests at your ACR images, then deploy
cd aks && kustomize edit set image \
  employee-backend-image=<ACR_LOGIN_SERVER>/employee-backend:<TAG> \
  employee-frontend-image=<ACR_LOGIN_SERVER>/employee-frontend:<TAG> && cd ..
kubectl apply -k aks/

# 5. Verify
kubectl get pods -n employee-app
kubectl get ingress -n employee-app
```

---

## 9. ACR Setup

```bash
# 1. Create ACR
az acr create --resource-group "<RESOURCE_GROUP>" --name "<ACR_NAME>" --sku Basic

# 2. Login
az acr login --name "<ACR_NAME>"
ACR_LOGIN_SERVER=$(az acr show --name "<ACR_NAME>" --query loginServer -o tsv)

# 3. Build backend image
docker build -t "$ACR_LOGIN_SERVER/employee-backend:<TAG>" ./backend

# 4. Build frontend image
docker build -t "$ACR_LOGIN_SERVER/employee-frontend:<TAG>" ./frontend

# 5. Tag (already tagged correctly by -t above; retag if needed)
docker tag employee-backend:local "$ACR_LOGIN_SERVER/employee-backend:<TAG>"

# 6. Push
docker push "$ACR_LOGIN_SERVER/employee-backend:<TAG>"
docker push "$ACR_LOGIN_SERVER/employee-frontend:<TAG>"

# 7. Verify
az acr repository list --name "<ACR_NAME>" --output table
az acr repository show-tags --name "<ACR_NAME>" --repository employee-backend --output table
```

### AKS image pull (why no registry password in a Secret)

```
AKS  --Managed Identity + "AcrPull" role-->  ACR
```

`az aks update --attach-acr` grants the AKS cluster's managed identity
the **`AcrPull`** role directly on the registry. AKS then authenticates
to ACR using that identity automatically on every image pull - no
`imagePullSecrets`, no registry username/password stored anywhere in the
cluster. This is the recommended Azure-native integration specifically
*because* storing long-lived registry credentials as a Kubernetes Secret
is both an unnecessary secret to rotate/leak and unnecessary given a
built-in, auditable alternative already exists.

---

## 10. Kubernetes Commands

```bash
# Apply everything (namespace through ingress, in one go via Kustomize)
kubectl apply -k aks/

# Or apply pieces individually, in dependency order:
kubectl apply -f aks/namespace.yaml
kubectl apply -f aks/configmap.yaml
kubectl apply -f aks/secret.yaml
kubectl apply -f aks/database/
kubectl apply -f aks/backend/
kubectl apply -f aks/frontend/
kubectl apply -f aks/ingress/

# Verify
kubectl get pods -n employee-app
kubectl get svc -n employee-app
kubectl get ingress -n employee-app
kubectl get deployments -n employee-app
kubectl get hpa -n employee-app

# Diagnose
kubectl describe pod <pod-name> -n employee-app
kubectl logs <pod-name> -n employee-app
kubectl logs <pod-name> -n employee-app --previous   # logs from before a crash/restart
kubectl get events -n employee-app --sort-by='.lastTimestamp'

# Rolling update / rollback
kubectl set image deployment/backend backend=<ACR_LOGIN_SERVER>/employee-backend:<NEW_TAG> -n employee-app
kubectl rollout status deployment/backend -n employee-app
kubectl rollout undo deployment/backend -n employee-app

# Scale manually (HPA will also do this automatically for backend)
kubectl scale deployment/frontend --replicas=3 -n employee-app

# Clean up
kubectl delete -k aks/
```

---

## 11. Troubleshooting

### VM (Docker Compose)

| Problem | Cause | Diagnose | Solution |
|---|---|---|---|
| Port 80 already in use | Another process bound to :80 | `sudo ss -tulpn \| grep :80` | Stop the conflicting service or remap the host port |
| Docker permission denied | User not in `docker` group | `docker ps` fails | `sudo usermod -aG docker $USER`, re-login |
| Container restarting | App error, bad env var, DB not ready | `docker compose logs backend` | Check logs/`.env` values |
| PostgreSQL connection refused | Postgres still starting or wrong host | `docker compose logs postgres` | Confirm `DATABASE_HOST=postgres`, wait for healthy |
| Nginx 502 Bad Gateway | Backend not up/healthy | `docker compose logs nginx` | Check/restart backend |
| Azure NSG blocking port 80 | Inbound rule missing | Azure Portal → NSG rules | Add inbound rule for TCP 80 |
| `.env` not loaded | Missing file / wrong directory | `docker compose config` | `cp .env.example .env` in project root |

*(Full VM troubleshooting table, including container DNS and volume
issues: see the original table format above, mirrored in
`docs/vm-architecture.md`.)*

### AKS (Kubernetes)

| Problem | Symptoms | Cause | Diagnostic command | Solution |
|---|---|---|---|---|
| **ImagePullBackOff / ErrImagePull** | Pod stuck, `kubectl get pods` shows this status | Wrong image name/tag, or AKS can't auth to ACR | `kubectl describe pod <pod> -n employee-app` | Verify the image exists (`az acr repository show-tags`), confirm `az aks update --attach-acr` was run |
| **CrashLoopBackOff** | Pod restarts repeatedly | App crashes on startup - bad env var, DB unreachable, code error | `kubectl logs <pod> -n employee-app --previous` | Fix the underlying error shown in logs; check ConfigMap/Secret values |
| **Pending Pods** | Pod never schedules | Insufficient CPU/memory on nodes, or unsatisfied PVC | `kubectl describe pod <pod> -n employee-app` (see Events) | Add nodes/resize node pool, or reduce requests |
| **PVC Pending** | `kubectl get pvc -n employee-app` shows `Pending` | No matching StorageClass, or Azure quota | `kubectl describe pvc postgresql-pvc -n employee-app` | Confirm `storageClassName` exists: `kubectl get storageclass` |
| **PostgreSQL connection failure** | Backend logs show connection errors | Postgres Pod not Ready, or wrong `DATABASE_HOST` | `kubectl logs deploy/postgresql -n employee-app` | Confirm `postgresql` Service/Pod healthy; confirm ConfigMap `DATABASE_HOST` |
| **Backend not ready** | `kubectl get pods` shows `0/1` Ready | Readiness probe failing (DB not reachable, app not started) | `kubectl describe pod <backend-pod> -n employee-app` | Check probe failure reason, backend logs |
| **Readiness probe failure** | Pod Running but not `Ready`, no traffic served | `/health` not responding in time | `kubectl describe pod <pod> -n employee-app` | Check app logs; consider raising `initialDelaySeconds` |
| **Liveness probe failure** | Pod restart count increasing | App hung or too slow to respond | `kubectl describe pod <pod> -n employee-app` | Check for deadlocks/slow startup; tune probe timing |
| **Ingress 404** | Browser/`curl` gets 404 | Path/Service name mismatch, or wrong `Host` header | `kubectl describe ingress employee-ingress -n employee-app` | Confirm path rules match `aks/ingress/ingress.yaml`; use correct `Host` header if testing by IP |
| **Ingress 502** | Bad Gateway | Backend/frontend Pods not Ready | `kubectl get pods -n employee-app` | Fix underlying Pod readiness issue first |
| **Service not reachable** | `curl` inside cluster fails | Selector/label mismatch | `kubectl get endpoints <service> -n employee-app` (empty = no matching Pods) | Confirm Service `selector` matches Pod `labels` exactly |
| **DNS resolution failure** | App can't resolve `postgresql` etc. | CoreDNS issue, or wrong namespace | `kubectl exec -it <pod> -n employee-app -- nslookup postgresql` | Confirm Service exists in the same namespace; check CoreDNS Pods (`kube-system`) |
| **ACR authentication failure** | `docker push`/`az acr login` fails | Not logged in, or insufficient RBAC | `az acr login --name <ACR_NAME>` | Re-run `az acr login`; confirm your account has `AcrPush` |
| **AKS cannot pull ACR image** | `ImagePullBackOff` even though the image exists | ACR not attached to the cluster | `az aks check-acr --resource-group <RG> --name <CLUSTER> --acr <ACR_NAME>` | `az aks update --attach-acr <ACR_NAME>` |
| **HPA not scaling** | Replica count stays flat under load | Metrics server unavailable, or no CPU requests set | `kubectl describe hpa backend-hpa -n employee-app` | Confirm `resources.requests.cpu` is set (it is, by default); confirm metrics-server is running |
| **Insufficient CPU / memory** | Pods stuck `Pending`, event says "Insufficient cpu" | Node pool too small for requested resources | `kubectl describe nodes` | Lower resource requests, or scale/resize the node pool |
| **Node NotReady** | `kubectl get nodes` shows `NotReady` | Node-level issue (kubelet, network, VM problem) | `kubectl describe node <node>` | Often resolves itself; if not, investigate via Azure Portal/`az aks nodepool` or cordon/drain and replace the node |

---

## 12. CI/CD

Two pipelines, mirroring the two deployment models:

- **`.azure-pipelines/vm-deploy.yml`** - Test → Docker build (backend) → tag → (push, placeholder) → deploy over SSH (placeholder).
- **`.azure-pipelines/aks-deploy.yml`** - Backend tests → build and push both images to ACR → deploy the release manifests to AKS → verify rollouts and public HTTP/database health. Pull requests test and build without deploying.

For the AKS pipeline, follow [Azure DevOps setup](docs/azure-devops-aks.md) to
create the Azure service connection and deployment environment. It targets the
existing cluster and preserves the live database Secret and PVC. The VM
pipeline remains a placeholder.

### Docker image tagging strategy

```
employee-backend:latest
employee-backend:$(Build.BuildId)
employee-backend:<git-commit-sha>
```

`latest` alone is fine for local dev, but never for a real deployment: it
is mutable, so a deployed Pod/container can't be traced back to an exact
commit, and a bad push can silently overwrite a known-good image.
Tagging with the immutable **build ID** and/or **git commit SHA** makes
every deployment traceable and rollback a one-line change
(`kubectl set image ... backend=...:<previous-tag>` or
`docker compose pull employee-backend:<previous-tag>`).

---

## 13. Security

**Shared (both deployments):**
- No hardcoded credentials - environment variables only (`app/config.py`).
- Input validation via Pydantic; explicit HTTP status codes; no leaked stack traces.
- `.env` / `aks/secret.yaml` real values are never committed - both are placeholders/git-ignored.

**VM-specific:**
- PostgreSQL and the backend have no host-published ports - only Nginx's :80 is exposed.
- Backend container runs as non-root `appuser`.
- Azure NSG controls perimeter access.

**AKS-specific:**
- Namespace isolation (`employee-app`).
- `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, all Linux capabilities dropped - on both frontend and backend containers.
- PostgreSQL and backend Services are `ClusterIP`-only, never reachable from the internet.
- Kubernetes Secrets for credentials; `AcrPull` managed identity instead of a stored registry password (see section 9).
- Resource requests/limits and health probes on every workload.

---

## 14. Monitoring

| What to watch | VM | AKS |
|---|---|---|
| Application logs | `docker compose logs -f` | `kubectl logs <pod> -n employee-app` |
| Container/Pod restarts | `docker compose ps` | `kubectl get pods -n employee-app`, `kubectl get events` |
| CPU / memory | `docker stats` | `kubectl top pods -n employee-app`, `kubectl top nodes` |
| Request count / HTTP errors | Nginx access logs (`docker compose logs nginx`) | Ingress controller logs / metrics; Azure Monitor once enabled |
| Host/Node health | `htop`, Azure VM metrics | `kubectl get nodes`, Azure Monitor for containers |

For AKS, this deployment is ready to plug into (not enabled by default,
so no extra Azure spend unless you turn it on):
- **Azure Monitor + Container Insights** - `az aks enable-addons -a monitoring ...`
- **Log Analytics** - collects the backend's existing stdout logs automatically once Container Insights is on.
- **Application Insights** - add the Python SDK to the FastAPI app for request/latency tracing.

---

## 15. VM vs AKS Comparison

| Dimension | VM | AKS |
|---|---|---|
| Scaling | Manual | Automatic (HPA, 2-5 backend replicas on CPU) |
| High availability | Single VM = single point of failure | Multiple replicas across nodes |
| Self-healing | Container restart policy only | Kubernetes reschedules/restarts automatically, on any healthy node |
| Rolling updates | Manual `docker compose up -d --build` | Declarative `RollingUpdate` with availability guarantees |
| Load balancing | N/A (1 backend container) | Kubernetes Service load-balances across all healthy replicas |
| Networking | Docker bridge + one Nginx container | ClusterIP Services + DNS + Ingress |
| Cost (learning scale) | Lowest (1 small VM) | Higher (control plane + 1-2+ nodes always on) |
| Operational overhead | Low | Higher, but buys HA/scaling/self-healing |

Full comparison with more dimensions (storage, security, monitoring,
CI/CD, "when to use which"): **`docs/vm-vs-aks.md`**.

---

## 16. Production Architecture Evolution

```
LEVEL 1   Single Azure VM + Docker Compose                          <- you are here (VM deployment)
LEVEL 2   AKS + ACR + Kubernetes                                    <- you are here (AKS deployment)
LEVEL 3   AKS + Azure Database for PostgreSQL + Key Vault + Managed Identity
LEVEL 4   AKS + Application Gateway for Containers + Private AKS + Private ACR
          + Private Database + Azure Firewall + Azure Monitor + Log Analytics
LEVEL 5   Enterprise Landing Zone: Hub-Spoke + Centralized Security + Governance
          + Policy + Private DNS + Private Endpoints + CI/CD + DevSecOps
```

- **Level 1 → 2**: what this repository already demonstrates - the same app on a VM and on a real orchestrator.
- **Level 2 → 3**: stop self-managing PostgreSQL and secrets - swap `aks/database/*` for Azure Database for PostgreSQL Flexible Server, and `aks/secret.yaml` for the AKS Key Vault Provider for Secrets Store CSI Driver + Managed Identity. No application code changes needed either time - the backend already only knows "a Postgres host" and "some env vars."
- **Level 3 → 4**: move the Ingress to Application Gateway for Containers (WAF, Azure-native L7 LB), make the AKS API server and ACR private, add Azure Firewall for egress control, turn on Azure Monitor/Container Insights/Log Analytics for real observability.
- **Level 4 → 5**: this stops being "one app's infrastructure" and becomes **platform** work - a Hub-Spoke network topology, Azure Policy for guardrails, Private DNS zones and Private Endpoints for every PaaS dependency, and CI/CD that deploys through that landing zone rather than directly against a cluster.

---

## 17. Interview Talking Points

### A realistic 2-minute explanation

> "I built an Employee Management System - a FastAPI backend, Postgres
> database, and a small JS frontend - and deployed the *same*
> application two different ways to demonstrate the trade-offs between
> them. First, on a single Azure VM using Docker Compose: Nginx, FastAPI,
> and Postgres as three containers, with Nginx handling both static
> serving and reverse proxying. Then I built a second deployment for AKS
> without touching the application code - I split the frontend into its
> own lightweight static-serving image, kept the backend image
> unchanged, and moved the routing responsibility from Nginx into a
> Kubernetes Ingress. On AKS the backend autoscales on CPU via an HPA,
> Postgres runs on a PersistentVolumeClaim-backed Pod, and everything's
> defined declaratively with Kustomize so `kubectl apply -k aks/` brings
> up the whole namespace. I used a Kubernetes Secret and ConfigMap that
> map 1:1 onto the same environment variables the app already reads, so
> there was zero code change to move platforms - only deployment
> artifacts changed. I also wired up two CI/CD pipeline skeletons in
> Azure Pipelines, one per platform, both ending in an automated smoke
> test against `/health` and `/api/employees`. The whole point was to
> have one codebase I could talk through both ways: 'here's the simple,
> cheap version' and 'here's what changes when you need HA, autoscaling,
> and self-healing.'"

### Likely questions

- **Why VM vs AKS?** VM: simplest possible path to "it's running," cheapest, easiest to reason about end-to-end. AKS: needed when you require automatic scaling, self-healing, rolling updates with real availability guarantees, or you're running many services on a shared platform.
- **Why ACR?** AKS needs a registry to pull images from; ACR integrates natively with AKS via managed identity (`AcrPull`), avoiding stored registry credentials.
- **Why ClusterIP (not LoadBalancer) for frontend/backend?** They should never be reachable directly from the internet - the Ingress is the single, controllable public entry point; `ClusterIP` keeps them internal-only.
- **Why Ingress instead of a Service per component?** One shared public IP/LB, path-based routing to many Services, and centralized TLS termination - a `LoadBalancer` Service per component would mean N public IPs and no shared routing/TLS story.
- **Why not expose PostgreSQL?** No legitimate reason for anything outside the backend to reach it directly; exposing it would be a pure security liability with zero benefit.
- **Why readiness/liveness probes?** Readiness stops traffic from reaching a Pod that isn't ready yet (no restart); liveness restarts a Pod whose process is hung but still technically running. Different problems, different remediation.
- **Why HPA?** Traffic isn't constant - scale capacity to load automatically instead of either over-provisioning for the peak or under-provisioning for the average.
- **Why resource requests/limits?** Requests drive scheduling (and HPA math); limits stop one container from starving its node of CPU/memory.
- **How does AKS pull images from ACR?** Cluster's managed identity is granted the `AcrPull` role on the registry (`az aks update --attach-acr`) - no credentials stored in the cluster.
- **How does Kubernetes Service discovery work?** Every Service gets a stable ClusterIP and a DNS name (`<service>.<namespace>.svc.cluster.local`); kube-proxy/CoreDNS route that to whichever Pods currently pass their readiness probe.
- **How does rolling deployment work?** `RollingUpdate` with `maxUnavailable`/`maxSurge` gradually replaces old Pods with new ones while keeping a minimum number available throughout.
- **How would you make this production-ready?** Azure Database for PostgreSQL instead of self-managed Postgres, Key Vault for secrets, Private AKS/ACR, Application Gateway for Containers, Azure Monitor/Log Analytics, and real CI/CD gates (see "Production Architecture Evolution").
- **How would you secure secrets?** Never commit real values; use the AKS Key Vault Provider for Secrets Store CSI Driver with Managed Identity instead of plain Kubernetes Secrets for anything sensitive in production.
- **How would you deploy PostgreSQL in production?** Azure Database for PostgreSQL - Flexible Server, not a self-managed Pod - for HA, automated backups, and patching.
- **How would CI/CD work end-to-end?** Push → test → build both images with an immutable tag → push to ACR → `kubectl apply -k` (or Helm) against AKS → automated smoke test that fails the pipeline on a bad deploy.
- **How would you troubleshoot CrashLoopBackOff?** `kubectl logs <pod> --previous` to see why the last attempt crashed, then check ConfigMap/Secret values and whether its dependencies (e.g. Postgres) were actually reachable.
- **How would you troubleshoot ImagePullBackOff?** `kubectl describe pod` to see the exact pull error, confirm the image/tag actually exists in ACR, and confirm `attach-acr` was run so the cluster identity has `AcrPull`.

## Azure infrastructure with Terraform

[`terraform-azure-infrastructure/`](terraform-azure-infrastructure/README.md) provisions AKS, ACR, and Azure Key Vault, including AKS image-pull permissions and Key Vault CSI access. See its README for configuration, existing-resource imports, and deployment commands.
