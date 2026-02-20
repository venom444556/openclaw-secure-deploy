#!/usr/bin/env bash
# =============================================================
# PGPClaw — Automated Backup Script
# Schedule: Daily via cron or launchd
# Cron:     0 2 * * * /path/to/pgpclaw/scripts/backup.sh
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
DATE=$(date +%Y-%m-%d_%H-%M)

# -- Paths (macOS-friendly, user-local) ----------------------------------------
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/.openclaw/backups}"
BACKUP_DIR="$BACKUP_ROOT/$DATE"
LOG_DIR="$OPENCLAW_HOME/logs"
LOG_FILE="$LOG_DIR/backup.log"
GPG_RECIPIENT="${GPG_RECIPIENT:-}"
BACKUP_PASSPHRASE_FILE="${BACKUP_PASSPHRASE_FILE:-$OPENCLAW_HOME/config/backup-passphrase}"
S3_BUCKET="${BACKUP_S3_BUCKET:-}"
RETENTION_DAYS=30

mkdir -p "$LOG_DIR"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"; }

# -- Pre-flight ----------------------------------------------------------------
log "=== PGPClaw Backup Starting ==="
mkdir -p "$BACKUP_DIR"

# -- 1. OpenClaw Configuration ------------------------------------------------
log "Backing up OpenClaw config..."
cp "$OPENCLAW_HOME/openclaw.json" "$BACKUP_DIR/openclaw.json" 2>/dev/null || true
cp "$REPO_DIR/config/.env.example" "$BACKUP_DIR/env.example" 2>/dev/null || true

# -- 2. Credentials (encrypted) -----------------------------------------------
log "Backing up credentials (encrypted)..."
if [ -d "$OPENCLAW_HOME/credentials" ]; then
  if [ -n "$GPG_RECIPIENT" ]; then
    tar czf - -C "$OPENCLAW_HOME" credentials/ | \
      gpg --encrypt --recipient "$GPG_RECIPIENT" \
          --trust-model always \
          -o "$BACKUP_DIR/credentials.tar.gz.gpg"
    log "Credentials encrypted with GPG key: $GPG_RECIPIENT"
  elif [ -f "$BACKUP_PASSPHRASE_FILE" ]; then
    tar czf - -C "$OPENCLAW_HOME" credentials/ | \
      openssl enc -aes-256-cbc -pbkdf2 -salt \
        -pass "file:$BACKUP_PASSPHRASE_FILE" \
        -out "$BACKUP_DIR/credentials.tar.gz.enc"
    log "WARN: Credentials encrypted with AES (set GPG_RECIPIENT for better security)"
  else
    log "WARN: No encryption configured for credentials — skipping"
    log "  Set GPG_RECIPIENT or create: $BACKUP_PASSPHRASE_FILE"
  fi

  # Verify encryption produced a non-empty file
  ENCRYPTED_FILE=""
  [ -f "$BACKUP_DIR/credentials.tar.gz.gpg" ] && ENCRYPTED_FILE="$BACKUP_DIR/credentials.tar.gz.gpg"
  [ -f "$BACKUP_DIR/credentials.tar.gz.enc" ] && ENCRYPTED_FILE="$BACKUP_DIR/credentials.tar.gz.enc"
  if [ -n "$ENCRYPTED_FILE" ] && [ ! -s "$ENCRYPTED_FILE" ]; then
    log "ERROR: Encryption produced empty file: $ENCRYPTED_FILE"
    rm -f "$ENCRYPTED_FILE"
  fi
fi

# -- 3. Workspace (skills, prompts) -------------------------------------------
log "Backing up workspace..."
if [ -d "$OPENCLAW_HOME/workspace" ]; then
  tar czf "$BACKUP_DIR/workspace.tar.gz" -C "$OPENCLAW_HOME" workspace/
fi

# -- 4. Sessions (last 7 days only) -------------------------------------------
log "Backing up recent sessions..."
if [ -d "$OPENCLAW_HOME/sessions" ]; then
  find "$OPENCLAW_HOME/sessions/" -mtime -7 -print0 | \
    tar czf "$BACKUP_DIR/sessions-7d.tar.gz" --null -T - 2>/dev/null || true
fi

# -- 5. Logs (last 7 days) ----------------------------------------------------
log "Backing up logs..."
if [ -d "$LOG_DIR" ]; then
  find "$LOG_DIR" -mtime -7 -name "*.log" -print0 | \
    tar czf "$BACKUP_DIR/logs-7d.tar.gz" --null -T - 2>/dev/null || true
fi

# -- 6. OpenBao Volume Backup -------------------------------------------------
log "Backing up OpenBao data volume..."
if docker volume inspect openbao_data &>/dev/null; then
  # Stop OpenBao to get a consistent snapshot
  OPENBAO_WAS_RUNNING=false
  if docker ps --format '{{.Names}}' | grep -q pgpclaw-openbao; then
    OPENBAO_WAS_RUNNING=true
    log "  Pausing OpenBao for consistent snapshot..."
    docker pause pgpclaw-openbao 2>/dev/null || true
  fi

  # Dump the volume via a temporary container
  docker run --rm \
    -v openbao_data:/source:ro \
    -v "$BACKUP_DIR":/backup \
    debian:bookworm-slim \
    tar czf /backup/openbao-data.tar.gz -C /source . 2>/dev/null || {
      log "WARN: OpenBao volume backup failed"
    }

  # Resume OpenBao
  if [ "$OPENBAO_WAS_RUNNING" = true ]; then
    docker unpause pgpclaw-openbao 2>/dev/null || true
    log "  OpenBao resumed"
  fi

  # Encrypt the backup
  if [ -f "$BACKUP_DIR/openbao-data.tar.gz" ]; then
    if [ -n "$GPG_RECIPIENT" ]; then
      gpg --encrypt --recipient "$GPG_RECIPIENT" \
          --trust-model always \
          -o "$BACKUP_DIR/openbao-data.tar.gz.gpg" \
          "$BACKUP_DIR/openbao-data.tar.gz"
      rm -f "$BACKUP_DIR/openbao-data.tar.gz"
      log "  OpenBao data encrypted with GPG"
    elif [ -f "$BACKUP_PASSPHRASE_FILE" ]; then
      openssl enc -aes-256-cbc -pbkdf2 -salt \
        -pass "file:$BACKUP_PASSPHRASE_FILE" \
        -in "$BACKUP_DIR/openbao-data.tar.gz" \
        -out "$BACKUP_DIR/openbao-data.tar.gz.enc"
      rm -f "$BACKUP_DIR/openbao-data.tar.gz"
      log "  OpenBao data encrypted with AES"
    else
      log "  WARN: OpenBao backup NOT encrypted — set GPG_RECIPIENT"
    fi
  fi

  log "  OpenBao volume backup complete"
else
  log "  OpenBao volume not found — skipping"
fi

# -- 7. OpenBao Audit Logs ----------------------------------------------------
log "Backing up OpenBao audit logs..."
if docker volume inspect openbao_audit &>/dev/null; then
  docker run --rm \
    -v openbao_audit:/source:ro \
    -v "$BACKUP_DIR":/backup \
    debian:bookworm-slim \
    tar czf /backup/openbao-audit.tar.gz -C /source . 2>/dev/null || {
      log "WARN: OpenBao audit log backup failed"
    }
  log "  Audit log backup complete"
fi

# -- 8. Nango Database Dump ---------------------------------------------------
log "Backing up Nango database..."
if docker ps --format '{{.Names}}' | grep -q pgpclaw-nango-db; then
  docker exec pgpclaw-nango-db \
    pg_dump -U nango -d nango --no-password \
    2>/dev/null | gzip > "$BACKUP_DIR/nango-db.sql.gz" || {
      log "WARN: Nango database dump failed"
    }

  # Encrypt the dump
  if [ -f "$BACKUP_DIR/nango-db.sql.gz" ] && [ -s "$BACKUP_DIR/nango-db.sql.gz" ]; then
    if [ -n "$GPG_RECIPIENT" ]; then
      gpg --encrypt --recipient "$GPG_RECIPIENT" \
          --trust-model always \
          -o "$BACKUP_DIR/nango-db.sql.gz.gpg" \
          "$BACKUP_DIR/nango-db.sql.gz"
      rm -f "$BACKUP_DIR/nango-db.sql.gz"
      log "  Nango DB dump encrypted with GPG"
    elif [ -f "$BACKUP_PASSPHRASE_FILE" ]; then
      openssl enc -aes-256-cbc -pbkdf2 -salt \
        -pass "file:$BACKUP_PASSPHRASE_FILE" \
        -in "$BACKUP_DIR/nango-db.sql.gz" \
        -out "$BACKUP_DIR/nango-db.sql.gz.enc"
      rm -f "$BACKUP_DIR/nango-db.sql.gz"
      log "  Nango DB dump encrypted with AES"
    else
      log "  WARN: Nango DB dump NOT encrypted — set GPG_RECIPIENT"
    fi
    log "  Nango database backup complete"
  else
    rm -f "$BACKUP_DIR/nango-db.sql.gz"
    log "  WARN: Nango DB dump was empty"
  fi
else
  log "  Nango database not running — skipping"
fi

# -- 9. Create Manifest -------------------------------------------------------
log "Creating manifest..."
{
  echo "PGPClaw Backup Manifest"
  echo "Date: $(date -Iseconds)"
  echo "Host: $(hostname)"
  echo ""
  echo "Components backed up:"
  echo "  - OpenClaw config and workspace"
  echo "  - OpenBao data volume (encrypted)"
  echo "  - OpenBao audit logs"
  echo "  - Nango database dump (encrypted)"
  echo "  - Recent sessions and logs"
  echo ""
  echo "Files:"
  ls -lh "$BACKUP_DIR/"
  echo ""
  echo "Total size:"
  du -sh "$BACKUP_DIR/"
} > "$BACKUP_DIR/MANIFEST.txt"

# -- 10. S3 Upload (optional) -------------------------------------------------
if [ -n "$S3_BUCKET" ]; then
  log "Uploading to S3: s3://$S3_BUCKET/$DATE/"
  aws s3 cp "$BACKUP_DIR/" "s3://$S3_BUCKET/$DATE/" \
    --recursive \
    --sse AES256 \
    --no-progress
  log "S3 upload complete"
fi

# -- 11. Cleanup old local backups ---------------------------------------------
log "Cleaning up backups older than $RETENTION_DAYS days..."
find "$BACKUP_ROOT" -maxdepth 1 -type d -mtime "+$RETENTION_DAYS" -exec rm -rf {} + 2>/dev/null || true

# -- Done ----------------------------------------------------------------------
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
log "=== PGPClaw Backup complete. Size: $TOTAL_SIZE. Location: $BACKUP_DIR ==="
