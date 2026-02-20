#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# PGPClaw — OpenBao Unseal
# Reads the unseal key from macOS Keychain and unseals OpenBao.
# Called on every restart (manually or via launchd).
# ============================================================

BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
KEYCHAIN_SERVICE="pgpclaw-openbao"
MAX_RETRIES=30
RETRY_INTERVAL=2

export BAO_ADDR

log()  { echo "[pgpclaw] $(date '+%H:%M:%S') $*"; }
err()  { echo "[pgpclaw] ERROR: $*" >&2; exit 1; }

# ── Wait for OpenBao to be reachable ────────────────────────

log "Waiting for OpenBao at ${BAO_ADDR}..."
for i in $(seq 1 "$MAX_RETRIES"); do
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${BAO_ADDR}/v1/sys/health" 2>/dev/null || echo "000")
  # 200 = initialized+unsealed, 429 = standby, 472 = perf standby
  # 501 = not initialized, 503 = sealed
  if [[ "$HTTP_CODE" != "000" ]]; then
    break
  fi
  if [[ "$i" -eq "$MAX_RETRIES" ]]; then
    err "OpenBao not reachable after ${MAX_RETRIES} attempts."
  fi
  sleep "$RETRY_INTERVAL"
done

# ── Check seal status ────────────────────────────────────────

SEALED=$(curl -sf "${BAO_ADDR}/v1/sys/seal-status" 2>/dev/null | jq -r '.sealed' 2>/dev/null || echo "unknown")

if [[ "$SEALED" == "false" ]]; then
  log "OpenBao is already unsealed."
  exit 0
fi

if [[ "$SEALED" == "unknown" ]]; then
  err "Cannot determine seal status. Is OpenBao initialized?"
fi

# ── Retrieve unseal key from Keychain ────────────────────────

if [[ "$(uname)" != "Darwin" ]]; then
  err "unseal-bao.sh requires macOS (uses Keychain). For Linux, provide UNSEAL_KEY env var."
fi

UNSEAL_KEY=$(security find-generic-password -a "openbao-unseal-key" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)

if [[ -z "$UNSEAL_KEY" ]]; then
  err "Unseal key not found in Keychain (service: $KEYCHAIN_SERVICE). Run bootstrap-bao.sh first."
fi

# ── Unseal ───────────────────────────────────────────────────

log "Unsealing OpenBao..."
bao operator unseal "$UNSEAL_KEY" >/dev/null

# ── Verify ───────────────────────────────────────────────────

SEALED_AFTER=$(curl -sf "${BAO_ADDR}/v1/sys/seal-status" | jq -r '.sealed')
if [[ "$SEALED_AFTER" == "false" ]]; then
  log "OpenBao unsealed successfully."
else
  err "Unseal failed. OpenBao is still sealed."
fi
