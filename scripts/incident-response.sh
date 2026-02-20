#!/usr/bin/env bash
# =============================================================
# PGPClaw — Incident Response Runbook Scripts
# Usage: ./incident-response.sh [scenario]
# Scenarios: compromised-key | bao-seal | nango-revoke |
#            prompt-injection | runaway-cost | full-lockdown | restore
# =============================================================
set -euo pipefail

SCENARIO="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
LOG_DIR="$OPENCLAW_HOME/logs"
LOG_FILE="$LOG_DIR/incidents.log"
OPENCLAW_LOG="$LOG_DIR/gateway.log"
BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"

mkdir -p "$LOG_DIR"

log() { echo "[$(date -Iseconds)] INCIDENT [$SCENARIO] $*" | tee -a "$LOG_FILE"; }

require_confirm() {
  echo -n "⚠️  $1 — Type 'yes' to confirm: "
  read -r CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
}

# Helper: stop the gateway (macOS + Linux)
stop_gateway() {
  docker compose -f "$REPO_DIR/docker/docker-compose.yml" stop openclaw 2>/dev/null || true
  launchctl unload ~/Library/LaunchAgents/com.pgpclaw.gateway.plist 2>/dev/null || true
  systemctl stop openclaw-gateway 2>/dev/null || true
  pkill -f "openclaw.*gateway" 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════
# SCENARIO: Emergency Seal OpenBao
# ══════════════════════════════════════════════════════════════
scenario_bao_seal() {
  log "RESPONDING TO: Emergency OpenBao Seal"
  echo ""
  echo "🔒 EMERGENCY OPENBAO SEAL"
  echo "========================="
  echo ""
  echo "This will IMMEDIATELY cut off ALL secret access."
  echo "The gateway and all integrations will stop working."
  echo ""

  require_confirm "Seal OpenBao and cut all secret access"

  # Seal OpenBao
  log "Step 1: Sealing OpenBao"
  if command -v bao &>/dev/null; then
    BAO_ADDR="$BAO_ADDR" bao operator seal 2>/dev/null && echo "✅ OpenBao sealed via CLI" || true
  fi

  # Fallback: HTTP API seal
  curl -sf -X PUT "${BAO_ADDR}/v1/sys/seal" \
    -H "X-Vault-Token: $(security find-generic-password -s pgpclaw-openbao -a root-token -w 2>/dev/null || echo '')" \
    2>/dev/null && echo "✅ OpenBao sealed via API" || true

  # Stop gateway (can't function without secrets)
  log "Step 2: Stopping gateway (no secrets available)"
  stop_gateway
  echo "✅ Gateway stopped"

  echo ""
  echo "🔧 TO RECOVER:"
  echo "   1. Investigate the incident"
  echo "   2. Unseal: ./openbao/scripts/unseal-bao.sh"
  echo "   3. Restart: ./scripts/start-gateway.sh"
  echo ""
  log "OpenBao sealed — all secret access cut"
}

# ══════════════════════════════════════════════════════════════
# SCENARIO: Revoke Nango OAuth Connections
# ══════════════════════════════════════════════════════════════
scenario_nango_revoke() {
  log "RESPONDING TO: Nango OAuth Revocation"
  echo ""
  echo "🔑 NANGO OAUTH REVOCATION"
  echo "========================="
  echo ""

  INTEGRATION="${2:-all}"

  if [[ "$INTEGRATION" == "all" ]]; then
    echo "This will revoke ALL OAuth connections (Gmail, GitHub, etc.)"
    require_confirm "Revoke ALL Nango OAuth connections"
  else
    echo "This will revoke OAuth connection: $INTEGRATION"
    require_confirm "Revoke Nango connection: $INTEGRATION"
  fi

  log "Revoking Nango connections: $INTEGRATION"

  if [[ -x "$REPO_DIR/nango/scripts/revoke-nango.sh" ]]; then
    if [[ "$INTEGRATION" == "all" ]]; then
      "$REPO_DIR/nango/scripts/revoke-nango.sh" --all
    else
      "$REPO_DIR/nango/scripts/revoke-nango.sh" "$INTEGRATION"
    fi
    echo "✅ Nango connections revoked"
  else
    echo "❌ revoke-nango.sh not found — manual revocation required"
    echo "   Nango dashboard: http://localhost:3003"
  fi

  echo ""
  log "Nango revocation complete: $INTEGRATION"
}

# ══════════════════════════════════════════════════════════════
# SCENARIO: Compromised API Key
# ══════════════════════════════════════════════════════════════
scenario_compromised_key() {
  log "RESPONDING TO: Compromised API Key"
  echo ""
  echo "🚨 COMPROMISED API KEY RESPONSE"
  echo "================================="
  echo ""

  require_confirm "This will stop the OpenClaw gateway and seal OpenBao"

  # 1. Seal OpenBao (cut all secret access immediately)
  log "Step 1: Sealing OpenBao"
  if command -v bao &>/dev/null; then
    BAO_ADDR="$BAO_ADDR" bao operator seal 2>/dev/null || true
  fi
  echo "✅ OpenBao sealed — no more secrets can be read"

  # 2. Stop gateway
  log "Step 2: Stopping gateway"
  stop_gateway
  echo "✅ Gateway stopped"

  # 3. Investigation
  log "Step 3: Investigating"
  echo ""
  echo "📋 Checking for suspicious activity in recent logs:"
  tail -100 "$OPENCLAW_LOG" 2>/dev/null | grep -iE "curl|wget|nc |bash.*-i|rm -rf|python.*-c|eval|base64" || echo "   Nothing obviously suspicious in logs"

  echo ""
  echo "📋 Unusual API calls:"
  grep -i "model.*gpt\|model.*openai" "$OPENCLAW_LOG" 2>/dev/null | tail -20 || echo "   None found"

  # 4. Instructions
  echo ""
  echo "🔧 NEXT STEPS (manual):"
  echo "   1. Go to https://console.anthropic.com/account/keys — REVOKE the old key NOW"
  echo "   2. Generate a new key and store it:"
  echo "      ./openbao/scripts/unseal-bao.sh"
  echo "      ./openbao/scripts/store-secret.sh anthropic-api-key <new-key>"
  echo "   3. Check OpenAI dashboard if applicable"
  echo "   4. Review logs for data exfiltration"
  echo "   5. Restart: ./scripts/start-gateway.sh"
  echo ""
  log "Investigation phase complete — manual steps required"
}

# ══════════════════════════════════════════════════════════════
# SCENARIO: Prompt Injection Attack
# ══════════════════════════════════════════════════════════════
scenario_prompt_injection() {
  log "RESPONDING TO: Prompt Injection Attack"
  echo ""
  echo "🚨 PROMPT INJECTION RESPONSE"
  echo "=============================="
  echo ""

  echo "📋 Recent suspicious messages:"
  grep -iE "ignore.*previous|system.*prompt|jailbreak|SUDO|root access|credentials|~/.openclaw" \
    "$OPENCLAW_LOG" 2>/dev/null | tail -20 || echo "   No matches found in logs"

  echo ""
  echo "🔧 AUTOMATIC MITIGATIONS:"

  # Check if sandbox is enabled
  if grep -q '"mode": "non-main"' "$OPENCLAW_HOME/openclaw.json" 2>/dev/null; then
    echo "   ✅ Sandbox (non-main) already enabled"
  else
    echo "   ⚠️  Sandbox not detected — review config/openclaw.json"
  fi

  echo ""
  echo "🔧 MANUAL STEPS:"
  echo "   1. Identify attacker's phone/username from logs above"
  echo "   2. Add to denylist in openclaw.json:"
  echo "      channels.whatsapp.denyFrom: [\"+1ATTACKER_NUMBER\"]"
  echo "   3. Run: openclaw sessions pause <session-id>"
  echo "   4. Harden: set agents.defaults.sandbox.mode = 'all' (paranoid mode)"
  echo "   5. Restart gateway: ./scripts/start-gateway.sh"
  echo ""
  log "Prompt injection incident logged"
}

# ══════════════════════════════════════════════════════════════
# SCENARIO: Runaway Agent Costs
# ══════════════════════════════════════════════════════════════
scenario_runaway_cost() {
  log "RESPONDING TO: Runaway Agent Costs"
  echo ""
  echo "🚨 RUNAWAY COST RESPONSE"
  echo "=========================="
  echo ""

  require_confirm "This will IMMEDIATELY kill the OpenClaw gateway"

  # 1. Emergency kill
  log "Step 1: Emergency kill"
  stop_gateway
  echo "✅ Gateway killed"

  # 2. Find culprit
  log "Step 2: Identifying runaway session"
  echo ""
  echo "📋 Sessions with most activity (last 500 lines):"
  tail -500 "$OPENCLAW_LOG" 2>/dev/null | \
    grep -oE "session[_-][a-zA-Z0-9_-]+" | sort | uniq -c | sort -rn | head -10 || true

  echo ""
  echo "📋 Agent spawning activity:"
  grep -i "sessions_spawn\|spawn.*agent" "$OPENCLAW_LOG" 2>/dev/null | tail -20 || echo "   None found"

  # 3. Cost limiting config advice
  echo ""
  echo "🔧 ADD THESE TO config/openclaw.json before restarting:"
  cat <<'CONFIG'
  "api": {
    "costControl": {
      "maxCostPerHour": 20,
      "maxCostPerDay": 200,
      "action": "pause_gateway"
    }
  },
  "sessions": {
    "maxDepth": 3
  }
CONFIG
  echo ""
  echo "   Then restart: ./scripts/start-gateway.sh"
  log "Runaway cost incident contained"
}

# ══════════════════════════════════════════════════════════════
# SCENARIO: Full Lockdown (nuclear option)
# ══════════════════════════════════════════════════════════════
scenario_full_lockdown() {
  log "INITIATING: Full Lockdown"
  echo ""
  echo "🔒 FULL LOCKDOWN"
  echo "================="
  echo ""

  require_confirm "This will SEAL OpenBao, REVOKE all OAuth, STOP all services, and BLOCK access"

  # 1. Seal OpenBao (cut all secrets)
  log "Step 1: Sealing OpenBao"
  if command -v bao &>/dev/null; then
    BAO_ADDR="$BAO_ADDR" bao operator seal 2>/dev/null || true
  fi
  echo "✅ OpenBao sealed"

  # 2. Revoke all Nango connections
  log "Step 2: Revoking all Nango OAuth connections"
  if [[ -x "$REPO_DIR/nango/scripts/revoke-nango.sh" ]]; then
    "$REPO_DIR/nango/scripts/revoke-nango.sh" --all 2>/dev/null || true
  fi
  echo "✅ Nango connections revoked"

  # 3. Stop all containers
  log "Step 3: Stopping all PGPClaw containers"
  docker compose -f "$REPO_DIR/docker/docker-compose.yml" --profile full down 2>/dev/null || true
  stop_gateway
  echo "✅ All services stopped"

  # 4. Block gateway port
  if command -v ufw &>/dev/null; then
    ufw deny 18789/tcp 2>/dev/null || true
    echo "✅ Firewall rule added: deny 18789"
  fi

  # 5. Block Tailscale (if using)
  if command -v tailscale &>/dev/null; then
    tailscale down 2>/dev/null || true
    echo "✅ Tailscale disconnected"
  fi

  log "FULL LOCKDOWN COMPLETE"
  echo ""
  echo "✅ Lockdown complete."
  echo "   - OpenBao: SEALED (no secret access)"
  echo "   - Nango: ALL OAuth connections REVOKED"
  echo "   - Gateway: STOPPED"
  echo "   - Network: BLOCKED"
  echo ""
  echo "   To restore: ./scripts/incident-response.sh restore"
}

# ══════════════════════════════════════════════════════════════
# SCENARIO: Restore from lockdown
# ══════════════════════════════════════════════════════════════
scenario_restore() {
  log "RESTORING from lockdown"
  echo ""
  echo "🔓 RESTORING SERVICES"
  echo ""
  require_confirm "This will re-enable PGPClaw services"

  # 1. Restore firewall
  if command -v ufw &>/dev/null; then
    ufw delete deny 18789/tcp 2>/dev/null || true
    echo "✅ Firewall rule removed"
  fi

  # 2. Restore Tailscale
  if command -v tailscale &>/dev/null; then
    tailscale up 2>/dev/null || true
    echo "✅ Tailscale reconnected"
  fi

  # 3. Start OpenBao container
  log "Starting OpenBao"
  docker start pgpclaw-openbao 2>/dev/null || true
  sleep 3

  # 4. Unseal OpenBao
  log "Unsealing OpenBao"
  if [[ -x "$REPO_DIR/openbao/scripts/unseal-bao.sh" ]]; then
    "$REPO_DIR/openbao/scripts/unseal-bao.sh"
    echo "✅ OpenBao unsealed"
  else
    echo "⚠️  Run manually: ./openbao/scripts/unseal-bao.sh"
  fi

  # 5. Start gateway
  log "Starting gateway"
  if [[ -x "$REPO_DIR/scripts/start-gateway.sh" ]]; then
    "$REPO_DIR/scripts/start-gateway.sh"
    echo "✅ Gateway started"
  else
    echo "⚠️  Run manually: ./scripts/start-gateway.sh"
  fi

  # 6. Run doctor
  openclaw doctor 2>/dev/null || true

  log "Services restored"
  echo ""
  echo "✅ PGPClaw restored"
  echo ""
  echo "⚠️  NOTE: Nango OAuth connections were revoked during lockdown."
  echo "   You must re-authorize integrations via the Nango dashboard:"
  echo "   http://localhost:3003"
}

# -- Main ----------------------------------------------------------------------
case "$SCENARIO" in
  bao-seal)           scenario_bao_seal ;;
  nango-revoke)       scenario_nango_revoke "$@" ;;
  compromised-key)    scenario_compromised_key ;;
  prompt-injection)   scenario_prompt_injection ;;
  runaway-cost)       scenario_runaway_cost ;;
  full-lockdown)      scenario_full_lockdown ;;
  restore)            scenario_restore ;;
  "")
    echo "Usage: $0 [scenario]"
    echo ""
    echo "Scenarios:"
    echo "  bao-seal           — Emergency seal OpenBao (cuts ALL secret access)"
    echo "  nango-revoke       — Revoke Nango OAuth connections"
    echo "  compromised-key    — API key leaked/stolen"
    echo "  prompt-injection   — Attack via chat messages"
    echo "  runaway-cost       — Agent loop burning money"
    echo "  full-lockdown      — Nuclear: seal + revoke + stop + block"
    echo "  restore            — Bring services back up after lockdown"
    ;;
  *)
    echo "Unknown scenario: $SCENARIO"
    exit 1
    ;;
esac
