#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# PGPClaw — Hardware & Security Validation
# Checks RAM, Docker, required tools, and verifies the
# secureclaw user cannot escalate privileges.
# ============================================================

DRY_RUN="${DRY_RUN:-false}"
MIN_RAM_GB=8
REQUIRED_CMDS=(docker curl jq openssl)

log()  { echo "[pgpclaw] $(date '+%H:%M:%S') $*"; }
warn() { echo "[pgpclaw] WARNING: $*" >&2; }
err()  { echo "[pgpclaw] ERROR: $*" >&2; exit 1; }
pass() { echo "[pgpclaw]   ✓ $*"; }
fail() { echo "[pgpclaw]   ✗ $*"; FAILURES=$((FAILURES + 1)); }

FAILURES=0

echo ""
echo "========================================================"
echo "  PGPClaw — Hardware & Security Validation"
echo "========================================================"
echo ""

# ── RAM Check ────────────────────────────────────────────────

log "Checking RAM..."
if [[ "$(uname)" == "Darwin" ]]; then
  RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
  RAM_GB=$((RAM_BYTES / 1073741824))
else
  RAM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
  RAM_GB=$((RAM_KB / 1048576))
fi

if [[ "$RAM_GB" -ge "$MIN_RAM_GB" ]]; then
  pass "RAM: ${RAM_GB}GB (minimum: ${MIN_RAM_GB}GB)"
else
  fail "RAM: ${RAM_GB}GB (minimum: ${MIN_RAM_GB}GB required)"
fi

# ── Required Commands ────────────────────────────────────────

log "Checking required tools..."
for CMD in "${REQUIRED_CMDS[@]}"; do
  if command -v "$CMD" >/dev/null 2>&1; then
    pass "$CMD: found"
  else
    fail "$CMD: not found"
  fi
done

# Check bao CLI separately (may need brew path)
if command -v bao >/dev/null 2>&1; then
  pass "bao CLI: found"
elif [[ -x /opt/homebrew/bin/bao ]]; then
  pass "bao CLI: found at /opt/homebrew/bin/bao"
else
  fail "bao CLI: not found (install: brew install openbao)"
fi

# ── Docker Running ───────────────────────────────────────────

log "Checking Docker..."
if docker info >/dev/null 2>&1; then
  pass "Docker: running"
else
  fail "Docker: not running or not accessible"
fi

# ── Sudoers Check ────────────────────────────────────────────

log "Checking privilege escalation..."
CURRENT_USER=$(whoami)

# Check if current user is in sudoers
if sudo -n true 2>/dev/null; then
  warn "Current user '$CURRENT_USER' has passwordless sudo. Consider restricting."
fi

# Check if secureclaw user exists and verify its constraints
if id secureclaw >/dev/null 2>&1; then
  pass "secureclaw user: exists"

  # Verify secureclaw is NOT in admin/sudo/wheel group
  GROUPS=$(id -Gn secureclaw 2>/dev/null || echo "")
  if echo "$GROUPS" | grep -qE '\b(admin|sudo|wheel)\b'; then
    fail "secureclaw is in a privileged group: $GROUPS"
  else
    pass "secureclaw: not in admin/sudo/wheel groups"
  fi

  # Verify secureclaw has no sudoers entry
  if [[ -f /etc/sudoers ]]; then
    if grep -q "secureclaw" /etc/sudoers 2>/dev/null; then
      fail "secureclaw has an entry in /etc/sudoers"
    else
      pass "secureclaw: no sudoers entry"
    fi
  fi

  # Check sudoers.d directory
  if [[ -d /etc/sudoers.d ]]; then
    if ls /etc/sudoers.d/ 2>/dev/null | xargs grep -l "secureclaw" 2>/dev/null; then
      fail "secureclaw has a file in /etc/sudoers.d/"
    else
      pass "secureclaw: no sudoers.d entry"
    fi
  fi

  # Verify secureclaw cannot write to sudoers
  if [[ "$(uname)" == "Darwin" ]]; then
    SUDOERS_OWNER=$(stat -f '%Su' /etc/sudoers 2>/dev/null || echo "unknown")
  else
    SUDOERS_OWNER=$(stat -c '%U' /etc/sudoers 2>/dev/null || echo "unknown")
  fi
  if [[ "$SUDOERS_OWNER" == "root" ]]; then
    pass "sudoers owned by root (secureclaw cannot modify)"
  else
    fail "sudoers not owned by root: $SUDOERS_OWNER"
  fi
else
  warn "secureclaw user does not exist yet (will be created by setup.sh)"
fi

# ── Disk Space ───────────────────────────────────────────────

log "Checking disk space..."
if [[ "$(uname)" == "Darwin" ]]; then
  AVAIL_GB=$(df -g / | tail -1 | awk '{print $4}')
else
  AVAIL_GB=$(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G')
fi

if [[ "$AVAIL_GB" -ge 20 ]]; then
  pass "Disk: ${AVAIL_GB}GB available"
else
  fail "Disk: ${AVAIL_GB}GB available (recommend 20GB+)"
fi

# ── macOS Keychain ───────────────────────────────────────────

if [[ "$(uname)" == "Darwin" ]]; then
  log "Checking macOS Keychain..."
  if command -v security >/dev/null 2>&1; then
    pass "macOS Keychain: available"
  else
    fail "macOS Keychain: security CLI not found"
  fi
fi

# ── Summary ──────────────────────────────────────────────────

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "========================================================"
  echo "  All checks passed. Ready for PGPClaw deployment."
  echo "========================================================"
else
  echo "========================================================"
  echo "  $FAILURES check(s) failed. Fix issues before deploying."
  echo "========================================================"
  exit 1
fi
