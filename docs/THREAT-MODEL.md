# PGPClaw Threat Model

## Comparison: PGPClaw vs TrustClaw vs Vanilla OpenClaw

This document honestly compares the security posture of three deployment approaches.

### Credential Exposure

| Threat | Vanilla OpenClaw | TrustClaw (Composio) | PGPClaw |
|--------|------------------|----------------------|---------|
| API keys on disk | `.env` file with keys in plaintext | Composio manages keys (SaaS) | Keys in OpenBao only; never on disk |
| Key in process memory | Loaded at startup, persists | Composio proxy handles | Loaded per-request, token revoked after |
| Key in container env | Passed via `--env` or compose | N/A (Composio SaaS) | Fetched from OpenBao inside container, then revoked |
| Backup exposure | Keys in encrypted backup | N/A | OpenBao volume backup (encrypted), no raw keys |

### OAuth Token Security

| Threat | Vanilla OpenClaw | TrustClaw (Composio) | PGPClaw |
|--------|------------------|----------------------|---------|
| Token storage | In OpenClaw credentials dir | Composio cloud vault | Nango self-hosted (Postgres, encrypted) |
| Token refresh | Manual or OpenClaw built-in | Composio handles | Nango handles automatically |
| Token visibility | Agent sees raw token | Agent sees raw token (via Composio SDK) | Agent never sees token (Nango proxy) |
| Per-integration revoke | Delete from credentials dir | Composio dashboard | `./scripts/revoke-integration.sh gmail` |
| Token theft blast radius | All tokens accessible | All Composio-connected tokens | Only tokens in Nango DB |

### Execution Isolation

| Threat | Vanilla OpenClaw | TrustClaw (Composio) | PGPClaw |
|--------|------------------|----------------------|---------|
| Code execution | OpenClaw sandbox (Docker) | OpenClaw sandbox + Composio | Ephemeral `--rm` containers |
| Persistent artifacts | Container may persist | Container may persist | Container destroyed after every task |
| Network access | Configurable | Configurable | Default: `--network none`; opt-in: internal only |
| Filesystem access | Read-only mount | Read-only mount | `--read-only` + no volumes |
| Secret in sandbox | Passed at container creation | Passed at container creation | Fetched inside, revoked after use |

### Prompt Injection Blast Radius

| Threat | Vanilla OpenClaw | TrustClaw (Composio) | PGPClaw |
|--------|------------------|----------------------|---------|
| Agent reads all secrets | If it has env access, yes | Limited by Composio ACLs | AppRole limits to `openclaw/*` path |
| Agent accesses all OAuth | Yes, if configured | Via Composio SDK | Only via Nango proxy (network isolation) |
| Agent persists across tasks | Session state persists | Session state persists | Ephemeral container destroyed |
| Agent modifies config | If file access exists | If file access exists | Read-only filesystem, no config access |

### Operational Security

| Threat | Vanilla OpenClaw | TrustClaw (Composio) | PGPClaw |
|--------|------------------|----------------------|---------|
| Secret rotation | Manual edit of .env | Via Composio dashboard | `./scripts/rotate-secrets.sh` (OpenBao) |
| Emergency lockdown | Kill process | Kill process + Composio revoke | Seal OpenBao + revoke Nango + kill (one command) |
| Audit trail | Application logs only | Composio + application logs | OpenBao audit log + Nango logs + app logs |
| Unseal key protection | N/A | N/A | macOS Keychain |
| Service account | Optional | Optional | Dedicated `secureclaw` user (enforced) |

## PGPClaw Advantages

1. **Zero secrets on disk** — OpenBao + Keychain means no `.env` file with API keys
2. **Agent-opaque OAuth** — Nango proxy means the agent never sees an OAuth token
3. **Ephemeral execution** — Every task container is destroyed; no persistent artifacts
4. **One-command lockdown** — `bao operator seal` instantly cuts all secret access
5. **Per-integration revocation** — Revoke Gmail without touching GitHub
6. **Audit trail** — OpenBao logs every secret access with timestamp and client IP
7. **Dedicated service account** — `secureclaw` user with verified zero-privilege

## PGPClaw Gaps (Honest Assessment)

### vs TrustClaw (Composio)

1. **No managed SLA** — Composio provides a managed service with uptime guarantees. PGPClaw is self-hosted; you are responsible for availability.

2. **No pre-built integrations** — Composio offers 250+ pre-built tool connectors. With PGPClaw + Nango, you must configure each OAuth app manually.

3. **Nango free tier limits** — Nango free self-hosted has limits (connections, proxy requests). Composio's pricing is per-agent, not per-connection.

4. **OpenBao operational burden** — OpenBao requires bootstrapping, unsealing on boot, and monitoring. Composio abstracts this away entirely.

5. **Manual Nango management** — OAuth flows require manual provider registration in the Nango dashboard. Composio auto-discovers many providers.

### Inherent Limitations

1. **Unseal key in Keychain** — If macOS Keychain is compromised, all secrets are exposed. This is the root-of-trust single point of failure.

2. **Single-node deployment** — No HA/clustering. If the machine dies, everything dies. (Mitigated by backups.)

3. **No hardware HSM** — Unseal key is in software (Keychain), not a hardware security module. For higher assurance, consider a YubiKey-backed setup.

4. **OpenBao healthcheck complexity** — `bao status` returns exit 0 when sealed. Custom health checks are required to detect seal state.

5. **Agent trust boundary** — The OpenClaw agent still runs with the `openclaw-agent` AppRole. A sufficiently sophisticated prompt injection could potentially read secrets within the `openclaw/*` path (though it cannot write or access other paths).

6. **No mTLS between components** — Communication between OpenClaw, OpenBao, and Nango is unencrypted on loopback. This is acceptable for single-machine deployment but would need TLS for multi-node.

## Attack Scenarios

### Scenario 1: API Key Compromised

**Vanilla:** Attacker has key indefinitely until manual rotation.
**PGPClaw:** Key is in OpenBao. `bao operator seal` instantly revokes access. Rotate via `store-secret.sh`, unseal, restart.

### Scenario 2: Prompt Injection Exfiltrates OAuth Token

**Vanilla:** Agent has direct access to OAuth token; attacker gets the raw token.
**PGPClaw:** Agent proxies through Nango; never sees the token. Attacker can make API calls via Nango but cannot exfiltrate the token itself.

### Scenario 3: Malicious Code Execution

**Vanilla:** Code runs in sandbox, but sandbox may persist state.
**PGPClaw:** Code runs in `--rm --read-only --network none` container. No persistence, no network, no filesystem writes. Container is destroyed on exit.

### Scenario 4: Full Compromise of Agent Process

**Vanilla:** Attacker has access to all env vars, all OAuth tokens, all file system.
**PGPClaw:** Attacker has access to OpenBao agent token (read-only, 1h TTL). They can read secrets in `openclaw/*` path until the token expires. They cannot access Nango tokens directly (network isolation). **Mitigation:** `./scripts/incident-response.sh full-lockdown` seals OpenBao, revokes Nango, kills everything.
