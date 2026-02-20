#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# PGPClaw — Nango Self-Hosted Setup
# Generates encryption key + DB password, stores in OpenBao,
# starts Nango services, prints OAuth config instructions.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
NANGO_URL="http://localhost:3003"
NANGO_UI_URL="http://localhost:3009"
DRY_RUN="${DRY_RUN:-false}"

log()  { echo "[pgpclaw] $(date '+%H:%M:%S') $*"; }
err()  { echo "[pgpclaw] ERROR: $*" >&2; exit 1; }

# ── Preflight ────────────────────────────────────────────────

command -v openssl >/dev/null 2>&1 || err "openssl not found."
command -v docker  >/dev/null 2>&1 || err "docker not found."

STORE_SECRET="$REPO_DIR/openbao/scripts/store-secret.sh"
[[ -x "$STORE_SECRET" ]] || err "store-secret.sh not found or not executable."

# ── Step 1: Generate secrets ─────────────────────────────────

log "Generating Nango encryption key..."
NANGO_ENCRYPTION_KEY=$(openssl rand -hex 32)

log "Generating Nango database password..."
NANGO_DB_PASSWORD=$(openssl rand -hex 24)

# ── Step 2: Store in OpenBao ─────────────────────────────────

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[DRY RUN] would store nango-encryption-key in OpenBao"
  echo "[DRY RUN] would store nango-db-password in OpenBao"
  echo "[DRY RUN] would start Nango services"
  exit 0
fi

log "Storing Nango secrets in OpenBao..."
"$STORE_SECRET" nango-encryption-key "$NANGO_ENCRYPTION_KEY"
"$STORE_SECRET" nango-db-password "$NANGO_DB_PASSWORD"

# ── Step 3: Start Nango services ────────────────────────────

log "Starting Nango services..."
export NANGO_ENCRYPTION_KEY
export NANGO_DB_PASSWORD

cd "$REPO_DIR"
docker compose -f docker/docker-compose.yml --profile oauth up -d nango-db nango-redis nango-server

# ── Step 4: Wait for health ──────────────────────────────────

log "Waiting for Nango to be ready..."
for i in $(seq 1 30); do
  if curl -sf "${NANGO_URL}/health" >/dev/null 2>&1; then
    log "Nango is ready."
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    err "Nango did not start within 60 seconds."
  fi
  sleep 2
done

# ── Step 5: Print instructions ───────────────────────────────

echo ""
echo "========================================================"
echo "  Nango OAuth Proxy is running"
echo "========================================================"
echo ""
echo "  Server API:   $NANGO_URL"
echo "  Connect UI:   $NANGO_UI_URL"
echo ""
echo "  To add an OAuth integration:"
echo ""
echo "  1. Go to the provider's developer console and create an OAuth app:"
echo "     - Gmail:   https://console.cloud.google.com/apis/credentials"
echo "     - GitHub:  https://github.com/settings/developers"
echo "     - Notion:  https://www.notion.so/my-integrations"
echo ""
echo "  2. Set the OAuth callback URL to:"
echo "     ${NANGO_URL}/oauth/callback"
echo ""
echo "  3. Open the Nango Connect UI at:"
echo "     ${NANGO_UI_URL}"
echo ""
echo "  4. Register each integration with its client ID and secret."
echo ""
echo "  5. To proxy API calls through Nango (agent never sees tokens):"
echo "     curl -H 'Connection-Id: <conn-id>' \\"
echo "          -H 'Provider-Config-Key: <provider>' \\"
echo "          ${NANGO_URL}/proxy/<provider>/<endpoint>"
echo ""
echo "  Free tier limits: 10 connections, 100k proxy requests."
echo "========================================================"

# Clear sensitive vars
unset NANGO_ENCRYPTION_KEY NANGO_DB_PASSWORD
