#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# PGPClaw — Ephemeral Runner Entrypoint
# 1. Authenticate to OpenBao via AppRole (HTTP API, no CLI)
# 2. Fetch required secrets into env vars
# 3. Execute the task command
# 4. Revoke token (cleanup)
# 5. Exit → --rm destroys the container and all state
# ============================================================

BAO_ADDR="${BAO_ADDR:-}"
BAO_ROLE_ID="${BAO_ROLE_ID:-}"
BAO_SECRET_ID="${BAO_SECRET_ID:-}"
TASK_COMMAND="${TASK_COMMAND:-}"
SECRETS_TO_FETCH="${SECRETS_TO_FETCH:-anthropic-api-key}"

log() { echo "[runner] $(date '+%H:%M:%S') $*"; }
err() { echo "[runner] ERROR: $*" >&2; exit 1; }

# ── Validate inputs ──────────────────────────────────────────

[[ -n "$TASK_COMMAND" ]] || err "TASK_COMMAND not set."

TOKEN=""

# ── Step 1: Authenticate to OpenBao (if configured) ─────────

if [[ -n "$BAO_ADDR" && -n "$BAO_ROLE_ID" && -n "$BAO_SECRET_ID" ]]; then
  log "Authenticating to OpenBao..."

  LOGIN_RESPONSE=$(curl -sf "${BAO_ADDR}/v1/auth/approle/login" \
    -d "{\"role_id\":\"${BAO_ROLE_ID}\",\"secret_id\":\"${BAO_SECRET_ID}\"}" 2>/dev/null || true)

  TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.auth.client_token' 2>/dev/null || true)

  if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    err "Failed to authenticate to OpenBao."
  fi

  # ── Step 2: Fetch secrets ────────────────────────────────

  IFS=',' read -ra SECRET_LIST <<< "$SECRETS_TO_FETCH"
  for SECRET_NAME in "${SECRET_LIST[@]}"; do
    SECRET_NAME=$(echo "$SECRET_NAME" | xargs)  # trim whitespace
    ENV_VAR_NAME=$(echo "$SECRET_NAME" | tr '[:lower:]-' '[:upper:]_')

    VALUE=$(curl -sf \
      -H "X-Vault-Token: $TOKEN" \
      "${BAO_ADDR}/v1/secret/data/openclaw/${SECRET_NAME}" \
      | jq -r '.data.data.value' 2>/dev/null || true)

    if [[ -n "$VALUE" && "$VALUE" != "null" ]]; then
      export "$ENV_VAR_NAME"="$VALUE"
      log "Loaded secret: $SECRET_NAME → \$$ENV_VAR_NAME"
    else
      log "Warning: secret '$SECRET_NAME' not found in OpenBao."
    fi
  done

  # Clear auth vars from environment
  unset BAO_ROLE_ID BAO_SECRET_ID
else
  log "No OpenBao configured — running without secrets."
fi

# ── Step 3: Execute task ─────────────────────────────────────

log "Executing task..."
eval "$TASK_COMMAND"
EXIT_CODE=$?

# ── Step 4: Revoke token ────────────────────────────────────

if [[ -n "$TOKEN" ]]; then
  curl -sf -X POST \
    -H "X-Vault-Token: $TOKEN" \
    "${BAO_ADDR}/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
  log "Token revoked."
fi

# ── Step 5: Exit — --rm destroys the container ──────────────

exit "$EXIT_CODE"
