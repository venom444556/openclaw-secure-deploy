#!/bin/bash
# start-auditpipe.sh — Capture audit events for Commission service accounts
# Run by launchd as root, writes to /var/log/commission-audit/audit.log
#
# Uses eslogger (Endpoint Security, macOS 13+) instead of OpenBSM praudit
# because SIP blocks auditd on modern macOS.
# Output: one JSON object per line, filtered to UIDs 599 (claude) and 600 (secureclaw).
#
# Prerequisites:
#   - /bin/bash must have Full Disk Access (System Settings → Privacy & Security)
#   - /usr/bin/eslogger must have Full Disk Access

set -euo pipefail

LOG_DIR="/var/log/commission-audit"
LOG_FILE="$LOG_DIR/audit.log"

mkdir -p "$LOG_DIR"

# eslogger outputs JSON events to stdout
# Subscribe to: exec, open, write, rename, unlink, signal
# Filter for our service account UIDs only
# eslogger JSON uses "euid", "ruid", "auid" — not bare "uid"
exec eslogger exec open write rename unlink signal 2>/dev/null | \
    grep --line-buffered -E '"[era]uid"\s*:\s*(599|600)' >> "$LOG_FILE"
