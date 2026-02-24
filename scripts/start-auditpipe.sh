#!/bin/bash
# start-auditpipe.sh — Continuously convert BSM binary audit to text
# Run by launchd, writes to /var/log/commission-audit/audit.log
# The praudit -lx flag outputs one-line XML per event

set -euo pipefail

LOG_DIR="/var/log/commission-audit"
LOG_FILE="$LOG_DIR/audit.log"

mkdir -p "$LOG_DIR"

# Filter for only our users (claude=599, secureclaw=600)
# praudit converts binary BSM to readable text
# We grep for our UIDs to avoid system noise
exec praudit -lx /dev/auditpipe 2>/dev/null | \
    grep -E '"599"|"600"' >> "$LOG_FILE"
