#!/bin/bash
# setup-audit.sh — Configure OpenBSM for The Commission service accounts
# Requires: sudo
# Usage: sudo bash scripts/setup-audit.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
AUDIT_LOG_DIR="/var/log/commission-audit"

echo "=== The Commission — OpenBSM Audit Setup ==="

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

# 3. Backup existing audit configs
if [[ -f /etc/security/audit_control ]]; then
    cp /etc/security/audit_control /etc/security/audit_control.bak.$(date +%Y%m%d%H%M%S)
    echo "✓ Backed up /etc/security/audit_control"
fi
if [[ -f /etc/security/audit_user ]]; then
    cp /etc/security/audit_user /etc/security/audit_user.bak.$(date +%Y%m%d%H%M%S)
    echo "✓ Backed up /etc/security/audit_user"
fi

# 4. Apply templates
cp "$REPO_DIR/config/audit_control.template" /etc/security/audit_control
cp "$REPO_DIR/config/audit_user.template" /etc/security/audit_user
echo "✓ Applied audit_control and audit_user"

# 5. Create audit log output directory for praudit
mkdir -p "$AUDIT_LOG_DIR"
chmod 750 "$AUDIT_LOG_DIR"
echo "✓ Created $AUDIT_LOG_DIR"

# 6. Refresh audit daemon
audit -s 2>/dev/null || echo "⚠ Could not refresh audit daemon — reboot may be required"
echo "✓ Audit daemon refreshed"

# 7. Verify audit is capturing
echo ""
echo "=== Verification ==="
echo "Run a test command as the claude user:"
echo "  su - claude -c 'whoami'"
echo "Then check for output:"
echo "  praudit /var/audit/current | tail -20"
echo ""
echo "If no output, check SIP status: csrutil status"
echo "=== Done ==="
