# PGPClaw Architecture

## System Overview

PGPClaw is a hardened security layer for OpenClaw that ensures the AI agent **never holds raw credentials** and **every task runs in a disposable container**.

```
 User (Telegram / WhatsApp / Discord)
         │
         ▼
   ┌─────────────────────────────────────────┐
   │   OpenClaw Gateway                      │
   │   (secureclaw user, loopback only)      │
   │   Port 18789 on 127.0.0.1              │
   └────────┬──────────────┬─────────────────┘
            │              │
   ┌────────▼──────┐  ┌───▼──────────────────┐
   │   OpenBao     │  │   Nango Proxy         │
   │   (secrets)   │  │   (OAuth broker)      │
   │   :8200       │  │   :3003 / :3009       │
   └────────┬──────┘  └───┬──────────────────┘
            │              │
            │         ┌────┤
            │         │    │
            │         ▼    ▼
            │       Gmail  GitHub  Notion  Slack ...
            │
            ▼
   ┌─────────────────────────────────┐
   │   Ephemeral Runner              │
   │   docker run --rm               │
   │   [spawned per task,            │
   │    destroyed on completion]     │
   └─────────────────────────────────┘
```

## Components

### 1. OpenBao (Secrets Broker)

**Image:** `openbao/openbao:2.5.0`

OpenBao is the Linux Foundation fork of HashiCorp Vault. It stores all secrets (API keys, tokens, passwords) and issues short-lived tokens to consumers.

**How it works:**
- On bootstrap, OpenBao is initialized with a single unseal key stored in macOS Keychain
- Two AppRoles are created:
  - `openclaw-agent` — read-only access to secrets (TTL=1h, max=4h)
  - `openclaw-admin` — read-write for secret management (TTL=15m, max=1h)
- The gateway authenticates via `openclaw-agent` AppRole at startup
- Ephemeral runners authenticate via the same AppRole per-task
- Tokens are revoked immediately after use

**Key files:**
- `openbao/config.hcl` — Server config (loopback, file storage, no UI)
- `openbao/policies/` — Least-privilege policies
- `openbao/scripts/bootstrap-bao.sh` — One-time init
- `openbao/scripts/unseal-bao.sh` — Boot-time unseal from Keychain
- `openbao/scripts/store-secret.sh` — Write a secret

### 2. Nango (OAuth Broker)

**Image:** `nangohq/nango-server:hosted-0.69.30`

Nango is a self-hosted OAuth proxy. Instead of storing OAuth tokens, the agent routes API calls through Nango, which handles token refresh and injection.

**How it works:**
- OAuth apps are registered in the Nango dashboard
- Users authorize integrations via Nango's OAuth flow
- The agent calls Nango's proxy endpoint: `http://localhost:3003/proxy/{provider}/{endpoint}`
- Nango injects the OAuth token into the upstream request
- The agent never sees the raw OAuth token

**Supporting services:**
- PostgreSQL 16 (Nango metadata)
- Redis 7.2.4 (Nango cache)

**Key files:**
- `nango/scripts/setup-nango.sh` — First-run configuration
- `nango/scripts/revoke-nango.sh` — Per-integration revocation

### 3. Ephemeral Runner (Execution Sandbox)

**Image:** `pgpclaw/ephemeral-runner:local` (built locally from `debian:bookworm-slim`)

Every code execution task runs in a fresh container that is destroyed on completion.

**How it works:**
1. Gateway spawns: `docker run --rm --network none --read-only pgpclaw/ephemeral-runner:local`
2. The entrypoint authenticates to OpenBao via HTTP API
3. Requested secrets are fetched into environment variables
4. The task command executes
5. The OpenBao token is revoked
6. Container exits and is destroyed (`--rm`)

**Security constraints:**
- `--read-only` filesystem
- `--network none` (default) or `--network pgpclaw-internal` (for Nango access)
- Non-root user (`runner`, UID 1000)
- Seccomp profile applied
- `--cap-drop ALL`

**Key files:**
- `docker/ephemeral-runner/Dockerfile`
- `docker/ephemeral-runner/entrypoint.sh`

### 4. OpenClaw Gateway

**Image:** `pgpclaw/openclaw-gateway:local` (built from `openclaw@2026.2.19-2` via npm)

The gateway runs with port mapping (`127.0.0.1:18789:18789`) and serves as the AI agent interface. On Docker Desktop (macOS), `network_mode: host` doesn't provide true host network access, so explicit port mapping is used instead.

## Network Architecture

```
┌─────────────────────────────────────────────────────┐
│  Host Network (loopback only — 127.0.0.1)           │
│                                                     │
│  ┌──────────────┐  ┌──────────────┐                 │
│  │ OpenClaw GW  │  │  OpenBao     │                 │
│  │ :18789       │  │  :8200       │                 │
│  └──────┬───────┘  └──────┬───────┘                 │
│         │                 │                         │
│    host port binding  host port binding             │
│         │                 │                         │
└─────────┼─────────────────┼─────────────────────────┘
          │                 │
┌─────────┼─────────────────┼─────────────────────────┐
│  pgpclaw-internal (Docker bridge, internal: true)   │
│         │                 │                         │
│  ┌──────┴───────┐  ┌─────┴────────┐                │
│  │ Nango Server │  │ OpenBao      │                │
│  │ :3003 :3009  │  │ (container)  │                │
│  └──────┬───────┘  └──────────────┘                │
│         │                                           │
│  ┌──────┴───────┐  ┌──────────────┐                │
│  │ Nango DB     │  │ Nango Redis  │                │
│  │ (no host     │  │ (no host     │                │
│  │  port)       │  │  port)       │                │
│  └──────────────┘  └──────────────┘                │
│                                                     │
│  ┌──────────────────────────────────┐               │
│  │ Ephemeral Runner (when networked)│               │
│  │ Can reach Nango, cannot reach    │               │
│  │ internet directly                │               │
│  └──────────────────────────────────┘               │
└─────────────────────────────────────────────────────┘
```

**Key principle:** The `pgpclaw-internal` network has `internal: true`, which means containers on it **cannot reach the internet directly**. They can only communicate with other containers on the same network.

## 4-Tier Routing

| Tier | Use Case | Network | Example |
|------|----------|---------|---------|
| 1 — Direct API | API key from OpenBao | Host loopback | Anthropic Claude, OpenAI |
| 2 — Nango Proxy | OAuth-protected APIs | pgpclaw-internal | Gmail, GitHub, Google Drive |
| 3 — Ephemeral Isolated | Code execution (no network) | `--network none` | Python scripts, shell commands |
| 4 — Ephemeral Networked | Code + OAuth API access | pgpclaw-internal | Tasks needing both code and API |

## Docker Compose Profiles

| Profile | Services |
|---------|----------|
| `core` | OpenBao + OpenClaw Gateway |
| `monitoring` | + Prometheus, Grafana, Alertmanager, n8n |
| `oauth` | + Nango Server, Nango DB, Nango Redis |
| `full` | Everything |
| `build` | Ephemeral runner image build only |

Start with a profile:
```bash
./scripts/start-gateway.sh core        # Minimal
./scripts/start-gateway.sh full        # Everything
```

## Secret Flow

```
1. Boot
   ├── launchd starts OpenBao container
   ├── unseal-bao.sh reads unseal key from Keychain
   └── OpenBao is ready

2. Gateway Start
   ├── start-gateway.sh authenticates via agent AppRole (from Keychain)
   ├── Fetches all secrets from OpenBao KV-v2
   ├── Exports to environment variables
   ├── Revokes the short-lived token
   └── Runs docker compose up

3. Task Execution
   ├── Gateway spawns ephemeral runner
   ├── Runner authenticates to OpenBao (AppRole via env var)
   ├── Fetches only the secrets it needs
   ├── Executes task
   ├── Revokes token
   └── Container destroyed (--rm)
```

**Result:** No secret ever exists on disk. Secrets live in OpenBao (encrypted at rest) and macOS Keychain (for unseal/AppRole credentials).

## Service Account: secureclaw

The `secureclaw` user is a dedicated service account with:
- Non-login shell (`/usr/bin/false`)
- No sudo access (validated during setup)
- Not in admin/sudo/wheel groups
- Owns `~secureclaw/.openclaw/` directory tree
- All PGPClaw processes run under this account
