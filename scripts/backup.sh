#!/usr/bin/env bash
# =============================================================
# OpenClaw Automated Backup Script
# Schedule: Daily via cron or systemd timer
# Cron:     0 2 * * * /usr/local/bin/backup-openclaw.sh
# =============================================================
set -euo pipefail

BACKUP_ROOT="/backups/openclaw"
DATE=$(date +%Y-%m-%d_%H-%M)
BACKUP_DIR="$BACKUP_ROOT/$DATE"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
LOG_FILE="/var/log/openclaw/backup.log"
GPG_RECIPIENT="${GPG_RECIPIENT:-}"                # Set your GPG key email
BACKUP_PASSPHRASE_FILE="${BACKUP_PASSPHRASE_FILE:-/etc/openclaw/backup-passphrase}"
S3_BUCKET="${BACKUP_S3_BUCKET:-}"                 # Set to enable S3 upload
RETENTION_DAYS=30

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"; }

# ── Pre-flight ─────────────────────────────────────────────────
log "=== OpenClaw Backup Starting ==="
mkdir -p "$BACKUP_DIR"

# ── 1. Configuration ───────────────────────────────────────────
log "Backing up config..."
cp "$OPENCLAW_HOME/openclaw.json" "$BACKUP_DIR/openclaw.json" 2>/dev/null || true

# ── 2. Credentials (encrypted) ────────────────────────────────
log "Backing up credentials (encrypted)..."
if [ -d "$OPENCLAW_HOME/credentials" ]; then
  if [ -n "$GPG_RECIPIENT" ]; then
    tar czf - -C "$OPENCLAW_HOME" credentials/ | \
      gpg --encrypt --recipient "$GPG_RECIPIENT" \
          --trust-model always \
          -o "$BACKUP_DIR/credentials.tar.gz.gpg"
    log "Credentials encrypted with GPG key: $GPG_RECIPIENT"
  elif [ -f "$BACKUP_PASSPHRASE_FILE" ]; then
    # Fallback: encrypt with AES using passphrase file on disk
    tar czf - -C "$OPENCLAW_HOME" credentials/ | \
      openssl enc -aes-256-cbc -pbkdf2 -salt \
        -pass "file:$BACKUP_PASSPHRASE_FILE" \
        -out "$BACKUP_DIR/credentials.tar.gz.enc"
    log "WARN: Credentials encrypted with AES (set GPG_RECIPIENT for better security)"
  else
    log "ERROR: Cannot encrypt credentials. Set GPG_RECIPIENT or create $BACKUP_PASSPHRASE_FILE"
    log "  To create: echo 'your-long-random-passphrase' > $BACKUP_PASSPHRASE_FILE && chmod 600 $BACKUP_PASSPHRASE_FILE"
    exit 1
  fi

  # Verify encryption produced a non-empty file
  ENCRYPTED_FILE=""
  [ -f "$BACKUP_DIR/credentials.tar.gz.gpg" ] && ENCRYPTED_FILE="$BACKUP_DIR/credentials.tar.gz.gpg"
  [ -f "$BACKUP_DIR/credentials.tar.gz.enc" ] && ENCRYPTED_FILE="$BACKUP_DIR/credentials.tar.gz.enc"
  if [ -n "$ENCRYPTED_FILE" ] && [ ! -s "$ENCRYPTED_FILE" ]; then
    log "ERROR: Encryption produced empty file: $ENCRYPTED_FILE"
    rm -f "$ENCRYPTED_FILE"
    exit 1
  fi
fi

# ── 3. Workspace (skills, prompts) ────────────────────────────
log "Backing up workspace..."
if [ -d "$OPENCLAW_HOME/workspace" ]; then
  tar czf "$BACKUP_DIR/workspace.tar.gz" -C "$OPENCLAW_HOME" workspace/
fi

# ── 4. Sessions (last 7 days only) ───────────────────────────
log "Backing up recent sessions..."
if [ -d "$OPENCLAW_HOME/sessions" ]; then
  find "$OPENCLAW_HOME/sessions/" -mtime -7 -print0 | \
    tar czf "$BACKUP_DIR/sessions-7d.tar.gz" --null -T -
fi

# ── 5. Logs (last 7 days) ─────────────────────────────────────
log "Backing up logs..."
if [ -d "/var/log/openclaw" ]; then
  find /var/log/openclaw -mtime -7 -print0 | \
    tar czf "$BACKUP_DIR/logs-7d.tar.gz" --null -T - 2>/dev/null || true
fi

# ── 6. Create manifest ────────────────────────────────────────
log "Creating manifest..."
{
  echo "OpenClaw Backup Manifest"
  echo "Date: $(date -Iseconds)"
  echo "Host: $(hostname)"
  echo ""
  echo "Files:"
  ls -lh "$BACKUP_DIR/"
  echo ""
  echo "Total size:"
  du -sh "$BACKUP_DIR/"
} > "$BACKUP_DIR/MANIFEST.txt"

# ── 7. S3 Upload (optional) ───────────────────────────────────
if [ -n "$S3_BUCKET" ]; then
  log "Uploading to S3: s3://$S3_BUCKET/$DATE/"
  aws s3 cp "$BACKUP_DIR/" "s3://$S3_BUCKET/$DATE/" \
    --recursive \
    --sse AES256 \
    --no-progress
  log "S3 upload complete"
fi

# ── 8. Cleanup old local backups ──────────────────────────────
log "Cleaning up backups older than $RETENTION_DAYS days..."
find "$BACKUP_ROOT" -maxdepth 1 -type d -mtime "+$RETENTION_DAYS" -exec rm -rf {} + 2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
log "=== Backup complete. Size: $TOTAL_SIZE. Location: $BACKUP_DIR ==="
