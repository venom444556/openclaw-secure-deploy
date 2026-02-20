#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# PGPClaw — Rotate Secrets via OpenBao
# Replaces rotate-keys.sh — secrets are rotated through
# OpenBao, not by editing .env files.
#
# Usage:
#   ./rotate-secrets.sh anthropic    # Rotate Anthropic API key
#   ./rotate-secrets.sh openai       # Rotate OpenAI API key
#   ./rotate-secrets.sh all          # Rotate all API keys
#   DRY_RUN=true ./rotate-secrets.sh anthropic
# ============================================================

TARGET="${1:?Usage: rotate-secrets.sh <anthropic|openai|telegram|discord|all>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DRY_RUN="${DRY_RUN:-false}"

STORE_SECRET="$REPO_DIR/openbao/scripts/store-secret.sh"

log()  { echo "[pgpclaw] $(date '+%H:%M:%S') $*"; }
err()  { echo "[pgpclaw] ERROR: $*" >&2; exit 1; }

[[ -x "$STORE_SECRET" ]] || err "store-secret.sh not found or not executable."

# ── Rotation functions ───────────────────────────────────────

rotate_key() {
  local name="$1"
  local display_name="$2"
  local format_hint="$3"

  echo ""
  log "Rotating: $display_name"
  echo "  1. Generate a new key at the provider's console."
  echo "  2. Paste the new key below."
  echo "  Format: $format_hint"
  echo ""
  echo -n "  New $display_name: "
  read -rs NEW_KEY
  echo ""

  if [[ -z "$NEW_KEY" ]]; then
    log "Skipped $display_name (empty input)."
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] would store new $name in OpenBao"
    return
  fi

  "$STORE_SECRET" "$name" "$NEW_KEY"
  log "$display_name rotated successfully in OpenBao."
  unset NEW_KEY
}

# ── Execute rotation ─────────────────────────────────────────

case "$TARGET" in
  anthropic)
    rotate_key "anthropic-api-key" "Anthropic API Key" "sk-ant-..."
    ;;
  openai)
    rotate_key "openai-api-key" "OpenAI API Key" "sk-..."
    ;;
  telegram)
    rotate_key "telegram-bot-token" "Telegram Bot Token" "123456789:ABC..."
    ;;
  discord)
    rotate_key "discord-bot-token" "Discord Bot Token" "MTk..."
    ;;
  all)
    rotate_key "anthropic-api-key" "Anthropic API Key" "sk-ant-..."
    rotate_key "openai-api-key" "OpenAI API Key" "sk-..."
    rotate_key "telegram-bot-token" "Telegram Bot Token" "123456789:ABC..."
    rotate_key "discord-bot-token" "Discord Bot Token" "MTk..."
    ;;
  *)
    err "Unknown target: $TARGET. Use: anthropic, openai, telegram, discord, or all."
    ;;
esac

echo ""
log "Rotation complete."
log "Restart the gateway to pick up new secrets:"
log "  ./scripts/start-gateway.sh"
