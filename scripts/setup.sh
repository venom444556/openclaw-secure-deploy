#!/usr/bin/env bash
# =============================================================
# OpenClaw Secure Deployment — Master Setup Script
# Tested on: Ubuntu 22.04+, macOS 14+, Raspberry Pi OS (bookworm)
# Usage: sudo ./setup.sh [--dev | --production]
# =============================================================
set -euo pipefail

MODE="${1:---production}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="/tmp/openclaw-setup.log"
OPENCLAW_USER="${OPENCLAW_USER:-$(whoami)}"

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
err()  { echo -e "${RED}❌ $*${NC}"; exit 1; }
info() { echo -e "   $*"; }

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"; }

# ══════════════════════════════════════════════════════════════
banner() {
cat << 'BANNER'
  ___                  ____ _               
 / _ \ _ __   ___ _ _ / ___| | __ ___      __
| | | | '_ \ / _ \ ' \ |   | |/ _` \ \ /\ / /
| |_| | |_) |  __/ | | |___| | (_| |\ V  V / 
 \___/| .__/ \___|_|_|\____|_|\__,_| \_/\_/  
      |_|      Secure Deployment Setup        

BANNER
  echo "Mode: $MODE"
  echo "Deploy dir: $DEPLOY_DIR"
  echo ""
}
# ══════════════════════════════════════════════════════════════

detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
  elif [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS="$ID"
  else
    OS="unknown"
  fi
  log "Detected OS: $OS"
}

check_prerequisites() {
  echo "📋 Checking prerequisites..."

  # Node.js 22+
  if command -v node &>/dev/null; then
    NODE_VER=$(node --version | sed 's/v//' | cut -d. -f1)
    if [[ "$NODE_VER" -ge 22 ]]; then
      ok "Node.js $NODE_VER"
    else
      warn "Node.js $NODE_VER — need 22+. Upgrade: https://nodejs.org"
    fi
  else
    warn "Node.js not found — install Node.js 22+"
    if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
      info "Run: curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt install -y nodejs"
    fi
  fi

  # Docker
  if command -v docker &>/dev/null; then
    ok "Docker $(docker --version | sed 's/[^0-9.]//g' | cut -d. -f1-3)"
  else
    warn "Docker not found — required for sandboxing"
    info "Install: https://docs.docker.com/engine/install/"
  fi

  # OpenClaw
  if command -v openclaw &>/dev/null; then
    ok "OpenClaw $(openclaw --version 2>/dev/null || echo 'installed')"
  else
    warn "OpenClaw not installed"
    info "Run: npm install -g openclaw@latest"
  fi

  # Tailscale (optional but recommended)
  if command -v tailscale &>/dev/null; then
    ok "Tailscale installed"
  else
    warn "Tailscale not found (optional but recommended for remote access)"
    info "Install: https://tailscale.com/download"
  fi

  echo ""
}

setup_user() {
  if [[ "$OPENCLAW_USER" == "root" ]]; then
    warn "Running as root — creating openclaw system user"
    if ! id openclaw &>/dev/null; then
      useradd -r -s /bin/false -m -d /home/openclaw openclaw
      ok "Created openclaw user"
    else
      ok "openclaw user exists"
    fi
    OPENCLAW_USER="openclaw"
  fi
}

setup_directories() {
  echo "📁 Setting up directories..."

  # Resolve correct home directory (macOS uses /Users, Linux uses /home)
  USER_HOME=$(eval echo "~$OPENCLAW_USER")

  # On macOS, use user-local paths for logs and backups (no root access)
  if [[ "$OS" == "macos" ]]; then
    LOG_DIR="$USER_HOME/.openclaw/logs"
    BACKUP_DIR="$USER_HOME/.openclaw/backups"
  else
    LOG_DIR="/var/log/openclaw"
    BACKUP_DIR="/backups/openclaw"
  fi

  DIRS=(
    "$USER_HOME/.openclaw"
    "$USER_HOME/.openclaw/credentials"
    "$USER_HOME/.openclaw/workspace/skills"
    "$USER_HOME/.openclaw/sessions"
    "$USER_HOME/.openclaw/logs"
    "$LOG_DIR"
    "$BACKUP_DIR"
  )

  for dir in "${DIRS[@]}"; do
    mkdir -p "$dir"
  done

  # Secure permissions
  chmod 700 "$USER_HOME/.openclaw"
  chmod 700 "$USER_HOME/.openclaw/credentials"

  ok "Directory structure created"
}

install_config() {
  echo "⚙️  Installing configuration..."

  OPENCLAW_CONFIG="$USER_HOME/.openclaw/openclaw.json"

  if [[ -f "$OPENCLAW_CONFIG" ]]; then
    warn "openclaw.json already exists — backing up to openclaw.json.bak"
    cp "$OPENCLAW_CONFIG" "$OPENCLAW_CONFIG.bak"
  fi

  cp "$DEPLOY_DIR/config/openclaw.json" "$OPENCLAW_CONFIG"
  chmod 600 "$OPENCLAW_CONFIG"
  chown "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_CONFIG" 2>/dev/null || true

  ok "Config installed: $OPENCLAW_CONFIG"
  warn "Edit $OPENCLAW_CONFIG to set your allowlists and alert email"
}

install_env() {
  echo "🔐 Setting up environment..."

  ENV_FILE="$DEPLOY_DIR/config/.env"

  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$DEPLOY_DIR/config/.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    warn ".env created from template — YOU MUST edit it with your API keys:"
    info "  nano $ENV_FILE"
  else
    ok ".env already exists"
  fi
}

install_seccomp() {
  echo "🔒 Installing seccomp profile..."

  # On macOS, use user-local config dir (no root access to /etc)
  if [[ "$OS" == "macos" ]]; then
    OPENCLAW_ETC="$USER_HOME/.openclaw/config"
  else
    OPENCLAW_ETC="/etc/openclaw"
  fi

  mkdir -p "$OPENCLAW_ETC"
  cp "$DEPLOY_DIR/docker/seccomp.json" "$OPENCLAW_ETC/seccomp.json"
  ok "Seccomp profile installed: $OPENCLAW_ETC/seccomp.json"

  # Create backup passphrase file if it doesn't exist
  PASSPHRASE_FILE="$OPENCLAW_ETC/backup-passphrase"
  if [ ! -f "$PASSPHRASE_FILE" ]; then
    touch "$PASSPHRASE_FILE"
    chmod 600 "$PASSPHRASE_FILE"
    chown "$OPENCLAW_USER:$OPENCLAW_USER" "$PASSPHRASE_FILE" 2>/dev/null || true
    warn "Backup passphrase file created: $PASSPHRASE_FILE"
    info "  Add a strong passphrase: echo 'your-long-random-passphrase' > $PASSPHRASE_FILE"
    info "  Or set GPG_RECIPIENT env var for GPG-based backup encryption"
  fi
}

install_systemd() {
  if [[ "$OS" == "macos" ]]; then
    warn "macOS detected — skipping systemd (use launchd or start manually)"
    return
  fi

  echo "⚙️  Installing systemd service..."
  cp "$DEPLOY_DIR/systemd/openclaw-gateway.service" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable openclaw-gateway
  ok "Systemd service installed and enabled"
}

setup_firewall() {
  if [[ "$OS" == "macos" ]]; then
    warn "macOS: configure firewall via System Preferences or pf"
    return
  fi

  if command -v ufw &>/dev/null; then
    echo "🔥 Configuring UFW firewall..."
    ufw default deny incoming 2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true
    ufw allow ssh 2>/dev/null || true
    # Allow Tailscale
    ufw allow 41641/udp 2>/dev/null || true
    # Note: 18789 is intentionally NOT opened — loopback only
    ok "UFW configured (gateway port NOT exposed to internet)"
  else
    warn "UFW not found — configure your firewall manually"
    info "Block: 18789 (gateway), expose only: 22 (SSH), 41641 (Tailscale)"
  fi
}

setup_logrotate() {
  if [[ "$OS" == "macos" ]]; then
    return
  fi

  echo "📄 Setting up log rotation..."
  cat > /etc/logrotate.d/openclaw << 'LOGROTATE'
/var/log/openclaw/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        systemctl reload openclaw-gateway 2>/dev/null || true
    endscript
}
LOGROTATE
  ok "Log rotation configured"
}

setup_backup_cron() {
  echo "⏰ Setting up backup cron..."
  chmod +x "$DEPLOY_DIR/scripts/backup.sh"
  
  CRON_JOB="0 2 * * * $DEPLOY_DIR/scripts/backup.sh >> /var/log/openclaw/backup.log 2>&1"
  
  # Add to cron if not already present
  if ! crontab -l 2>/dev/null | grep -q "backup.sh"; then
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    ok "Backup cron job added (runs at 2am daily)"
  else
    ok "Backup cron already configured"
  fi
}

make_scripts_executable() {
  chmod +x "$DEPLOY_DIR/scripts/"*.sh
  ok "Scripts made executable"
}

print_next_steps() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🎉 OpenClaw Secure Deployment — Setup Complete!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "📋 REQUIRED NEXT STEPS:"
  echo ""
  echo "1. Edit your API keys:"
  echo "   nano $DEPLOY_DIR/config/.env"
  echo ""
  echo "2. Update allowlists in OpenClaw config:"
  echo "   nano $USER_HOME/.openclaw/openclaw.json"
  echo "   → Set channels.whatsapp.allowFrom (your phone numbers)"
  echo "   → Set api.costControl.notify email"
  echo ""
  echo "3. Pull the sandbox Docker image:"
  echo "   docker pull openclaw/sandbox:1.0.0"
  echo ""
  echo "4. Run the health check:"
  echo "   openclaw doctor"
  echo ""
  echo "5. Start the gateway:"
  if [[ "$OS" != "macos" ]]; then
  echo "   systemctl start openclaw-gateway"
  else
  echo "   openclaw gateway --port 18789"
  fi
  echo ""
  echo "📋 OPTIONAL:"
  echo "   Start monitoring: docker compose -f $DEPLOY_DIR/docker/docker-compose.yml up -d"
  echo "   Grafana dashboard: http://localhost:3000"
  echo ""
  echo "📋 INCIDENT RESPONSE:"
  echo "   Compromised key: ./scripts/incident-response.sh compromised-key"
  echo "   Runaway costs:   ./scripts/incident-response.sh runaway-cost"
  echo "   Nuclear option:  ./scripts/incident-response.sh full-lockdown"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────
banner
detect_os
check_prerequisites
setup_user
setup_directories
install_config
install_env
install_seccomp
make_scripts_executable

if [[ "$MODE" == "--production" ]]; then
  install_systemd
  setup_firewall
  setup_logrotate
  setup_backup_cron
else
  warn "Dev mode — skipping systemd, firewall, logrotate, cron"
fi

print_next_steps

log "Setup complete (mode: $MODE)"
