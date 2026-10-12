# TenantGuard

TenantGuard is a multi-tenant isolation and noisy-neighbor defense platform.

## What this project does

- Enforces tenant quotas and admission limits
- Schedules workloads fairly using cost-aware deficit round robin
- Detects noisy-neighbor behavior across CPU, memory and DB contention
- Applies adaptive throttling and isolation controls
- Exposes a live operations dashboard

## Stack

- Go for scheduler and control plane
- Docker + cgroup v2 for tenant isolation
- PostgreSQL for policy/state storage
- Redis for quotas and rate limiting
- Python + FastAPI for predictor service
- Next.js + TypeScript for dashboard

## Run locally

```bash
docker compose up --build
```

Then open:
- Dashboard: http://localhost:3000
- API: http://localhost:8080/health
- Prometheus: http://localhost:9090
- Grafana: http://localhost:9091

## Project layout

```text
api/
predictor/
dashboard/
db/
config/
Dockerfile.api
docker-compose.yml
README.md
.env.example
```
