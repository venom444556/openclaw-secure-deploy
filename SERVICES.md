# Running Services

> All commands assume you're in the pgpclaw repository directory.

All services bind to `127.0.0.1` (loopback only). Use Tailscale for remote access.

## Services by Profile

### Core Profile (`--profile core`)

| Service | Container | Port | URL | Data |
|---------|-----------|------|-----|------|
| OpenBao | pgpclaw-openbao | 8200 | http://localhost:8200 | `openbao_data` volume |
| OpenClaw Gateway | pgpclaw-gateway | 18789 | http://localhost:18789 | `~/.openclaw/` |

### Monitoring Profile (`--profile monitoring`)

Includes all Core services, plus:

| Service | Container | Port | URL | Data |
|---------|-----------|------|-----|------|
| Prometheus | pgpclaw-prometheus | 9090 | http://localhost:9090 | `prometheus_data` volume |
| Grafana | pgpclaw-grafana | 3000 | http://localhost:3000 | `grafana_data` volume |
| Alertmanager | pgpclaw-alertmanager | 9093 | http://localhost:9093 | Auto volume |
| Blackbox Exporter | pgpclaw-blackbox | — (internal) | — | Stateless |
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

## Monitoring Architecture

Services are monitored in two ways:

- **Native metrics**: Prometheus, Grafana, and Alertmanager expose `/metrics` endpoints (Prometheus format). Scraped directly.
- **HTTP probes**: OpenBao, Gateway, n8n, and Nango don't expose Prometheus metrics. The Blackbox Exporter probes their health endpoints and reports `probe_success`, `probe_duration_seconds`, etc.

### Grafana Dashboards

Dashboards are provisioned from `monitoring/grafana-dashboards/` (read-only bind mount). To add or modify:

1. Edit JSON files in `monitoring/grafana-dashboards/`
2. Restart Grafana: `docker compose -f docker/docker-compose.yml restart grafana`
3. Or edit in Grafana UI (Edit button) and export JSON

Available dashboards:
- **PGPClaw — Stack Overview**: Service health, response times, alerts, Prometheus engine stats

### Alert Rules

Defined in `monitoring/alerts.yml`. Groups:
- `pgpclaw.health` — Service probe failures and slow responses
- `pgpclaw.scrape` — Scrape target issues
- `pgpclaw.security` — API usage spikes, auth failures, sandbox issues
- `pgpclaw.cost` — Hourly and monthly API cost projections
- `pgpclaw.openbao` — OpenBao health
- `pgpclaw.prometheus` — Storage, memory, config reload
- `pgpclaw.grafana` — Grafana availability
- `pgpclaw.nango` — Nango OAuth proxy health

## Persistence Details

- **Restart policy:** `unless-stopped` — services restart after crashes and Docker Desktop restarts. They stay stopped only after explicit `docker compose down`.
- **Data persistence:** Named Docker volumes survive container restarts, upgrades, and `docker compose down`. Only `docker compose down -v` or `docker volume rm` destroys data.
- **Config files:** Prometheus, Grafana, Alertmanager, and OpenBao configs are bind-mounted read-only. Changes require a service restart.

## Updating the Stack

Use the update script to check for and apply updates across all services:

```bash
# Check what updates are available (read-only, no changes)
./scripts/update-stack.sh

# Apply all available updates (runs backup first)
./scripts/update-stack.sh --apply

# Update a single service
./scripts/update-stack.sh --apply --service grafana

# Rollback to previous versions (from last snapshot)
./scripts/update-stack.sh --rollback
```

The update script:
- Checks Docker Hub + npm registry for latest versions
- Runs `backup.sh` before any changes
- Saves a version snapshot for rollback
- Updates services one-by-one with health check validation
- Automatically rolls back any service that fails its health check
- Logs all actions to `~/.openclaw/logs/updates.log`

### Manual Upgrade (single service)

1. Update the version tag in `docker/docker-compose.yml`
2. Pull: `docker compose -f docker/docker-compose.yml pull <service>`
3. Recreate: `docker compose -f docker/docker-compose.yml up -d <service>`
4. Verify: check logs and health endpoints
5. Data in volumes is preserved across upgrades

## Current Image Versions

| Image | Version |
|-------|---------|
| `openbao/openbao` | 2.5.0 |
| `pgpclaw/openclaw-gateway` | local (openclaw@2026.2.19-2) |
| `nangohq/nango-server` | hosted-0.69.30 |
| `postgres` | 16.12-alpine |
| `redis` | 7.4.7 |
| `prom/prometheus` | v3.9.1 |
| `grafana/grafana` | 12.3.3 |
| `prom/alertmanager` | v0.31.1 |
| `prom/blackbox-exporter` | v0.25.0 |
| `n8nio/n8n` | 2.9.1 |
| `debian` (ephemeral runner base) | bookworm-slim |
