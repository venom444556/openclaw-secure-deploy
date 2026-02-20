#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# PGPClaw — Store Secret in OpenBao
# Authenticates via admin AppRole (credentials from Keychain),
# writes a secret to KV-v2, and revokes the token.
#
# Usage:
#   ./store-secret.sh <secret-name> [secret-value]
#   ./store-secret.sh anthropic-api-key sk-ant-xxx
#   ./store-secret.sh anthropic-api-key              # prompts interactively
# ============================================================

SECRET_NAME="${1:?Usage: store-secret.sh <name> [value]}"
SECRET_VALUE="${2:-}"
BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
KEYCHAIN_SERVICE="pgpclaw-openbao"
DRY_RUN="${DRY_RUN:-false}"

export BAO_ADDR

log()  { echo "[pgpclaw] $(date '+%H:%M:%S') $*"; }
err()  { echo "[pgpclaw] ERROR: $*" >&2; exit 1; }

# ── Interactive prompt if value not provided ─────────────────

if [[ -z "$SECRET_VALUE" ]]; then
  echo -n "Enter value for '$SECRET_NAME': "
  read -rs SECRET_VALUE
  echo ""
  if [[ -z "$SECRET_VALUE" ]]; then
    err "Secret value cannot be empty."
  fi
fi

# ── Preflight ────────────────────────────────────────────────

if [[ "$(uname)" != "Darwin" ]]; then
  err "store-secret.sh requires macOS (uses Keychain)."
fi

# ── Retrieve admin AppRole from Keychain ─────────────────────

ADMIN_ROLE_ID=$(security find-generic-password -a "openbao-admin-role-id" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)
ADMIN_SECRET_ID=$(security find-generic-password -a "openbao-admin-secret-id" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)

if [[ -z "$ADMIN_ROLE_ID" || -z "$ADMIN_SECRET_ID" ]]; then
  err "Admin AppRole not found in Keychain. Run bootstrap-bao.sh first."
fi

# ── Authenticate ─────────────────────────────────────────────

log "Authenticating to OpenBao via admin AppRole..."

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[DRY RUN] would write secret/data/openclaw/$SECRET_NAME"
  exit 0
fi

LOGIN_RESPONSE=$(curl -sf "${BAO_ADDR}/v1/auth/approle/login" \
  -d "{\"role_id\":\"${ADMIN_ROLE_ID}\",\"secret_id\":\"${ADMIN_SECRET_ID}\"}" 2>/dev/null || true)

TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.auth.client_token' 2>/dev/null || true)

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  err "Failed to authenticate to OpenBao. Is it unsealed?"
fi

# ── Write secret ─────────────────────────────────────────────

log "Writing secret: secret/data/openclaw/$SECRET_NAME"

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "X-Vault-Token: $TOKEN" \
  -X POST \
  -d "{\"data\":{\"value\":\"${SECRET_VALUE}\"}}" \
  "${BAO_ADDR}/v1/secret/data/openclaw/${SECRET_NAME}")

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
  log "Secret '$SECRET_NAME' stored successfully."
else
  # Revoke token before erroring
  curl -sf -X POST -H "X-Vault-Token: $TOKEN" "${BAO_ADDR}/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
  err "Failed to write secret (HTTP $HTTP_CODE)."
fi

# ── Revoke token ─────────────────────────────────────────────

curl -sf -X POST -H "X-Vault-Token: $TOKEN" "${BAO_ADDR}/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
log "Admin token revoked."

# Clear sensitive vars
unset TOKEN SECRET_VALUE ADMIN_SECRET_ID
