#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# PGPClaw — Revoke Nango OAuth Connections
# Revokes one or all OAuth connections through Nango.
#
# Usage:
#   ./revoke-nango.sh              # revoke ALL connections
#   ./revoke-nango.sh gmail        # revoke only 'gmail'
#   DRY_RUN=true ./revoke-nango.sh # show what would be revoked
# ============================================================

TARGET="${1:-all}"
NANGO_URL="${NANGO_URL:-http://localhost:3003}"
BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
KEYCHAIN_SERVICE="pgpclaw-openbao"
DRY_RUN="${DRY_RUN:-false}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUDIT_LOG="${HOME}/.openclaw/logs/revocation-audit.log"

log()  { echo "[pgpclaw] $(date '+%H:%M:%S') $*"; }
err()  { echo "[pgpclaw] ERROR: $*" >&2; exit 1; }

# ── Get Nango secret key from OpenBao ────────────────────────

if [[ "$(uname)" == "Darwin" ]]; then
  ADMIN_ROLE_ID=$(security find-generic-password -a "openbao-admin-role-id" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)
  ADMIN_SECRET_ID=$(security find-generic-password -a "openbao-admin-secret-id" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)
else
  err "Linux Keychain support not implemented. Use macOS."
fi

if [[ -z "$ADMIN_ROLE_ID" || -z "$ADMIN_SECRET_ID" ]]; then
  err "Admin AppRole not found in Keychain. Run bootstrap-bao.sh first."
fi

# Authenticate to OpenBao
TOKEN=$(curl -sf "${BAO_ADDR}/v1/auth/approle/login" \
  -d "{\"role_id\":\"${ADMIN_ROLE_ID}\",\"secret_id\":\"${ADMIN_SECRET_ID}\"}" \
  | jq -r '.auth.client_token' 2>/dev/null || true)

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  err "Failed to authenticate to OpenBao."
fi

# Fetch Nango encryption key (used as auth for Nango API)
NANGO_SECRET_KEY=$(curl -sf \
  -H "X-Vault-Token: $TOKEN" \
  "${BAO_ADDR}/v1/secret/data/openclaw/nango-encryption-key" \
  | jq -r '.data.data.value' 2>/dev/null || true)

# Revoke OpenBao token
curl -sf -X POST -H "X-Vault-Token: $TOKEN" "${BAO_ADDR}/v1/auth/token/revoke-self" >/dev/null 2>&1 || true

if [[ -z "$NANGO_SECRET_KEY" || "$NANGO_SECRET_KEY" == "null" ]]; then
  err "Could not fetch Nango secret key from OpenBao."
fi

# ── Ensure audit log directory exists ────────────────────────

mkdir -p "$(dirname "$AUDIT_LOG")"

# ── List connections ─────────────────────────────────────────

log "Fetching connections from Nango..."

CONNECTIONS=$(curl -sf \
  -H "Authorization: Bearer ${NANGO_SECRET_KEY}" \
  "${NANGO_URL}/connections" 2>/dev/null || true)

if [[ -z "$CONNECTIONS" ]]; then
  log "No connections found or Nango not reachable."
  exit 0
fi

CONNECTION_COUNT=$(echo "$CONNECTIONS" | jq '.connections | length' 2>/dev/null || echo "0")
log "Found $CONNECTION_COUNT connection(s)."

if [[ "$CONNECTION_COUNT" -eq 0 ]]; then
  log "Nothing to revoke."
  exit 0
fi

# ── Revoke connections ───────────────────────────────────────

echo "$CONNECTIONS" | jq -c '.connections[]' 2>/dev/null | while read -r CONN; do
  CONN_ID=$(echo "$CONN" | jq -r '.connection_id')
  PROVIDER=$(echo "$CONN" | jq -r '.provider_config_key')

  # Filter if specific target requested
  if [[ "$TARGET" != "all" && "$PROVIDER" != "$TARGET" && "$CONN_ID" != "$TARGET" ]]; then
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] would revoke: connection=$CONN_ID provider=$PROVIDER"
    continue
  fi

  log "Revoking: connection=$CONN_ID provider=$PROVIDER"

  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    -X DELETE \
    -H "Authorization: Bearer ${NANGO_SECRET_KEY}" \
    "${NANGO_URL}/connection/${CONN_ID}?provider_config_key=${PROVIDER}")

  if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    log "Revoked: $CONN_ID ($PROVIDER)"
    echo "$(date -Iseconds) | REVOKED | connection=$CONN_ID | provider=$PROVIDER" >> "$AUDIT_LOG"
  else
    log "Failed to revoke $CONN_ID (HTTP $HTTP_CODE)"
    echo "$(date -Iseconds) | FAILED  | connection=$CONN_ID | provider=$PROVIDER | http=$HTTP_CODE" >> "$AUDIT_LOG"
  fi
done

log "Revocation complete."

# Clear sensitive vars
unset NANGO_SECRET_KEY TOKEN ADMIN_SECRET_ID
