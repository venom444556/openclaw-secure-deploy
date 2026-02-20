#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# PGPClaw — OpenBao Bootstrap (Run Once)
# Initializes OpenBao, stores unseal key in macOS Keychain,
# configures AppRole auth, and revokes the root token.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
KEYCHAIN_SERVICE="pgpclaw-openbao"
DRY_RUN="${DRY_RUN:-false}"

export BAO_ADDR

# ── Helpers ──────────────────────────────────────────────────

log()  { echo "[pgpclaw] $(date '+%H:%M:%S') $*"; }
err()  { echo "[pgpclaw] ERROR: $*" >&2; exit 1; }
run()  {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] would execute: $*"
  else
    "$@"
  fi
}

# ── Preflight ────────────────────────────────────────────────

command -v bao  >/dev/null 2>&1 || err "bao CLI not found. Install: brew install openbao"
command -v jq   >/dev/null 2>&1 || err "jq not found. Install: brew install jq"

if [[ "$(uname)" != "Darwin" ]]; then
  err "bootstrap-bao.sh requires macOS (uses Keychain). For Linux, adapt Keychain calls."
fi

command -v security >/dev/null 2>&1 || err "macOS security CLI not found"

# Check if OpenBao is reachable
if ! curl -sf "${BAO_ADDR}/v1/sys/health" >/dev/null 2>&1; then
  # Uninitialized returns 501 which is expected
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${BAO_ADDR}/v1/sys/health" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "000" ]]; then
    err "OpenBao not reachable at ${BAO_ADDR}. Start it first: docker compose --profile core up -d openbao"
  fi
fi

# Check if already initialized
INIT_STATUS=$(curl -sf "${BAO_ADDR}/v1/sys/health" 2>/dev/null || true)
if echo "$INIT_STATUS" | jq -e '.initialized == true' >/dev/null 2>&1; then
  log "OpenBao is already initialized."
  log "If you need to re-bootstrap, destroy the openbao_data volume first."
  exit 0
fi

log "Starting OpenBao bootstrap..."

# ── Step 1: Initialize ──────────────────────────────────────

log "Initializing OpenBao (1 key share, 1 threshold)..."
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[DRY RUN] would execute: bao operator init -key-shares=1 -key-threshold=1 -format=json"
  echo "[DRY RUN] Skipping remaining steps."
  exit 0
fi

INIT_OUTPUT=$(bao operator init -key-shares=1 -key-threshold=1 -format=json)
UNSEAL_KEY=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

if [[ -z "$UNSEAL_KEY" || -z "$ROOT_TOKEN" ]]; then
  err "Failed to parse init output."
fi

log "OpenBao initialized."

# ── Step 2: Store in macOS Keychain ─────────────────────────

log "Storing unseal key in macOS Keychain..."
security add-generic-password \
  -a "openbao-unseal-key" \
  -s "$KEYCHAIN_SERVICE" \
  -w "$UNSEAL_KEY" \
  -U 2>/dev/null || security add-generic-password \
  -a "openbao-unseal-key" \
  -s "$KEYCHAIN_SERVICE" \
  -w "$UNSEAL_KEY"

log "Storing root token in macOS Keychain (temporary — will be revoked)..."
security add-generic-password \
  -a "openbao-root-token" \
  -s "$KEYCHAIN_SERVICE" \
  -w "$ROOT_TOKEN" \
  -U 2>/dev/null || security add-generic-password \
  -a "openbao-root-token" \
  -s "$KEYCHAIN_SERVICE" \
  -w "$ROOT_TOKEN"

# ── Step 3: Unseal ──────────────────────────────────────────

log "Unsealing OpenBao..."
bao operator unseal "$UNSEAL_KEY" >/dev/null
log "OpenBao unsealed."

export BAO_TOKEN="$ROOT_TOKEN"

# ── Step 4: Enable KV-v2 secrets engine ─────────────────────

log "Enabling KV-v2 secrets engine at secret/..."
bao secrets enable -path=secret kv-v2 2>/dev/null || log "KV-v2 already enabled."

# ── Step 5: Write policies ──────────────────────────────────

log "Writing openclaw-agent policy..."
bao policy write openclaw-agent "$SCRIPT_DIR/../policies/openclaw-agent.hcl"

log "Writing openclaw-admin policy..."
bao policy write openclaw-admin "$SCRIPT_DIR/../policies/openclaw-admin.hcl"

# ── Step 6: Enable AppRole auth ─────────────────────────────

log "Enabling AppRole auth method..."
bao auth enable approle 2>/dev/null || log "AppRole already enabled."

# ── Step 7: Create agent role (read-only, short TTL) ────────

log "Creating openclaw-agent AppRole (TTL=1h, max=4h)..."
bao write auth/approle/role/openclaw-agent \
  token_policies="openclaw-agent" \
  token_ttl="1h" \
  token_max_ttl="4h" \
  secret_id_ttl="0" \
  token_num_uses=0

AGENT_ROLE_ID=$(bao read -format=json auth/approle/role/openclaw-agent/role-id | jq -r '.data.role_id')
AGENT_SECRET_ID=$(bao write -f -format=json auth/approle/role/openclaw-agent/secret-id | jq -r '.data.secret_id')

log "Storing agent AppRole credentials in Keychain..."
security add-generic-password -a "openbao-agent-role-id" -s "$KEYCHAIN_SERVICE" -w "$AGENT_ROLE_ID" -U 2>/dev/null \
  || security add-generic-password -a "openbao-agent-role-id" -s "$KEYCHAIN_SERVICE" -w "$AGENT_ROLE_ID"
security add-generic-password -a "openbao-agent-secret-id" -s "$KEYCHAIN_SERVICE" -w "$AGENT_SECRET_ID" -U 2>/dev/null \
  || security add-generic-password -a "openbao-agent-secret-id" -s "$KEYCHAIN_SERVICE" -w "$AGENT_SECRET_ID"

# ── Step 8: Create admin role (read-write, for secret mgmt) ─

log "Creating openclaw-admin AppRole (TTL=15m, max=1h)..."
bao write auth/approle/role/openclaw-admin \
  token_policies="openclaw-admin" \
  token_ttl="15m" \
  token_max_ttl="1h" \
  secret_id_ttl="0" \
  token_num_uses=0

ADMIN_ROLE_ID=$(bao read -format=json auth/approle/role/openclaw-admin/role-id | jq -r '.data.role_id')
ADMIN_SECRET_ID=$(bao write -f -format=json auth/approle/role/openclaw-admin/secret-id | jq -r '.data.secret_id')

log "Storing admin AppRole credentials in Keychain..."
security add-generic-password -a "openbao-admin-role-id" -s "$KEYCHAIN_SERVICE" -w "$ADMIN_ROLE_ID" -U 2>/dev/null \
  || security add-generic-password -a "openbao-admin-role-id" -s "$KEYCHAIN_SERVICE" -w "$ADMIN_ROLE_ID"
security add-generic-password -a "openbao-admin-secret-id" -s "$KEYCHAIN_SERVICE" -w "$ADMIN_SECRET_ID" -U 2>/dev/null \
  || security add-generic-password -a "openbao-admin-secret-id" -s "$KEYCHAIN_SERVICE" -w "$ADMIN_SECRET_ID"

# ── Step 9: Enable audit logging ────────────────────────────

log "Enabling file audit log..."
bao audit enable file file_path=/openbao/audit/audit.log 2>/dev/null || log "Audit log already enabled."

# ── Step 10: Prompt for initial secrets ──────────────────────

echo ""
echo "========================================================"
echo "  OpenBao is ready. Store your secrets now."
echo "========================================================"
echo ""
echo "  Run for each secret you need:"
echo ""
echo "    ./openbao/scripts/store-secret.sh anthropic-api-key <your-key>"
echo "    ./openbao/scripts/store-secret.sh openclaw-auth-password <password>"
echo "    ./openbao/scripts/store-secret.sh grafana-admin-password <password>"
echo ""
echo "  Optional (only if using these services):"
echo "    ./openbao/scripts/store-secret.sh openai-api-key <key>"
echo "    ./openbao/scripts/store-secret.sh telegram-bot-token <token>"
echo "    ./openbao/scripts/store-secret.sh discord-bot-token <token>"
echo ""

# ── Step 11: Revoke root token ──────────────────────────────

log "Revoking root token (no longer needed)..."
bao token revoke "$ROOT_TOKEN"

# Mark the Keychain entry as revoked
security add-generic-password \
  -a "openbao-root-token" \
  -s "$KEYCHAIN_SERVICE" \
  -w "REVOKED" \
  -U 2>/dev/null || true

unset BAO_TOKEN

log "Root token revoked. Only AppRole auth remains."
log ""
log "Bootstrap complete. OpenBao is ready."
log "  Agent role-id:  $AGENT_ROLE_ID"
log "  Admin role-id:  $ADMIN_ROLE_ID"
log "  Unseal key:     stored in macOS Keychain (service: $KEYCHAIN_SERVICE)"
log ""
log "To unseal after restart: ./openbao/scripts/unseal-bao.sh"
