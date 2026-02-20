# Running Services

> All commands assume you're in the pgpclaw repository directory.

All services bind to `127.0.0.1` (loopback only). Use Tailscale for remote access.

## Services by Profile

### Core Profile (`--profile core`)

| Service | Container | Port | URL | Data |
|---------|-----------|------|-----|------|
| OpenBao | pgpclaw-openbao | 8200 | http://localhost:8200 | `openbao_data` volume |
| OpenClaw Gateway | pgpclaw-openclaw | 18789 | http://localhost:18789 | `~/.openclaw/` |

### Monitoring Profile (`--profile monitoring`)

Includes all Core services, plus:

| Service | Container | Port | URL | Data |
|---------|-----------|------|-----|------|
| Prometheus | pgpclaw-prometheus | 9090 | http://localhost:9090 | `prometheus_data` volume |
| Grafana | pgpclaw-grafana | 3000 | http://localhost:3000 | `grafana_data` volume |
| Alertmanager | pgpclaw-alertmanager | 9093 | http://localhost:9093 | Auto volume |
| n8n | pgpclaw-n8n | 5678 | http://localhost:5678 | `n8n_data` volume |

### OAuth Profile (`--profile oauth`)

Includes all Core services, plus:

| Service | Container | Port | URL | Data |
|---------|-----------|------|-----|------|
| Nango Server | pgpclaw-nango-server | 3003, 3009 | http://localhost:3003 | Via Postgres |
| Nango DB | pgpclaw-nango-db | — (internal) | — | `nango_db_data` volume |
| Nango Redis | pgpclaw-nango-redis | — (internal) | — | `nango_redis_data` volume |

### Full Profile (`--profile full`)

All services from all profiles above.

### Build Profile (`--profile build`)

| Service | Container | Port | URL | Purpose |
|---------|-----------|------|-----|---------|
| runner-build | — | — | — | Builds `pgpclaw/ephemeral-runner:local` image |

## Common Commands

### Start with a profile
```bash
./scripts/start-gateway.sh core          # Minimal
./scripts/start-gateway.sh full          # Everything
./scripts/start-gateway.sh monitoring    # Core + monitoring
```

### Manual Docker Compose
```bash
# Start specific profile
docker compose -f docker/docker-compose.yml --profile core up -d

# Stop everything
docker compose -f docker/docker-compose.yml --profile full down

# Restart a single service
docker compose -f docker/docker-compose.yml restart openbao

# Build ephemeral runner image
docker compose -f docker/docker-compose.yml --profile build build
```

### View logs
```bash
docker logs pgpclaw-openbao
docker logs pgpclaw-openclaw
docker logs pgpclaw-prometheus
docker logs pgpclaw-grafana
docker logs pgpclaw-nango-server
```

### Follow logs (live)
```bash
docker logs -f pgpclaw-openbao
```

### Check status
```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

### OpenBao status
```bash
bao status
```

## Data & Volumes

| Volume | Used By | Contains | Backup? |
|--------|---------|----------|---------|
| `openbao_data` | OpenBao | Encrypted secrets, policies | **Yes** (via `backup.sh`) |
| `openbao_audit` | OpenBao | Audit logs | Yes (via `backup.sh`) |
| `prometheus_data` | Prometheus | Metrics (30 day retention) | Optional (re-scrapeable) |
| `grafana_data` | Grafana | Dashboards, preferences | Back up if customized |
| `n8n_data` | n8n | Workflows, execution history | Back up before upgrades |
| `nango_db_data` | Nango Postgres | OAuth connections, metadata | **Yes** (via `backup.sh` pg_dump) |
| `nango_redis_data` | Nango Redis | Cache | No (ephemeral) |

### Back up a volume manually
```bash
docker run --rm -v openbao_data:/source:ro -v $(pwd):/backup \
  debian:bookworm-slim tar czf /backup/openbao-backup.tar.gz -C /source .
```

### Automated backups
```bash
./scripts/backup.sh
```

This backs up: OpenClaw config, OpenBao volume (encrypted), OpenBao audit logs, Nango DB dump (encrypted), recent sessions, and logs.

## Networks

| Network | Type | Purpose |
|---------|------|---------|
| `pgpclaw-internal` | Bridge (internal) | Inter-container communication (no internet) |
| Host network | — | OpenClaw gateway (loopback access to OpenBao) |

**Note:** `pgpclaw-internal` has `internal: true`, meaning containers on it **cannot reach the internet**. This is by design.

## Persistence Details

- **Restart policy:** `unless-stopped` — services restart after crashes and Docker Desktop restarts. They stay stopped only after explicit `docker compose down`.
- **Data persistence:** Named Docker volumes survive container restarts, upgrades, and `docker compose down`. Only `docker compose down -v` or `docker volume rm` destroys data.
- **Config files:** Prometheus, Grafana, Alertmanager, and OpenBao configs are bind-mounted read-only. Changes require a service restart.

## Upgrading Images

1. Update the version tag in `docker/docker-compose.yml`
2. Pull: `docker compose -f docker/docker-compose.yml pull <service>`
3. Recreate: `docker compose -f docker/docker-compose.yml up -d <service>`
4. Verify: check logs and health endpoints
5. Data in volumes is preserved across upgrades

## Current Image Versions

| Image | Version |
|-------|---------|
| `openbao/openbao` | 2.5.0 |
| `openclaw/openclaw` | 1.0.0 |
| `nangohq/nango-server` | hosted-0.69.30 |
| `postgres` | 16.0-alpine |
| `redis` | 7.2.4 |
| `prom/prometheus` | v3.5.1 |
| `grafana/grafana` | 11.5.2 |
| `prom/alertmanager` | v0.27.0 |
| `n8nio/n8n` | 2.8.2 |
| `debian` (ephemeral runner base) | bookworm-slim |
