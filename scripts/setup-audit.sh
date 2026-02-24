#!/bin/bash
# setup-audit.sh — Configure audit monitoring for The Commission service accounts
# Requires: sudo
# Usage: sudo bash scripts/setup-audit.sh
#
# This script sets up eslogger-based audit monitoring for the claude (uid=599)
# and secureclaw (uid=600) service accounts. It also configures OpenBSM audit_control
# as a secondary audit source.
#
# Prerequisites:
#   - /bin/bash must have Full Disk Access (System Settings → Privacy & Security)
#   - /usr/bin/eslogger must have Full Disk Access
#   See step 7 below for instructions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
AUDIT_LOG_DIR="/var/log/commission-audit"

echo "=== The Commission — Audit Monitoring Setup ==="

# 1. Verify running as root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run with sudo" >&2
    exit 1
fi

# 2. Verify service accounts exist
for user in claude secureclaw; do
    if ! id "$user" &>/dev/null; then
        echo "ERROR: User '$user' does not exist" >&2
        exit 1
    fi
done
echo "✓ Service accounts verified: claude ($(id -u claude)), secureclaw ($(id -u secureclaw))"

# 3. Backup and apply OpenBSM audit configs
if [[ -f /etc/security/audit_control ]]; then
    cp /etc/security/audit_control /etc/security/audit_control.bak.$(date +%Y%m%d%H%M%S)
    echo "✓ Backed up /etc/security/audit_control"
fi
if [[ -f /etc/security/audit_user ]]; then
    cp /etc/security/audit_user /etc/security/audit_user.bak.$(date +%Y%m%d%H%M%S)
    echo "✓ Backed up /etc/security/audit_user"
fi
cp "$REPO_DIR/config/audit_control.template" /etc/security/audit_control
cp "$REPO_DIR/config/audit_user.template" /etc/security/audit_user
echo "✓ Applied audit_control and audit_user"

# 4. Ensure auditd is loaded (may not be running on modern macOS)
launchctl load -w /System/Library/LaunchDaemons/com.apple.auditd.plist 2>/dev/null || true
audit -s 2>/dev/null || true
echo "✓ auditd loaded and refreshed"

# 5. Create audit log output directory
mkdir -p "$AUDIT_LOG_DIR"
chmod 755 "$AUDIT_LOG_DIR"
echo "✓ Created $AUDIT_LOG_DIR (chmod 755 for Docker mount access)"

# 6. Install eslogger audit daemon
PLIST_SRC="$REPO_DIR/launchd/com.thecommission.auditpipe.plist"
PLIST_DST="/Library/LaunchDaemons/com.thecommission.auditpipe.plist"
SCRIPT_SRC="$REPO_DIR/scripts/start-auditpipe.sh"
SCRIPT_DST="/usr/local/bin/commission-auditpipe.sh"

# Update plist to point to installed script location
sed "s|$SCRIPT_SRC|$SCRIPT_DST|g" "$PLIST_SRC" > "$PLIST_DST"
cp "$SCRIPT_SRC" "$SCRIPT_DST"
chmod +x "$SCRIPT_DST"
echo "✓ Installed auditpipe daemon script and plist"

# Restart daemon if already loaded
launchctl bootout system/com.thecommission.auditpipe 2>/dev/null || true
launchctl bootstrap system "$PLIST_DST"
echo "✓ Auditpipe daemon started"

echo ""
echo "=== IMPORTANT: Full Disk Access Required ==="
echo ""
echo "eslogger requires macOS TCC authorization to capture audit events."
echo "You MUST manually grant Full Disk Access to these binaries:"
echo ""
echo "  1. Open System Settings → Privacy & Security → Full Disk Access"
echo "  2. Click '+', press Cmd+Shift+G, add: /usr/bin/eslogger"
echo "  3. Click '+', press Cmd+Shift+G, add: /bin/bash"
echo ""
echo "Then restart the daemon:"
echo "  sudo launchctl bootout system/com.thecommission.auditpipe"
echo "  sudo launchctl bootstrap system $PLIST_DST"
echo ""
echo "=== Verification ==="
echo "After granting FDA, test with:"
echo "  sudo su - claude -c 'whoami'"
echo "  sleep 3"
echo "  cat $AUDIT_LOG_DIR/audit.log | head -1"
echo ""
echo "=== Done ==="
