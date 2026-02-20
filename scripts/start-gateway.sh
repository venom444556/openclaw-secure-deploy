#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# PGPClaw — Start Gateway
# Fetches all secrets from OpenBao, exports them to env,
# and starts docker compose with the specified profile.
# No secrets touch disk — they live in process memory only.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
KEYCHAIN_SERVICE="pgpclaw-openbao"
PROFILE="${1:-core}"

log()  { echo "[pgpclaw] $(date '+%H:%M:%S') $*"; }
err()  { echo "[pgpclaw] ERROR: $*" >&2; exit 1; }

# ── Preflight ────────────────────────────────────────────────

if [[ "$(uname)" != "Darwin" ]]; then
  err "start-gateway.sh requires macOS (uses Keychain)."
fi

command -v curl >/dev/null 2>&1 || err "curl not found."
command -v jq   >/dev/null 2>&1 || err "jq not found."

# ── Ensure OpenBao is running and unsealed ───────────────────

SEALED=$(curl -sf "${BAO_ADDR}/v1/sys/seal-status" 2>/dev/null | jq -r '.sealed' 2>/dev/null || echo "unreachable")

if [[ "$SEALED" == "unreachable" ]]; then
  log "OpenBao not running. Starting it..."
  docker compose -f "$REPO_DIR/docker/docker-compose.yml" --profile core up -d openbao
  sleep 5
  "$REPO_DIR/openbao/scripts/unseal-bao.sh"
elif [[ "$SEALED" == "true" ]]; then
  log "OpenBao is sealed. Unsealing..."
  "$REPO_DIR/openbao/scripts/unseal-bao.sh"
fi

# ── Authenticate via agent AppRole ───────────────────────────

log "Fetching AppRole credentials from Keychain..."
ROLE_ID=$(security find-generic-password -a "openbao-agent-role-id" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)
SECRET_ID=$(security find-generic-password -a "openbao-agent-secret-id" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)

if [[ -z "$ROLE_ID" || -z "$SECRET_ID" ]]; then
  err "Agent AppRole not found in Keychain. Run bootstrap-bao.sh first."
fi

log "Authenticating to OpenBao..."
LOGIN_RESPONSE=$(curl -sf "${BAO_ADDR}/v1/auth/approle/login" \
  -d "{\"role_id\":\"${ROLE_ID}\",\"secret_id\":\"${SECRET_ID}\"}" 2>/dev/null || true)

TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.auth.client_token' 2>/dev/null || true)

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  err "Failed to authenticate to OpenBao."
fi

# ── Fetch secrets ────────────────────────────────────────────

fetch_secret() {
  local name="$1"
  local value
  value=$(curl -sf \
    -H "X-Vault-Token: $TOKEN" \
    "${BAO_ADDR}/v1/secret/data/openclaw/${name}" \
    | jq -r '.data.data.value' 2>/dev/null || true)
  if [[ -n "$value" && "$value" != "null" ]]; then
    echo "$value"
  fi
}

log "Fetching secrets from OpenBao..."

export ANTHROPIC_API_KEY=$(fetch_secret "anthropic-api-key")
export OPENAI_API_KEY=$(fetch_secret "openai-api-key")
export TELEGRAM_BOT_TOKEN=$(fetch_secret "telegram-bot-token")
export DISCORD_BOT_TOKEN=$(fetch_secret "discord-bot-token")
export OPENCLAW_AUTH_PASSWORD=$(fetch_secret "openclaw-auth-password")
export GRAFANA_ADMIN_PASSWORD=$(fetch_secret "grafana-admin-password")

# Nango secrets (only if oauth or full profile)
if [[ "$PROFILE" == "oauth" || "$PROFILE" == "full" ]]; then
  export NANGO_ENCRYPTION_KEY=$(fetch_secret "nango-encryption-key")
  export NANGO_DB_PASSWORD=$(fetch_secret "nango-db-password")
fi

# ── Revoke token ─────────────────────────────────────────────

curl -sf -X POST -H "X-Vault-Token: $TOKEN" "${BAO_ADDR}/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
unset TOKEN SECRET_ID

# ── Count loaded secrets ─────────────────────────────────────

LOADED=0
[[ -n "${ANTHROPIC_API_KEY:-}" ]]      && LOADED=$((LOADED + 1))
[[ -n "${OPENAI_API_KEY:-}" ]]         && LOADED=$((LOADED + 1))
[[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]     && LOADED=$((LOADED + 1))
[[ -n "${DISCORD_BOT_TOKEN:-}" ]]      && LOADED=$((LOADED + 1))
[[ -n "${OPENCLAW_AUTH_PASSWORD:-}" ]] && LOADED=$((LOADED + 1))
[[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]] && LOADED=$((LOADED + 1))
[[ -n "${NANGO_ENCRYPTION_KEY:-}" ]]   && LOADED=$((LOADED + 1))
[[ -n "${NANGO_DB_PASSWORD:-}" ]]      && LOADED=$((LOADED + 1))

log "Loaded $LOADED secret(s) from OpenBao."

# ── Start docker compose ─────────────────────────────────────

log "Starting PGPClaw stack (profile: $PROFILE)..."
docker compose -f "$REPO_DIR/docker/docker-compose.yml" --profile "$PROFILE" up -d

log "PGPClaw started."
