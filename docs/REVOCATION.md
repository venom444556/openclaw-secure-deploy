# PGPClaw Revocation Guide

Emergency procedures for revoking access at every level of the PGPClaw stack.

## Quick Reference

| Action | Command | Effect |
|--------|---------|--------|
| Seal OpenBao | `./scripts/incident-response.sh bao-seal` | Cuts ALL secret access instantly |
| Revoke one integration | `./scripts/revoke-integration.sh gmail` | Revokes specific OAuth connection |
| Revoke all OAuth | `./scripts/incident-response.sh nango-revoke` | Revokes ALL Nango connections |
| Full lockdown | `./scripts/incident-response.sh full-lockdown` | Seal + revoke + stop + block |
| Restore | `./scripts/incident-response.sh restore` | Unseal + restart + reconnect |

## Level 1: Seal OpenBao (Fastest)

**When:** You need to immediately cut off all secret access.

**What happens:** OpenBao becomes sealed. No process can read any secret. The gateway and all integrations stop working immediately.

```bash
# Via incident response script (recommended)
./scripts/incident-response.sh bao-seal

# Or directly via CLI
bao operator seal
```

**Recovery:**
```bash
./openbao/scripts/unseal-bao.sh
./scripts/start-gateway.sh
```

**Time to effect:** Immediate (< 1 second)

## Level 2: Revoke Specific Integration

**When:** A single OAuth integration (e.g., Gmail) is compromised but others are fine.

**What happens:** The OAuth connection for that specific provider is deleted from Nango. The agent can no longer make API calls to that provider.

```bash
# Revoke Gmail
./scripts/revoke-integration.sh gmail

# Revoke GitHub
./scripts/revoke-integration.sh github

# Revoke with dry-run first
DRY_RUN=true ./scripts/revoke-integration.sh gmail
```

**Recovery:** Re-authorize the integration via the Nango dashboard at `http://localhost:3003`.

**Time to effect:** < 5 seconds

## Level 3: Revoke All OAuth Connections

**When:** Multiple integrations may be compromised, or you want to do a clean sweep.

**What happens:** All Nango OAuth connections are deleted. The agent cannot access any OAuth-protected API.

```bash
./scripts/incident-response.sh nango-revoke
```

**Recovery:** Re-authorize each integration individually via the Nango dashboard.

**Time to effect:** < 10 seconds

## Level 4: Rotate API Keys

**When:** An API key (Anthropic, OpenAI, etc.) has been compromised.

**What happens:** You rotate the key at the provider, then update it in OpenBao. No file changes needed.

```bash
# 1. Go to the provider dashboard and revoke the old key, generate a new one

# 2. Store the new key in OpenBao
./openbao/scripts/store-secret.sh anthropic-api-key sk-ant-NEW-KEY-HERE

# 3. Restart the gateway to pick up the new key
./scripts/start-gateway.sh
```

**For interactive rotation of all keys:**
```bash
./scripts/rotate-secrets.sh all
```

## Level 5: Revoke OpenBao AppRole

**When:** You suspect the AppRole credentials (role-id/secret-id) stored in Keychain have been compromised.

**What happens:** The current AppRole secret-id is invalidated. No process can authenticate to OpenBao with the old credentials.

```bash
# 1. Unseal OpenBao if needed
./openbao/scripts/unseal-bao.sh

# 2. Generate new secret-id for the agent role
# (requires admin AppRole credentials from Keychain)
BAO_ADDR=http://127.0.0.1:8200

# Authenticate as admin
ADMIN_ROLE_ID=$(security find-generic-password -s pgpclaw-openbao -a admin-role-id -w)
ADMIN_SECRET_ID=$(security find-generic-password -s pgpclaw-openbao -a admin-secret-id -w)
ADMIN_TOKEN=$(curl -sf -X POST "${BAO_ADDR}/v1/auth/approle/login" \
  -d "{\"role_id\":\"${ADMIN_ROLE_ID}\",\"secret_id\":\"${ADMIN_SECRET_ID}\"}" \
  | jq -r '.auth.client_token')

# Destroy old secret-id and generate new one
curl -sf -X POST "${BAO_ADDR}/v1/auth/approle/role/openclaw-agent/secret-id" \
  -H "X-Vault-Token: ${ADMIN_TOKEN}" | jq -r '.data.secret_id' > /tmp/new-secret-id

# Update Keychain
security delete-generic-password -s pgpclaw-openbao -a agent-secret-id 2>/dev/null || true
security add-generic-password -s pgpclaw-openbao -a agent-secret-id -w "$(cat /tmp/new-secret-id)"
rm -f /tmp/new-secret-id

# Revoke admin token
curl -sf -X POST "${BAO_ADDR}/v1/auth/token/revoke-self" \
  -H "X-Vault-Token: ${ADMIN_TOKEN}" || true

# 3. Restart gateway
./scripts/start-gateway.sh
```

## Level 6: Full Lockdown (Nuclear Option)

**When:** Full system compromise suspected. You want to cut everything immediately.

**What happens:**
1. OpenBao is sealed (all secrets inaccessible)
2. All Nango OAuth connections are revoked
3. All Docker containers are stopped
4. Firewall rules block the gateway port
5. Tailscale is disconnected

```bash
./scripts/incident-response.sh full-lockdown
```

**Recovery:**
```bash
./scripts/incident-response.sh restore
```

After restore, you must:
1. Re-authorize all OAuth integrations in the Nango dashboard
2. Verify all secrets are still valid
3. Review audit logs for unauthorized access

## Audit Logs

After any revocation event, review these logs:

```bash
# OpenBao audit log (every secret access)
docker logs pgpclaw-openbao 2>&1 | grep -i "auth\|secret\|revoke"

# Nango revocation audit
cat ~/.openclaw/logs/revocation-audit.log

# Incident response log
cat ~/.openclaw/logs/incidents.log

# Gateway log (for suspicious activity)
cat ~/.openclaw/logs/gateway.log | tail -200
```

## Revocation Checklist

For a full security incident, work through this checklist in order:

- [ ] Seal OpenBao (`./scripts/incident-response.sh bao-seal`)
- [ ] Stop the gateway (automatic after seal)
- [ ] Revoke compromised API keys at the provider dashboard
- [ ] Revoke Nango OAuth connections if applicable
- [ ] Review OpenBao audit logs for unauthorized reads
- [ ] Review Nango logs for unauthorized proxy calls
- [ ] Rotate AppRole secret-ids (see Level 5)
- [ ] Store new API keys in OpenBao
- [ ] Unseal OpenBao
- [ ] Restart gateway
- [ ] Re-authorize OAuth integrations
- [ ] Run smoke test: `curl http://localhost:18789/health`
- [ ] Monitor for 24 hours
