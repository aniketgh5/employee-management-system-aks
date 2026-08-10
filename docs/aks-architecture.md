# AKS Architecture Reference

Companion to `docs/vm-architecture.md`. This document covers the second
deployment model for the **same application**: Azure Kubernetes Service.

---

## 1. High-level flow

```
 Developer
    │
    ▼
 Git Repository
    │
    ▼
 Docker Build  (backend/Dockerfile, frontend/Dockerfile - unchanged app code)
    │
    ▼
 Azure Container Registry (ACR)
    │
    ▼
 AKS
    │
    ├── Frontend Pods   (static site, 2 replicas)
    ├── Backend Pods    (FastAPI, 2-5 replicas via HPA)
    └── PostgreSQL Pod  (1 replica, PVC-backed)
    │
    ▼
 Ingress
    │
    ▼
 Public Access
```

## 2. Kubernetes application architecture

```
                 Internet
                    │
                    ▼
              AKS Ingress
                    │
          ┌─────────┴─────────┐
          │                   │
          ▼                   ▼
   Frontend Service     Backend Service
    (ClusterIP:80)       (ClusterIP:8000)
          │                   │
          ▼                   ▼
   Frontend Pods         Backend Pods
   (nginx-unprivileged)  (FastAPI/Uvicorn)
                              │
                              ▼
                     PostgreSQL Service
                       (ClusterIP:5432)
                              │
                              ▼
                     PostgreSQL Pod
                     (PVC-backed)
```

Only the **Ingress** is reachable from the internet. Everything else -
Frontend Service, Backend Service, PostgreSQL Service - is `ClusterIP`,
meaning it only has a virtual IP that's routable *inside* the cluster.

## 3. Kubernetes objects used, explained simply

| Object | Plain-English purpose | Used for |
|---|---|---|
| **Namespace** | A named "folder" that groups and isolates a set of resources. | `employee-app` holds every resource for this project. |
| **Deployment** | Describes *how many* copies of a Pod to run and *how* to roll out changes to them. Kubernetes keeps the actual count matching the desired count. | `frontend`, `backend`, `postgresql` |
| **Pod** | The smallest deployable unit - one or more containers that share networking/storage. Deployments create/manage Pods for you; you rarely create a Pod directly. | (created automatically by each Deployment) |
| **Service** | A stable virtual IP + DNS name in front of a changing set of Pods, so callers never need to track individual Pod IPs. | `frontend`, `backend`, `postgresql` |
| **ConfigMap** | Non-sensitive key/value configuration, injected into Pods as environment variables (or files). | `employee-config`, `postgres-init-script` |
| **Secret** | Same idea as a ConfigMap, but for sensitive values (base64-encoded at rest, access-controlled via RBAC). | `employee-secret` |
| **PersistentVolumeClaim (PVC)** | A request for durable storage ("give me 5Gi that survives Pod restarts"), independent of any one Pod's lifecycle. | `postgresql-pvc` |
| **Ingress** | Layer-7 (HTTP) routing rules - "path `/api` goes to this Service, path `/` goes to that Service" - fronted by a single public IP. | `employee-ingress` |
| **Liveness Probe** | "Is this container still alive?" - if it fails repeatedly, Kubernetes **restarts** the container. | backend & frontend containers |
| **Readiness Probe** | "Can this Pod receive traffic right now?" - if it fails, Kubernetes **removes the Pod from the Service** (no restart) until it passes again. | backend & frontend containers |
| **Resource Requests** | The CPU/memory a container is *guaranteed* - used for scheduling decisions (which node has room) and for HPA math. | every container |
| **Resource Limits** | The CPU/memory a container is *capped* at - prevents one runaway container starving its node. | every container |
| **HorizontalPodAutoscaler (HPA)** | Watches a metric (here: CPU %) and automatically adds/removes replicas of a Deployment within a min/max range. | `backend-hpa` |
| **SecurityContext** | Per-Pod/per-container hardening flags: run as non-root, drop Linux capabilities, block privilege escalation, read-only root filesystem. | every Pod/container |
| **Labels** | Free-form key/value tags used by *selectors* to group objects (e.g. a Service finding "all Pods with `app: backend`"). | `app`, `app.kubernetes.io/part-of` on everything |
| **Annotations** | Free-form metadata that is *not* used for selection - notes, tool hints, controller configuration (e.g. Ingress-controller-specific settings). | ingress annotations, Prometheus scrape hints |

## 4. Namespace

Everything lives in `employee-app`:

```bash
kubectl get all -n employee-app
```

## 5. ConfigMap / Secret naming (why it "just works")

`backend/app/config.py` already reads these exact environment variable
names: `APP_NAME`, `APP_ENV`, `LOG_LEVEL`, `CORS_ORIGINS`,
`DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME`, `DATABASE_USER`,
`DATABASE_PASSWORD`. `aks/configmap.yaml` and `aks/secret.yaml` use those
exact same keys, and the backend Deployment loads both wholesale with:

```yaml
envFrom:
  - configMapRef: { name: employee-config }
  - secretRef:    { name: employee-secret }
```

Result: **zero application code changes** to run the same backend image
on Kubernetes instead of Docker Compose.

## 6. Database: learning setup vs. production

This project runs PostgreSQL as a plain `Deployment` + `PersistentVolumeClaim`
inside AKS (`aks/database/`). That's a deliberate, clearly-labeled
**learning/demo** choice:

- One replica, no automatic failover.
- A rollout briefly needs the old Pod to fully terminate before the new
  one can mount the same `ReadWriteOnce` disk (`strategy: Recreate`).
- Backups, patching, and HA are entirely your responsibility.

**Production recommendation:** use **Azure Database for PostgreSQL -
Flexible Server** instead. You'd delete `aks/database/*.yaml` and the
`DATABASE_HOST` in the ConfigMap would point at the managed server's
hostname instead of the in-cluster Service - no other application code
changes needed, because the backend already only knows "some Postgres
host" via an environment variable. See "Enterprise Evolution" in the
main README for the full progression.

## 7. Ingress Controller: LEARNING vs ENTERPRISE

**LEARNING VERSION (used by `aks/ingress/ingress.yaml`):**

The community **ingress-nginx** controller, installed via Helm, with
`ingressClassName: nginx`. This is the most widely-documented option and
is what almost every Kubernetes tutorial uses. Good for a hands-on
cluster; you fully control and can inspect its configuration.

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace
```

**ENTERPRISE / PRODUCTION VERSION (not applied by this project - documented
here for the evolution path):**

AKS now offers a managed **"App Routing" add-on**
(`az aks approuting enable --resource-group <RG> --name <CLUSTER>`),
which runs a managed NGINX ingress controller for you and can integrate
with Azure DNS and Key Vault-issued TLS certificates automatically -
`ingressClassName: webapprouting.kubernetes.azure.com`. For larger,
security-sensitive estates, **Azure Application Gateway for Containers**
(or the older AGIC) is the enterprise-grade option: it's an Azure-native
L7 load balancer with WAF, integrates with Private AKS/Private Link, and
is managed outside the cluster's own compute.

**Do not mix these two models in one manifest.** Pick one
`ingressClassName` per environment. This project uses the learning
version so the whole thing is runnable with just `helm install` + `kubectl
apply -k` and no extra Azure resources.

## 8. Ingress vs. Service vs. LoadBalancer vs. NodePort

| Type | Public? | Layer | Typical use |
|---|---|---|---|
| `ClusterIP` (default Service type) | No | L4 (TCP/UDP) | Internal-only traffic between Pods/Services - what `frontend`, `backend`, `postgresql` all use here. |
| `NodePort` | Yes (via `<NodeIP>:<port>`, 30000-32767) | L4 | Rarely used directly in production; mostly a building block or for quick local testing. |
| `LoadBalancer` | Yes (gets a real public/external IP) | L4 | One external IP **per Service** - fine for a single service, wasteful/hard to manage TLS/paths for many. |
| `Ingress` | Yes (one shared entry point) | L7 (HTTP/HTTPS) | Path- and host-based routing to many Services behind **one** IP/LoadBalancer, with TLS termination, in one place. This is why the app uses Ingress instead of giving `frontend` and `backend` their own `LoadBalancer` IPs. |

## 9. Networking / traffic flow

**Frontend request:**
```
Internet → Ingress → Frontend Service (ClusterIP:80) → Frontend Pods (:8080)
```

**API request:**
```
Internet → Ingress → Backend Service (ClusterIP:8000) → Backend Pods (:8000) → PostgreSQL Service (ClusterIP:5432) → PostgreSQL Pod (:5432)
```

## 10. Kubernetes DNS

Every Service automatically gets a cluster-internal DNS name:

```
<service-name>.<namespace>.svc.cluster.local
```

For this project: `postgresql.employee-app.svc.cluster.local`. Because
the backend Pods run in the *same* namespace, the short form `postgresql`
already resolves correctly (that's the value used in `DATABASE_HOST`).

**Why Service names instead of Pod IPs:** Pod IPs are ephemeral - a Pod
that restarts, gets rescheduled, or is replaced during a rolling update
gets a **new** IP. A Service's ClusterIP and DNS name stay constant for
the Service's entire lifetime and always route to whichever Pods are
currently healthy (per the readiness probe), so nothing in the app ever
needs to track individual Pod addresses.

## 11. Autoscaling concepts

| Term | Meaning |
|---|---|
| **Pod** | One running instance of your container(s). |
| **Replica** | A *count* - "how many identical Pods should exist right now." |
| **Deployment** | The controller that keeps the actual Pod count equal to the desired replica count, and manages rolling updates. |
| **HPA** | A controller that *changes the Deployment's replica count automatically* based on an observed metric (here, CPU utilization), within `minReplicas`/`maxReplicas` bounds. |

`aks/backend/hpa.yaml`: `minReplicas: 2`, `maxReplicas: 5`, target 70% CPU
utilization (measured against the container's CPU *request*, which is
why `resources.requests.cpu` must be set for HPA math to work at all).

## 12. Resource requests & limits

| Container | requests (cpu/mem) | limits (cpu/mem) |
|---|---|---|
| backend | 100m / 128Mi | 300m / 256Mi |
| frontend | 50m / 64Mi | 150m / 128Mi |
| postgresql | 100m / 128Mi | 250m / 256Mi |

Sized to comfortably fit a small learning node pool (comparable to the
VM's `Standard_B1s`) while leaving headroom for the HPA to actually scale
the backend up to 5 replicas. **Requests** tell the scheduler "don't
place this Pod somewhere that can't guarantee this much"; **limits**
prevent a single misbehaving container from starving its node of
CPU/memory and taking down unrelated Pods.

## 13. Rolling updates

`backend` and `frontend` Deployments both use:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 1
    maxSurge: 1
```

With `replicas: 2`, this means: at most 1 old Pod is taken down before its
replacement is ready (`maxUnavailable: 1`), and at most 1 extra Pod may
exist temporarily above the desired count while the new version comes up
(`maxSurge: 1`). Net effect: capacity never drops below 1 healthy replica
during a deploy - near-zero-downtime releases, with **no manual
coordination required** (unlike the VM deployment, where you'd
`docker compose up -d --build` and briefly interrupt the single running
container).

```
Old version (2 Pods)
      │
      ▼   new Pod created (surge)
Old ×2, New ×1
      │
      ▼   one old Pod terminated once new Pod is Ready
Old ×1, New ×1
      │
      ▼   repeat until fully replaced
New ×2
```

## 14. Health checks

Both probes hit the application's existing `/health` endpoint - no new
endpoint had to be added to the backend.

- **Readiness = "Can this Pod receive traffic?"** Checked continuously;
  on failure, the Pod is pulled out of its Service's routing (no
  restart) until it passes again. Prevents traffic from reaching a Pod
  that's still starting up or is temporarily overloaded.
- **Liveness = "Is this container still alive?"** On repeated failure,
  Kubernetes kills and restarts the container. Recovers from a hung
  process that's technically running but no longer serving.

## 15. Storage lifecycle

```
Pod
 │  mounts
 ▼
PersistentVolumeClaim (postgresql-pvc: "I need 5Gi, ReadWriteOnce")
 │  satisfied by
 ▼
StorageClass (managed-csi: "how" to provision - Azure Disk, CSI driver)
 │  provisions
 ▼
Azure Disk (the actual durable block storage)
```

`kubectl get storageclass` on your cluster shows what's available; AKS
clusters created recently default to `managed-csi`. As noted above,
production database workloads should preferably use **Azure Database for
PostgreSQL** rather than a self-managed Postgres Pod + PVC.

## 16. Observability (optional, not applied by default)

This deployment doesn't require any extra Azure resources to run, but is
structured so you can bolt on:

- **Azure Monitor + Container Insights** - enable on the AKS cluster
  (`az aks enable-addons -a monitoring ...`) for automatic Pod/node
  CPU, memory, and restart-count dashboards.
- **Log Analytics** - collects container stdout/stderr (the backend
  already logs structured lines to stdout - see `app/main.py`).
- **Application Insights** - request/latency/error tracing if you later
  add the Python SDK to the FastAPI app.

At minimum, keep an eye on: **Pod restarts**, **CPU/memory usage**
against requests & limits, **HTTP error rates**, **request count**,
**application logs**, and **node health** (`kubectl get nodes`,
`kubectl top nodes`).

## 17. Security summary

- Namespace isolation (`employee-app`).
- Non-root containers (`runAsNonRoot: true`) for frontend and backend.
- `readOnlyRootFilesystem: true` on frontend and backend, with `emptyDir`
  volumes for the few paths that need to be writable (`/tmp`, nginx cache/run dirs).
- `allowPrivilegeEscalation: false` and `capabilities: drop: ["ALL"]`
  everywhere.
- Secrets kept in a Kubernetes `Secret`, never in application source or
  container images.
- PostgreSQL and the backend are `ClusterIP`-only - never reachable from
  the internet directly.
- Resource requests/limits on every container.
- Liveness/readiness probes on every workload.

This is intentionally "reasonable for a learning project," not
exhaustive - see the README's "Enterprise Evolution" section for what a
production security posture (Key Vault, Private AKS, Azure Firewall,
Policy) adds on top.
