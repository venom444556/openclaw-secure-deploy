#!/usr/bin/env bash
# =============================================================
# OpenClaw — Incident Response Runbook Scripts
# Usage: ./incident-response.sh [scenario]
# Scenarios: compromised-key | prompt-injection | runaway-cost | full-lockdown
# =============================================================
set -euo pipefail

SCENARIO="${1:-}"
LOG_FILE="/var/log/openclaw/incidents.log"
OPENCLAW_LOG="/var/log/openclaw/gateway.log"

log() { echo "[$(date -Iseconds)] INCIDENT [$SCENARIO] $*" | tee -a "$LOG_FILE"; }

require_confirm() {
  echo -n "⚠️  $1 — Type 'yes' to confirm: "
  read -r CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
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

  require_confirm "This will stop the OpenClaw gateway"

  # 1. Stop gateway
  log "Step 1: Stopping gateway"
  systemctl stop openclaw-gateway 2>/dev/null || pkill openclaw 2>/dev/null || true
  echo "✅ Gateway stopped"

  # 2. Investigation
  log "Step 2: Investigating"
  echo ""
  echo "📋 Checking for suspicious activity in last 100 lines:"
  tail -100 "$OPENCLAW_LOG" 2>/dev/null | grep -iE "curl|wget|nc |bash.*-i|rm -rf|python.*-c|eval|base64" || echo "   Nothing obviously suspicious in logs"

  echo ""
  echo "📋 Unusual API calls:"
  grep -i "model.*gpt\|model.*openai" "$OPENCLAW_LOG" 2>/dev/null | tail -20 || echo "   None found"

  # 3. Instructions
  echo ""
  echo "🔧 NEXT STEPS (manual):"
  echo "   1. Go to https://console.anthropic.com/account/keys — REVOKE the old key NOW"
  echo "   2. Run: ./scripts/rotate-keys.sh anthropic"
  echo "   3. Check OpenAI dashboard if applicable"
  echo "   4. Review: $OPENCLAW_LOG for data exfiltration"
  echo "   5. Once secured, restart: systemctl start openclaw-gateway"
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
  if grep -q '"mode": "non-main"' ~/.openclaw/openclaw.json 2>/dev/null; then
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
  echo "   5. Restart: systemctl restart openclaw-gateway"
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
  pkill -9 openclaw 2>/dev/null || true
  systemctl stop openclaw-gateway 2>/dev/null || true
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
  echo "   Then restart: systemctl start openclaw-gateway"
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

  require_confirm "This will STOP ALL OpenClaw services and block external access"

  # Kill everything
  systemctl stop openclaw-gateway 2>/dev/null || true
  pkill -9 openclaw 2>/dev/null || true

  # Block gateway port (UFW)
  if command -v ufw &>/dev/null; then
    ufw deny 18789/tcp 2>/dev/null || true
    echo "✅ Firewall rule added: deny 18789"
  fi

  # Block Tailscale (if using)
  if command -v tailscale &>/dev/null; then
    tailscale down 2>/dev/null || true
    echo "✅ Tailscale disconnected"
  fi

  log "FULL LOCKDOWN COMPLETE — gateway stopped, ports blocked"
  echo ""
  echo "✅ Lockdown complete."
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
  require_confirm "This will re-enable OpenClaw"

  # Restore firewall
  if command -v ufw &>/dev/null; then
    ufw delete deny 18789/tcp 2>/dev/null || true
  fi

  # Restore Tailscale
  if command -v tailscale &>/dev/null; then
    tailscale up 2>/dev/null || true
  fi

  # Run doctor
  openclaw doctor || true

  # Restart
  systemctl start openclaw-gateway
  log "Services restored"
  echo "✅ OpenClaw restored"
}

# ── Main ──────────────────────────────────────────────────────
case "$SCENARIO" in
  compromised-key)    scenario_compromised_key ;;
  prompt-injection)   scenario_prompt_injection ;;
  runaway-cost)       scenario_runaway_cost ;;
  full-lockdown)      scenario_full_lockdown ;;
  restore)            scenario_restore ;;
  "")
    echo "Usage: $0 [scenario]"
    echo ""
    echo "Scenarios:"
    echo "  compromised-key    — API key leaked/stolen"
    echo "  prompt-injection   — Attack via chat messages"
    echo "  runaway-cost       — Agent loop burning money"
    echo "  full-lockdown      — Nuclear option: kill everything"
    echo "  restore            — Bring services back up"
    ;;
  *)
    echo "Unknown scenario: $SCENARIO"
    exit 1
    ;;
esac
