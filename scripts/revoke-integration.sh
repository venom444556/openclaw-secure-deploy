#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# PGPClaw — Revoke Integration (Wrapper)
# Convenience wrapper for nango/scripts/revoke-nango.sh
#
# Usage:
#   ./scripts/revoke-integration.sh gmail     # Revoke Gmail
#   ./scripts/revoke-integration.sh github    # Revoke GitHub
#   ./scripts/revoke-integration.sh           # Revoke ALL
#   DRY_RUN=true ./scripts/revoke-integration.sh gmail
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REVOKE_SCRIPT="$REPO_DIR/nango/scripts/revoke-nango.sh"

if [[ ! -x "$REVOKE_SCRIPT" ]]; then
  echo "[pgpclaw] ERROR: revoke-nango.sh not found at $REVOKE_SCRIPT" >&2
  exit 1
fi

exec "$REVOKE_SCRIPT" "${1:-all}"
