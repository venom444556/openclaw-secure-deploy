#!/usr/bin/env bash
# =============================================================
# OpenClaw — API Key Rotation Script
# Run: ./rotate-keys.sh [provider]
# Providers: anthropic | openai | all
# =============================================================
set -euo pipefail

PROVIDER="${1:-all}"
ENV_FILE="${ENV_FILE:-$HOME/openclaw-secure-deploy/config/.env}"
LOG_FILE="/var/log/openclaw/key-rotation.log"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"; }

rotate_anthropic() {
  log "Rotating Anthropic API key..."
  echo ""
  echo "⚠️  To rotate your Anthropic API key:"
  echo "   1. Go to https://console.anthropic.com/account/keys"
  echo "   2. Create a new key"
  echo "   3. Update ANTHROPIC_API_KEY in: $ENV_FILE"
  echo "   4. Run: systemctl restart openclaw-gateway"
  echo "   5. Verify gateway is healthy"
  echo "   6. Delete the old key from the console"
  echo ""
  echo -n "Enter new Anthropic API key (sk-ant-...): "
  read -rs NEW_KEY
  echo ""

  if [[ ! "$NEW_KEY" =~ ^sk-ant- ]]; then
    echo "❌ Invalid key format. Expected sk-ant-..."
    exit 1
  fi

  # Update .env file
  if grep -q "ANTHROPIC_API_KEY=" "$ENV_FILE"; then
    sed -i.bak "s|ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=$NEW_KEY|" "$ENV_FILE"
    # Securely delete backup containing old key
    if command -v shred &>/dev/null; then
      shred -u "${ENV_FILE}.bak" 2>/dev/null || rm -f "${ENV_FILE}.bak"
    else
      rm -f "${ENV_FILE}.bak"
    fi
  else
    echo "ANTHROPIC_API_KEY=$NEW_KEY" >> "$ENV_FILE"
  fi

  # Export for running services
  export ANTHROPIC_API_KEY="$NEW_KEY"

  log "Anthropic key updated in $ENV_FILE"
}

rotate_openai() {
  log "Rotating OpenAI API key..."
  echo ""
  echo "⚠️  To rotate your OpenAI API key:"
  echo "   1. Go to https://platform.openai.com/api-keys"
  echo "   2. Create a new key"
  echo "   3. Update OPENAI_API_KEY in: $ENV_FILE"
  echo ""
  echo -n "Enter new OpenAI API key (sk-...): "
  read -rs NEW_KEY
  echo ""

  if grep -q "OPENAI_API_KEY=" "$ENV_FILE"; then
    sed -i.bak "s|OPENAI_API_KEY=.*|OPENAI_API_KEY=$NEW_KEY|" "$ENV_FILE"
    # Securely delete backup containing old key
    if command -v shred &>/dev/null; then
      shred -u "${ENV_FILE}.bak" 2>/dev/null || rm -f "${ENV_FILE}.bak"
    else
      rm -f "${ENV_FILE}.bak"
    fi
  else
    echo "OPENAI_API_KEY=$NEW_KEY" >> "$ENV_FILE"
  fi

  log "OpenAI key updated in $ENV_FILE"
}

restart_gateway() {
  log "Restarting OpenClaw gateway..."
  if systemctl is-active --quiet openclaw-gateway; then
    systemctl restart openclaw-gateway
    sleep 3
    if systemctl is-active --quiet openclaw-gateway; then
      log "✅ Gateway restarted successfully"
    else
      log "❌ Gateway failed to restart — check: journalctl -u openclaw-gateway"
      exit 1
    fi
  else
    log "Gateway not running as systemd service — restart manually"
  fi
}

# ── Main ──────────────────────────────────────────────────────
log "=== Key Rotation Starting (provider: $PROVIDER) ==="

case "$PROVIDER" in
  anthropic) rotate_anthropic ;;
  openai)    rotate_openai ;;
  all)       rotate_anthropic; rotate_openai ;;
  *)         echo "Unknown provider: $PROVIDER. Use: anthropic | openai | all"; exit 1 ;;
esac

restart_gateway
log "=== Key rotation complete ==="
echo ""
echo "✅ Keys rotated. Remember to delete old keys from provider dashboards."
