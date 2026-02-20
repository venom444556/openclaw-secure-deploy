# PGPClaw

Hardened AI gateway security layer for OpenClaw. Zero secrets on disk, agent-opaque OAuth, ephemeral execution.

## What Is PGPClaw?

PGPClaw wraps OpenClaw with three security components:

1. **OpenBao** (secrets broker) — API keys live in a vault, not in `.env` files. The agent requests short-lived tokens that are revoked after use.
2. **Nango** (OAuth proxy) — OAuth integrations (Gmail, GitHub, etc.) route through a proxy. The agent never sees raw OAuth tokens.
3. **Ephemeral Runner** — Every code execution task runs in a `docker run --rm` container that is destroyed on completion. No persistent artifacts.

## Architecture

```
 User (Telegram / WhatsApp / Discord)
         │
         ▼
   OpenClaw Gateway (secureclaw user, loopback only)
         │
    ┌────┴────┐
    │         │
    ▼         ▼
  OpenBao    Nango Proxy
  (secrets)  (OAuth)
    │         │
    │    ┌────┤
    │    │    │
    │    ▼    ▼
    │  Gmail  GitHub  Notion ...
    │
    ▼
  Ephemeral Runner (--rm)
  [spawned per task, destroyed on completion]
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full system diagram.

## Quick Start

```bash
# 1. Clone
git clone https://github.com/venom444556/pgpclaw.git
cd pgpclaw

# 2. Run setup (creates secureclaw user, bootstraps OpenBao, builds runner)
./scripts/setup.sh --profile core

# 3. Store your first API key
./openbao/scripts/store-secret.sh anthropic-api-key sk-ant-YOUR-KEY

# 4. Start the gateway
./scripts/start-gateway.sh core

# 5. Verify
curl http://localhost:18789/health
```

**Dry-run first:**
```bash
DRY_RUN=true ./scripts/setup.sh --profile core
```

## Profiles

| Profile | Services | Use Case |
|---------|----------|----------|
| `core` | OpenBao + OpenClaw Gateway | Minimal secure deployment |
| `monitoring` | + Prometheus, Grafana, Alertmanager, n8n | Observability |
| `oauth` | + Nango, Postgres, Redis | OAuth integrations |
| `full` | Everything | Complete stack |

## Security Posture

| Layer | Protection | Implementation |
|-------|-----------|----------------|
| **Secrets** | Never on disk | OpenBao vault + macOS Keychain |
| **OAuth** | Agent-opaque tokens | Nango proxy (agent never sees token) |
| **Execution** | Ephemeral containers | `docker run --rm --read-only --network none` |
| **Network** | Loopback only | All ports bound to `127.0.0.1` |
| **Identity** | Dedicated service account | `secureclaw` user (non-login, no sudo) |
| **Monitoring** | Cost caps + auth alerts | Prometheus + Alertmanager |

## Incident Response

```bash
# Seal OpenBao (cuts ALL secret access instantly)
./scripts/incident-response.sh bao-seal

# Revoke a specific OAuth integration
./scripts/revoke-integration.sh gmail

# Revoke ALL OAuth connections
./scripts/incident-response.sh nango-revoke

# Nuclear option: seal + revoke + stop + block
./scripts/incident-response.sh full-lockdown

# Bring everything back
./scripts/incident-response.sh restore
```

See [`docs/REVOCATION.md`](docs/REVOCATION.md) for the full emergency procedures guide.

## Secret Management

```bash
# Store a secret
./openbao/scripts/store-secret.sh anthropic-api-key sk-ant-xxx

# Rotate secrets interactively
./scripts/rotate-secrets.sh all

# Seal OpenBao (emergency)
bao operator seal
```

Secrets are stored in OpenBao KV-v2. The unseal key lives in macOS Keychain. **No secret is ever written to a file on disk.**

## Monitoring

With the `monitoring` or `full` profile:

| Service | URL | Auth |
|---------|-----|------|
| Grafana | http://localhost:3000 | admin / (password in OpenBao) |
| Prometheus | http://localhost:9090 | None |
| Alertmanager | http://localhost:9093 | None |
| n8n | http://localhost:5678 | Create on first launch |

Alerts: API cost spikes, auth failures, OpenBao sealed, sandbox failures, gateway down.

## Pinned Image Versions

| Image | Version |
|-------|---------|
| `openbao/openbao` | 2.5.0 |
| `pgpclaw/openclaw-gateway` | local (openclaw@2026.2.19-2) |
| `nangohq/nango-server` | hosted-0.69.30 |
| `postgres` | 16.0-alpine |
| `redis` | 7.2.4 |
| `prom/prometheus` | v3.5.1 |
| `grafana/grafana` | 11.5.2 |
| `prom/alertmanager` | v0.27.0 |
| `n8nio/n8n` | 2.8.2 |
| `debian` | bookworm-slim |

No `:latest` tags anywhere.

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — System design and component details
- [`docs/THREAT-MODEL.md`](docs/THREAT-MODEL.md) — PGPClaw vs TrustClaw vs vanilla OpenClaw
- [`docs/REVOCATION.md`](docs/REVOCATION.md) — Emergency revocation procedures
- [`SERVICES.md`](SERVICES.md) — Running services reference
- [`POST-DEPLOY.md`](POST-DEPLOY.md) — Post-setup configuration guide

## Things You SHOULD NOT Do

- Store API keys in `.env` files — use OpenBao
- Expose any port to `0.0.0.0` — loopback only, Tailscale for remote
- Run as root — use the `secureclaw` service account
- Use `:latest` Docker tags — pin versions
- Skip `openclaw doctor` after changes
- Give `secureclaw` sudo access

## License

This project is provided "as is" under the [MIT License](LICENSE). No warranty, express or implied. Use at your own risk.

## References

- [OpenClaw Docs](https://docs.openclaw.ai)
- [OpenBao](https://openbao.org)
- [Nango](https://nango.dev)
- [MCP Protocol](https://modelcontextprotocol.io)
