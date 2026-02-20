# Running Services

All services bind to `127.0.0.1` (loopback only — not accessible from the network).
All services use `restart: unless-stopped` and will auto-start with Docker Desktop.

## Services

| Service | Container | Port | URL | Data Persistent |
|---------|-----------|------|-----|-----------------|
| Prometheus | openclaw-prometheus | 9090 | http://localhost:9090 | Yes (`prometheus_data` volume) |
| Grafana | openclaw-grafana | 3000 | http://localhost:3000 | Yes (`grafana_data` volume) |
| Alertmanager | openclaw-alertmanager | 9093 | http://localhost:9093 | Yes (auto volume) |
| n8n | openclaw-n8n | 5678 | http://localhost:5678 | Yes (`n8n_data` volume) |
| OpenClaw Gateway | — | 18789 | http://localhost:18789 | Config in `~/.openclaw/` |

**Note:** The OpenClaw Gateway runs natively (not in Docker) and must be started manually after adding your API key. See `POST-DEPLOY.md`.

## Common Commands

### Start all services
```bash
docker compose -f /Users/devserver/Documents/OpenClaw/openclaw-secure-deploy/docker/docker-compose.yml up -d prometheus grafana alertmanager n8n
```

### Stop all services
```bash
docker compose -f /Users/devserver/Documents/OpenClaw/openclaw-secure-deploy/docker/docker-compose.yml down
```

### Restart a single service
```bash
docker compose -f /Users/devserver/Documents/OpenClaw/openclaw-secure-deploy/docker/docker-compose.yml restart <service>
```

### View logs
```bash
docker logs openclaw-prometheus
docker logs openclaw-grafana
docker logs openclaw-alertmanager
docker logs openclaw-n8n
```

### Follow logs (live)
```bash
docker logs -f openclaw-n8n
```

### Check status
```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

## Data & Volumes

| Volume | Used By | Contains | Backup? |
|--------|---------|----------|---------|
| `prometheus_data` | Prometheus | Metrics (30 day retention, 5GB cap) | Not backed up (re-scrapeable) |
| `grafana_data` | Grafana | Dashboards, users, preferences | Back up if customized |
| `n8n_data` | n8n | Workflows, credentials, execution history | Back up before upgrades |

### Back up a volume
```bash
docker run --rm -v docker_n8n_data:/data -v $(pwd):/backup alpine tar czf /backup/n8n-backup.tar.gz -C /data .
```

### Restore a volume
```bash
docker run --rm -v docker_n8n_data:/data -v $(pwd):/backup alpine tar xzf /backup/n8n-backup.tar.gz -C /data
```

## Persistence Details

- **Restart policy:** `unless-stopped` — services restart automatically after a crash or Docker Desktop restart. They stay stopped only if you explicitly run `docker compose down` or `docker stop`.
- **Data persistence:** All services use named Docker volumes. Data survives container restarts, image upgrades, and `docker compose down`. Data is only lost if you explicitly remove volumes with `docker compose down -v` or `docker volume rm`.
- **Config files:** Prometheus, Grafana, and Alertmanager configs are bind-mounted read-only from the deploy directory. Changes require a service restart.

## Upgrading

1. Update the image tag in `docker/docker-compose.yml`
2. Pull the new image: `docker compose pull <service>`
3. Recreate the container: `docker compose up -d <service>`
4. Data in volumes is preserved across upgrades

## Current Image Versions

| Image | Version |
|-------|---------|
| `prom/prometheus` | v3.5.1 |
| `grafana/grafana` | 11.5.2 |
| `prom/alertmanager` | v0.27.0 |
| `n8nio/n8n` | 2.8.2 |
