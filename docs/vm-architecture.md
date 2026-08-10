# Architecture Reference

Extended diagrams supporting the top-level README. See README.md sections
1 and 9 for the narrative walkthrough - this file is the quick-reference
version for pinning up next to your terminal during deployment.

---

## 1. Azure infrastructure (already provisioned via Terraform)

```
                         Internet
                             |
                             | Static Public IP
                             v
                    +-------------------+
                    |   Azure NIC        |
                    +-------------------+
                             |
                             v
              +-------------------------------+
              |     vm-alzvm-app01 (Ubuntu)    |
              |     Standard_B1s                |
              |     Spoke VNet: 10.20.0.0/16    |
              |     App subnet: 10.20.1.0/24    |
              +-------------------------------+
                             |
                       Hub-Spoke peering
                             |
                    +-------------------+
                    |   Hub VNet         |
                    |   vnet-alzvm-hub   |
                    +-------------------+

  Other spoke subnets (provisioned, not used by this app):
    Data subnet:       10.20.2.0/24
    Management subnet: 10.20.10.0/24

  Network Security Groups control inbound/outbound traffic to the VM
  (must allow inbound TCP 80/443 for this application to be reachable).
```

## 2. Container architecture (inside the VM)

```
 vm-alzvm-app01 (Ubuntu 22.04)
 ┌───────────────────────────────────────────────────────────────┐
 │  Docker Engine                                                  │
 │                                                                   │
 │   Docker network: emp-network (bridge)                          │
 │  ┌───────────┐   ┌───────────┐   ┌───────────┐                 │
 │  │  nginx    │──▶│  backend  │──▶│ postgres  │                 │
 │  │ :80 (host)│   │  :8000    │   │  :5432    │                 │
 │  │  healthy  │   │  healthy  │   │  healthy  │                 │
 │  └───────────┘   └───────────┘   └───────────┘                 │
 │       │                                  │                      │
 │       │ port 80 published to host        │ named volume         │
 │       ▼                                  ▼                      │
 │   Host :80                        postgres_data (persisted)     │
 └───────────────────────────────────────────────────────────────┘
```

## 3. Request flow: `GET /api/employees?search=aniket`

```
Browser
  │  GET http://<VM_PUBLIC_IP>/api/employees?search=aniket
  ▼
Nginx (container, :80)
  │  location /api/  → proxy_pass http://backend:8000/api/
  │  (uses Docker DNS service name "backend", never localhost)
  ▼
FastAPI backend (container, :8000)
  │  router: app/routers/employees.py -> list_employees()
  │  service: app/services/employee_service.py -> get_employees()
  ▼
SQLAlchemy -> psycopg2 -> PostgreSQL (container, :5432)
  │  SELECT * FROM employees WHERE first_name ILIKE '%aniket%' OR ...
  ▼
Rows returned -> serialized via Pydantic EmployeeResponse -> JSON
  ▼
Nginx passes the JSON response back unchanged
  ▼
Browser renders the filtered table
```

## 4. Health check chain

```
docker compose ps
  │
  ├─ postgres healthcheck:  pg_isready -U <user> -d <db>
  │
  ├─ backend healthcheck:   curl -fsS http://localhost:8000/health
  │        (backend "depends_on: postgres" with condition: service_healthy,
  │         so it only starts accepting traffic once Postgres is ready)
  │
  └─ nginx healthcheck:     curl -fsS http://localhost/
           (nginx "depends_on: backend" with condition: service_healthy)
```

This ordering guarantees that when `docker compose ps` shows all three
containers as `healthy`, the full request chain (Nginx → FastAPI →
PostgreSQL) is actually working end-to-end - not just that the processes
started.

## 5. CI/CD pipeline shape (Azure Pipelines)

```
 git push
    │
    ▼
 ┌─────────┐     ┌──────────────────┐     ┌───────────────────┐
 │  Test   │ --> │      Build        │ --> │      Deploy         │
 │ pytest  │     │ docker build      │     │ SSH into Azure VM   │
 │         │     │ tag :BuildId+SHA  │     │ git pull            │
 │         │     │ (push: placeholder)│     │ docker compose up -d│
 └─────────┘     └──────────────────┘     └───────────────────┘
```

See `.azure-pipelines/azure-pipelines.yml` and README section 11 for the
full pipeline definition and activation steps.
