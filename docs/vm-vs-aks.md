# VM vs. AKS: Same Application, Two Deployment Platforms

Both deployment models run the **exact same source code**
(`backend/`, `frontend/`, `database/init.sql`) - only the deployment
artifacts differ (`docker-compose.yml` + `nginx/` vs. `aks/`).

```
 VM MODEL                              AKS MODEL
 ─────────                              ──────────
 Developer                              Developer
    │                                      │
    ▼                                      ▼
 Docker                                 Docker
    │                                      │
    ▼                                      ▼
 Azure VM                               ACR
    │                                      │
    ├── Nginx                              ▼
    ├── FastAPI                          AKS
    └── PostgreSQL                         │
                                            ├── Frontend Pods
                                            ├── Backend Pods
                                            └── PostgreSQL
```

## Side-by-side comparison

| Dimension | VM (Docker Compose) | AKS (Kubernetes) |
|---|---|---|
| **Deployment unit** | 3 containers on 1 VM, orchestrated by Docker Compose | 3 workloads spread across cluster nodes, orchestrated by the Kubernetes control plane |
| **Scaling** | Manual - resize the VM or run more containers by hand; no automatic reaction to load | `backend-hpa` automatically scales the backend 2→5 replicas on CPU; frontend/backend replica counts are declarative |
| **Networking** | Docker bridge network + one Nginx container doing both static serving and reverse-proxying | Kubernetes Services (ClusterIP) + DNS-based service discovery + Ingress doing L7 routing across dedicated frontend/backend Services |
| **High availability** | Single VM = single point of failure; a VM reboot takes the whole app down | Multiple replicas of frontend/backend across nodes; a Pod or even a node failing doesn't take the app down (Postgres itself is still single-replica in this learning setup - see AKS docs) |
| **Self-healing** | `restart: unless-stopped` restarts a crashed container on the same VM; the VM itself has no automatic recovery | Kubernetes reschedules failed Pods automatically, on a different node if needed; liveness probes restart hung containers, readiness probes stop routing to unhealthy ones |
| **Rolling updates** | `docker compose up -d --build` briefly stops and replaces each container in place | `RollingUpdate` strategy with `maxUnavailable`/`maxSurge` replaces Pods gradually with defined availability guarantees during the rollout |
| **Load balancing** | Nginx round-robins... nothing - there's only ever 1 backend container | Kubernetes Services load-balance across all healthy replicas automatically |
| **Storage** | Docker named volume (`postgres_data`) tied to that one VM's disk | PersistentVolumeClaim → Azure Managed Disk, decoupled from any specific node |
| **Security** | OS-level hardening is manual (patch the VM yourself); NSG controls perimeter | Namespace isolation, per-container SecurityContext (non-root, read-only rootfs, dropped capabilities), Secrets, cluster RBAC, `AcrPull` managed identity instead of stored registry passwords |
| **Monitoring** | `docker compose logs`, manual `top`/`htop` on the VM | Ready to plug into Azure Monitor / Container Insights / Log Analytics; `kubectl top`, `kubectl get events` built in |
| **CI/CD** | `vm-deploy.yml`: SSH in, `git pull`, `docker compose up -d --build` | `aks-deploy.yml`: build+push images to ACR, `kubectl apply -k aks/`, automated smoke test against the live Ingress |
| **Operational overhead** | Low - one VM, a handful of `docker compose` commands, easy to reason about end-to-end | Higher - a whole cluster to understand (nodes, Services, Ingress controller, RBAC, storage classes) but that complexity buys you the properties above |
| **Cost (learning scale)** | Cheapest - one `Standard_B1s` VM | Higher - a managed control plane (free tier available) + at least 1-2 worker nodes running continuously, even at low traffic |

## When each makes sense

**VM + Docker Compose** is the right call when:
- You're learning the fundamentals of containers, reverse proxies, and Linux deployment.
- The whole application comfortably fits on one machine and doesn't need to scale elastically.
- Operational simplicity matters more than high availability.
- Budget is tight and traffic is low/predictable.

**AKS** is the right call when:
- You need the application to survive a node/VM failure without manual intervention.
- Traffic is variable enough that automatic scaling saves real money or handles real spikes.
- You're running (or plan to run) many services, not just one, and want a consistent platform for all of them.
- You need enterprise controls: RBAC, network policy, managed TLS, integration with Azure AD, Key Vault, Private Link, etc.

## The point of building both

This project intentionally deploys the **same three application
components** (frontend, backend, database) two different ways so the
platform trade-offs above are visible in real manifests and commands,
not just theory - useful both as a learning exercise and as a concrete
talking point in a DevOps interview (see README "Interview Talking Points").
