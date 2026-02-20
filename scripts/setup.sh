#!/usr/bin/env bash
# =============================================================
# PGPClaw — Master Setup Script
# Tested on: macOS 14+, Ubuntu 22.04+, Debian 12+
# Usage: ./setup.sh [--profile core|monitoring|oauth|full] [--dry-run]
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PROFILE="${PGPCLAW_PROFILE:-core}"
DRY_RUN="${DRY_RUN:-false}"
LOG_FILE="/tmp/pgpclaw-setup.log"
SERVICE_USER="secureclaw"

# -- Parse args ----------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --profile)    shift; PROFILE="${1:-core}" ;;
    --dry-run)    DRY_RUN=true ;;
    core|monitoring|oauth|full) PROFILE="$arg" ;;
    *)            ;;
  esac
  shift 2>/dev/null || true
done

# -- Colors --------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
err()  { echo -e "${RED}❌ $*${NC}"; exit 1; }
info() { echo -e "   $*"; }
step() { echo -e "${BLUE}${BOLD}── $* ──${NC}"; }

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"; }
dry() { if [[ "$DRY_RUN" == "true" ]]; then echo "  [DRY-RUN] $*"; return 0; else return 1; fi; }

# ══════════════════════════════════════════════════════════════
banner() {
cat << 'BANNER'
  ____   ____ ____   ____ _
 |  _ \ / ___|  _ \ / ___| | __ ___      __
 | |_) | |  _| |_) | |   | |/ _` \ \ /\ / /
 |  __/| |_| |  __/| |___| | (_| |\ V  V /
 |_|    \____|_|    \____|_|\__,_| \_/\_/
       Hardened AI Gateway Security Layer

BANNER
  echo "  Profile:  $PROFILE"
  echo "  Dry-run:  $DRY_RUN"
  echo "  Repo:     $REPO_DIR"
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

# -- Step 1: Create secureclaw service user ------------------------------------
create_service_user() {
  step "Creating service user: $SERVICE_USER"

  if id "$SERVICE_USER" &>/dev/null; then
    ok "$SERVICE_USER user already exists"
    return
  fi

  if dry "Would create user: $SERVICE_USER"; then return; fi

  if [[ "$OS" == "macos" ]]; then
    # macOS: create a standard user (not admin, no sudo)
    # Find next available UID above 500
    NEXT_UID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1)
    NEXT_UID=$((NEXT_UID + 1))

    sudo dscl . -create "/Users/$SERVICE_USER"
    sudo dscl . -create "/Users/$SERVICE_USER" UserShell /usr/bin/false
    sudo dscl . -create "/Users/$SERVICE_USER" RealName "PGPClaw Service Account"
    sudo dscl . -create "/Users/$SERVICE_USER" UniqueID "$NEXT_UID"
    sudo dscl . -create "/Users/$SERVICE_USER" PrimaryGroupID 20  # staff
    sudo dscl . -create "/Users/$SERVICE_USER" NFSHomeDirectory "/Users/$SERVICE_USER"
    sudo mkdir -p "/Users/$SERVICE_USER"
    sudo chown "$SERVICE_USER:staff" "/Users/$SERVICE_USER"
    ok "Created macOS user: $SERVICE_USER (UID $NEXT_UID)"
  else
    # Linux: create non-login system user
    sudo useradd -r -s /usr/bin/false -m -d "/home/$SERVICE_USER" \
      -c "PGPClaw Service Account" "$SERVICE_USER"
    ok "Created Linux user: $SERVICE_USER"
  fi
}

# -- Step 2: Validate hardware + security --------------------------------------
validate_system() {
  step "Validating system requirements"

  if [[ -x "$REPO_DIR/scripts/validate-hardware.sh" ]]; then
    "$REPO_DIR/scripts/validate-hardware.sh" || {
      warn "Hardware validation reported issues — review above"
    }
  else
    warn "validate-hardware.sh not found — skipping hardware checks"
  fi
}

# -- Step 3: Check prerequisites -----------------------------------------------
check_prerequisites() {
  step "Checking prerequisites"
  MISSING=()

  # Docker (required)
  if command -v docker &>/dev/null; then
    ok "Docker $(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  else
    MISSING+=("docker")
    err "Docker not found — install from https://docs.docker.com/engine/install/"
  fi

  # Docker Compose
  if docker compose version &>/dev/null; then
    ok "Docker Compose $(docker compose version --short 2>/dev/null)"
  else
    MISSING+=("docker-compose")
    err "Docker Compose not found — install Docker Desktop or the compose plugin"
  fi

  # bao CLI (required for OpenBao management)
  if command -v bao &>/dev/null; then
    ok "OpenBao CLI $(bao version 2>/dev/null | head -1)"
  else
    MISSING+=("bao")
    warn "OpenBao CLI (bao) not found"
    if [[ "$OS" == "macos" ]]; then
      info "Install: brew install openbao"
    else
      info "Install: https://github.com/openbao/openbao/releases"
    fi
  fi

  # curl, jq, openssl (required)
  for cmd in curl jq openssl; do
    if command -v "$cmd" &>/dev/null; then
      ok "$cmd"
    else
      MISSING+=("$cmd")
      warn "$cmd not found"
    fi
  done

  # Node.js (recommended)
  if command -v node &>/dev/null; then
    NODE_VER=$(node --version | sed 's/v//' | cut -d. -f1)
    if [[ "$NODE_VER" -ge 22 ]]; then
      ok "Node.js $(node --version)"
    else
      warn "Node.js $NODE_VER found — recommend 22+"
    fi
  else
    warn "Node.js not found — needed for OpenClaw"
    info "Install: https://nodejs.org"
  fi

  # OpenClaw
  if command -v openclaw &>/dev/null; then
    ok "OpenClaw $(openclaw --version 2>/dev/null || echo 'installed')"
  else
    warn "OpenClaw not installed — run: npm install -g openclaw@latest"
  fi

  # Tailscale (optional)
  if command -v tailscale &>/dev/null; then
    ok "Tailscale installed"
  else
    info "Tailscale not found (optional, recommended for remote access)"
  fi

  if [[ ${#MISSING[@]} -gt 0 ]]; then
    err "Missing required tools: ${MISSING[*]}"
  fi

  echo ""
}

# -- Step 4: Validate secureclaw cannot escalate --------------------------------
validate_security() {
  step "Validating security constraints"

  if ! id "$SERVICE_USER" &>/dev/null; then
    warn "$SERVICE_USER user doesn't exist yet — skipping security checks"
    return
  fi

  # Check secureclaw is NOT in admin/sudo/wheel groups
  USER_GROUPS=$(id -Gn "$SERVICE_USER" 2>/dev/null || echo "")
  for BAD_GROUP in admin sudo wheel; do
    if echo "$USER_GROUPS" | grep -qw "$BAD_GROUP"; then
      err "$SERVICE_USER is in '$BAD_GROUP' group — this is a security risk"
    fi
  done
  ok "$SERVICE_USER is not in privileged groups"

  # Check no sudoers entry for secureclaw
  if [[ "$OS" != "macos" ]]; then
    if sudo grep -r "$SERVICE_USER" /etc/sudoers /etc/sudoers.d/ 2>/dev/null | grep -v "^#" | grep -q .; then
      err "$SERVICE_USER has sudoers entry — remove it"
    fi
    ok "No sudoers entry for $SERVICE_USER"
  fi

  # Verify sudoers owned by root
  if [[ -f /etc/sudoers ]]; then
    SUDOERS_OWNER=$(stat -c '%U' /etc/sudoers 2>/dev/null || stat -f '%Su' /etc/sudoers 2>/dev/null || echo "unknown")
    if [[ "$SUDOERS_OWNER" == "root" ]]; then
      ok "sudoers owned by root"
    else
      warn "sudoers owned by '$SUDOERS_OWNER' — expected root"
    fi
  fi

  echo ""
}

# -- Step 5: Set up directories ------------------------------------------------
setup_directories() {
  step "Setting up directories"

  USER_HOME=$(eval echo "~$SERVICE_USER" 2>/dev/null || echo "$HOME")
  OPENCLAW_HOME="$USER_HOME/.openclaw"

  DIRS=(
    "$OPENCLAW_HOME"
    "$OPENCLAW_HOME/config"
    "$OPENCLAW_HOME/credentials"
    "$OPENCLAW_HOME/workspace/skills"
    "$OPENCLAW_HOME/sessions"
    "$OPENCLAW_HOME/logs"
    "$OPENCLAW_HOME/backups"
  )

  if dry "Would create directories under $OPENCLAW_HOME"; then return; fi

  for dir in "${DIRS[@]}"; do
    mkdir -p "$dir"
  done

  # Secure permissions
  chmod 700 "$OPENCLAW_HOME"
  chmod 700 "$OPENCLAW_HOME/credentials"
  chown -R "$SERVICE_USER" "$OPENCLAW_HOME" 2>/dev/null || true

  ok "Directory structure created under $OPENCLAW_HOME"
}

# -- Step 6: Build ephemeral runner image --------------------------------------
build_runner_image() {
  step "Building ephemeral runner image"

  if dry "Would build pgpclaw/ephemeral-runner:local"; then return; fi

  if [[ -f "$REPO_DIR/docker/ephemeral-runner/Dockerfile" ]]; then
    docker build -t pgpclaw/ephemeral-runner:local \
      "$REPO_DIR/docker/ephemeral-runner/" \
      --quiet
    ok "Built pgpclaw/ephemeral-runner:local"
  else
    warn "Ephemeral runner Dockerfile not found — skipping"
  fi
}

# -- Step 7: Bootstrap OpenBao -------------------------------------------------
bootstrap_openbao() {
  step "Bootstrapping OpenBao"

  if dry "Would bootstrap OpenBao (init, unseal, policies, AppRoles)"; then return; fi

  # Start OpenBao container first
  docker compose -f "$REPO_DIR/docker/docker-compose.yml" \
    --profile core up -d openbao

  # Wait for container to be healthy
  echo "  Waiting for OpenBao to start..."
  for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:8200/v1/sys/health -o /dev/null 2>/dev/null; then
      break
    fi
    sleep 2
  done

  # Check if already initialized
  INIT_STATUS=$(curl -sf http://127.0.0.1:8200/v1/sys/init 2>/dev/null || echo '{}')
  if echo "$INIT_STATUS" | grep -q '"initialized":true'; then
    ok "OpenBao already initialized — skipping bootstrap"
    # Just unseal if needed
    if [[ -x "$REPO_DIR/openbao/scripts/unseal-bao.sh" ]]; then
      "$REPO_DIR/openbao/scripts/unseal-bao.sh" || true
    fi
    return
  fi

  # Run bootstrap
  if [[ -x "$REPO_DIR/openbao/scripts/bootstrap-bao.sh" ]]; then
    "$REPO_DIR/openbao/scripts/bootstrap-bao.sh"
    ok "OpenBao bootstrapped"
  else
    err "bootstrap-bao.sh not found"
  fi
}

# -- Step 8: Set up Nango (if oauth/full profile) -----------------------------
setup_nango() {
  if [[ "$PROFILE" != "oauth" && "$PROFILE" != "full" ]]; then
    info "Nango setup skipped (profile: $PROFILE)"
    return
  fi

  step "Setting up Nango OAuth proxy"

  if dry "Would run nango/scripts/setup-nango.sh"; then return; fi

  if [[ -x "$REPO_DIR/nango/scripts/setup-nango.sh" ]]; then
    "$REPO_DIR/nango/scripts/setup-nango.sh"
    ok "Nango configured"
  else
    warn "setup-nango.sh not found — skipping Nango setup"
  fi
}

# -- Step 9: Install config + seccomp -----------------------------------------
install_config() {
  step "Installing configuration"

  USER_HOME=$(eval echo "~$SERVICE_USER" 2>/dev/null || echo "$HOME")

  if dry "Would install config to $USER_HOME/.openclaw/"; then return; fi

  OPENCLAW_CONFIG="$USER_HOME/.openclaw/openclaw.json"

  if [[ -f "$OPENCLAW_CONFIG" ]]; then
    warn "openclaw.json already exists — backing up"
    cp "$OPENCLAW_CONFIG" "$OPENCLAW_CONFIG.bak"
  fi

  cp "$REPO_DIR/config/openclaw.json" "$OPENCLAW_CONFIG"
  chmod 600 "$OPENCLAW_CONFIG"
  chown "$SERVICE_USER" "$OPENCLAW_CONFIG" 2>/dev/null || true
  ok "Config installed: $OPENCLAW_CONFIG"

  # Create .env from template if it doesn't exist
  ENV_FILE="$REPO_DIR/config/.env"
  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$REPO_DIR/config/.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok ".env created from template"
  fi

  # Install seccomp profile
  if [[ "$OS" == "macos" ]]; then
    SECCOMP_DIR="$USER_HOME/.openclaw/config"
  else
    SECCOMP_DIR="/etc/openclaw"
  fi
  mkdir -p "$SECCOMP_DIR"
  cp "$REPO_DIR/docker/seccomp.json" "$SECCOMP_DIR/seccomp.json"
  ok "Seccomp profile installed"
}

# -- Step 10: Install launchd / systemd ---------------------------------------
install_service() {
  step "Installing service auto-start"

  if dry "Would install launchd/systemd services"; then return; fi

  if [[ "$OS" == "macos" ]]; then
    LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
    mkdir -p "$LAUNCH_AGENTS"

    for PLIST in com.pgpclaw.openbao.plist com.pgpclaw.gateway.plist; do
      if [[ -f "$REPO_DIR/launchd/$PLIST" ]]; then
        # Replace __REPO_DIR__ placeholder with actual path
        sed "s|__REPO_DIR__|$REPO_DIR|g" "$REPO_DIR/launchd/$PLIST" \
          > "$LAUNCH_AGENTS/$PLIST"
        launchctl load "$LAUNCH_AGENTS/$PLIST" 2>/dev/null || true
        ok "Installed launchd: $PLIST"
      fi
    done
  else
    if [[ -f "$REPO_DIR/systemd/openclaw-gateway.service" ]]; then
      sudo cp "$REPO_DIR/systemd/openclaw-gateway.service" /etc/systemd/system/
      sudo systemctl daemon-reload
      sudo systemctl enable openclaw-gateway
      ok "Systemd service installed and enabled"
    fi
  fi
}

# -- Step 11: Make scripts executable ------------------------------------------
make_scripts_executable() {
  step "Making scripts executable"

  if dry "Would chmod +x all scripts"; then return; fi

  find "$REPO_DIR" -name "*.sh" -exec chmod +x {} \;
  ok "All scripts made executable"
}

# -- Step 12: Start gateway + smoke test ---------------------------------------
start_and_test() {
  step "Starting gateway"

  if dry "Would start gateway with profile: $PROFILE"; then return; fi

  if [[ -x "$REPO_DIR/scripts/start-gateway.sh" ]]; then
    "$REPO_DIR/scripts/start-gateway.sh" "$PROFILE" || {
      warn "Gateway start had issues — check logs"
    }
  fi

  # Smoke test: check OpenBao is unsealed
  echo ""
  echo "  Running smoke tests..."

  if curl -sf http://127.0.0.1:8200/v1/sys/health 2>/dev/null | grep -q '"sealed":false'; then
    ok "OpenBao is running and unsealed"
  else
    warn "OpenBao health check failed"
  fi

  # Check gateway is listening
  if curl -sf http://127.0.0.1:18789/health -o /dev/null 2>/dev/null; then
    ok "Gateway is responding on port 18789"
  else
    warn "Gateway not responding yet (may still be starting)"
  fi

  echo ""
}

# -- Security Posture Summary --------------------------------------------------
print_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🎉 PGPClaw Setup Complete!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "📊 SECURITY POSTURE:"
  echo "   Service user:    $SERVICE_USER (non-login, no sudo)"
  echo "   Secrets:         OpenBao (Keychain-backed unseal)"
  echo "   API keys:        Never on disk — fetched at runtime"
  echo "   Execution:       Ephemeral containers (--rm)"
  echo "   Network:         Loopback only (127.0.0.1)"
  echo "   Profile:         $PROFILE"
  echo ""
  echo "📋 STORE YOUR FIRST SECRET:"
  echo "   ./openbao/scripts/store-secret.sh anthropic-api-key sk-ant-xxx"
  echo ""
  echo "📋 ADD MORE SECRETS:"
  echo "   ./openbao/scripts/store-secret.sh openai-api-key sk-xxx"
  echo "   ./openbao/scripts/store-secret.sh telegram-bot-token xxx"
  echo "   ./openbao/scripts/store-secret.sh discord-bot-token xxx"
  echo ""

  if [[ "$PROFILE" == "oauth" || "$PROFILE" == "full" ]]; then
    echo "📋 CONFIGURE OAUTH (Nango):"
    echo "   Dashboard: http://localhost:3003"
    echo "   Add providers: Gmail, GitHub, Google Drive, Notion, Slack"
    echo ""
  fi

  if [[ "$PROFILE" == "monitoring" || "$PROFILE" == "full" ]]; then
    echo "📋 MONITORING:"
    echo "   Grafana:      http://localhost:3000"
    echo "   Prometheus:   http://localhost:9090"
    echo "   Alertmanager: http://localhost:9093"
    echo ""
  fi

  echo "📋 INCIDENT RESPONSE:"
  echo "   Seal vault:      ./scripts/incident-response.sh bao-seal"
  echo "   Revoke OAuth:    ./scripts/incident-response.sh nango-revoke"
  echo "   Compromised key: ./scripts/incident-response.sh compromised-key"
  echo "   Full lockdown:   ./scripts/incident-response.sh full-lockdown"
  echo ""
  echo "📋 MANAGEMENT:"
  echo "   Rotate secrets:  ./scripts/rotate-secrets.sh"
  echo "   Backup:          ./scripts/backup.sh"
  echo "   Validate:        ./scripts/validate-hardware.sh"
  echo ""
}

# -- Main ----------------------------------------------------------------------
banner
detect_os
log "PGPClaw setup starting (profile: $PROFILE, dry-run: $DRY_RUN)"

create_service_user
validate_system
check_prerequisites
validate_security
setup_directories
make_scripts_executable
build_runner_image
bootstrap_openbao
setup_nango
install_config
install_service
start_and_test
print_summary

log "PGPClaw setup complete (profile: $PROFILE)"
