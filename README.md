# OpenClaw Secure Deployment Kit

Production-hardened deployment package for OpenClaw. Based on the OpenClaw Knowledge Base and Advanced Deployment Playbook.

## What's In The Box

```
openclaw-secure-deploy/
├── config/
│   ├── openclaw.json          # Hardened gateway config (sandbox, rate limits, injection defense)
│   ├── nginx.conf             # Reverse proxy with rate limiting + TLS hardening
│   └── .env.example           # API keys template (copy → .env, never commit)
├── docker/
│   ├── docker-compose.yml     # OpenClaw + Prometheus + Grafana + Alertmanager stack
│   └── seccomp.json           # Docker syscall whitelist for sandboxed sessions
├── monitoring/
│   ├── prometheus.yml         # Scrape config
│   ├── alerts.yml             # Alert rules (cost spikes, auth failures, sandbox failures)
│   ├── alertmanager.yml       # Alert routing config (Slack/email notifications)
│   └── grafana-datasources.yml
├── systemd/
│   └── openclaw-gateway.service  # Hardened systemd unit (non-root, resource limits)
└── scripts/
    ├── setup.sh               # Master install script
    ├── backup.sh              # Encrypted daily backups (local + optional S3)
    ├── rotate-keys.sh         # API key rotation with zero-downtime restart
    └── incident-response.sh   # Runbook automation for common incidents
```

## Quick Start

```bash
# 1. Clone / extract this package
cd openclaw-secure-deploy

# 2. Run setup (production mode)
sudo ./scripts/setup.sh --production

# 3. Fill in your API keys
nano config/.env

# 4. Update allowlists in openclaw config
nano ~/.openclaw/openclaw.json

# 5. Pull sandbox image + run health check
docker pull openclaw/sandbox:1.0.0
openclaw doctor

# 6. Start
systemctl start openclaw-gateway
```

## Security Posture

This config implements **defense-in-depth** across 5 layers:

| Layer | What | Config |
|-------|------|--------|
| **1. Channel Access** | DM pairing required, no open inbound | `channels.*.dmPolicy = "pairing"` |
| **2. Sandboxing** | Non-main sessions run in Docker with no-net, read-only FS, seccomp | `agents.defaults.sandbox` |
| **3. Network** | Gateway bound to loopback only, Tailscale for remote access | `gateway.bind = "loopback"` |
| **4. Credentials** | Env vars only, never in config files, encrypted backups | `.env` + GPG backup |
| **5. Monitoring** | Cost caps, auth failure alerts, suspicious exec detection | `monitoring.alerts` |

## Key Security Decisions

**Sandbox mode = `non-main`** — Your personal DMs run on host (full power), everyone else is jailed in Docker. This is the pragmatic default; flip to `"all"` for paranoid mode.

**No public ports** — Gateway never binds to `0.0.0.0`. Use Tailscale Serve for remote access. SSH tunnel as fallback.

**Cost controls** — Hard cap at $20/hr, $200/day, $2000/month. Gateway pauses and alerts before you get a surprise bill.

**Prompt injection defense** — Regex filters on inbound messages before they hit the model. Not bulletproof, but catches the obvious stuff.

## Incident Response

```bash
# API key leaked
./scripts/incident-response.sh compromised-key

# Prompt injection attack
./scripts/incident-response.sh prompt-injection

# Agent loop burning money
./scripts/incident-response.sh runaway-cost

# Nuclear option (kill everything)
./scripts/incident-response.sh full-lockdown

# Bring it back
./scripts/incident-response.sh restore
```

## Monitoring

Start the full monitoring stack:
```bash
docker compose -f docker/docker-compose.yml up -d
```

- **Prometheus**: http://localhost:9090
- **Grafana**: http://localhost:3000 (login: admin / your GRAFANA_ADMIN_PASSWORD)
- **Alertmanager**: http://localhost:9093

Alerts fire for: API cost spikes, sandbox failures, auth brute-force, gateway downtime.

## Things You MUST Change

1. `config/.env` — All API keys and passwords marked `CHANGE_ME`
2. `config/openclaw.json` — Alert email, allowFrom phone numbers
3. `config/nginx.conf` — Your domain name + SSL cert paths
4. `monitoring/alertmanager.yml` — Uncomment and configure Slack/email receivers
5. `/etc/openclaw/backup-passphrase` — Add a strong passphrase (or set `GPG_RECIPIENT`)

## Things You SHOULD NOT Do

- Set `dmPolicy: "open"` — opens you to spam and injection attacks
- Hardcode API keys in `openclaw.json` — use `.env`
- Expose port 18789 to the internet — use Tailscale or SSH tunnel
- Run as root in production — the systemd service uses a dedicated user
- Skip `openclaw doctor` after changes — it catches misconfigs
- Use the same password for Grafana and gateway — they are separate credentials
- Use `:latest` Docker image tags — pin to specific versions for reproducible deployments

## Pinned Image Versions

All Docker images are pinned for reproducible, secure deployments. Update tags in
`docker/docker-compose.yml` and `config/openclaw.json`, then test before deploying.

| Image | File | Current |
|-------|------|---------|
| `openclaw/openclaw` | docker-compose.yml | 1.0.0 |
| `openclaw/sandbox` | openclaw.json | 1.0.0 |
| `prom/prometheus` | docker-compose.yml | v3.5.1 |
| `grafana/grafana` | docker-compose.yml | 11.5.2 |
| `prom/alertmanager` | docker-compose.yml | v0.27.0 |

## License

This project is provided "as is" under the [MIT License](LICENSE). No warranty, express or implied. Use at your own risk.

## References

- [OpenClaw Docs](https://docs.openclaw.ai)
- [Security Guide](https://docs.openclaw.ai/gateway/security)
- [Docker Sandboxing](https://docs.openclaw.ai/install/docker)
- [MCP Protocol](https://modelcontextprotocol.io)
