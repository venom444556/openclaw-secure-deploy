#!/usr/bin/env bash
# =============================================================
# PGPClaw — Stack Update Script
# Checks for updates, applies them safely with rollback support.
# Compatible with macOS bash 3.2+ (no associative arrays).
#
# Usage:
#   ./update-stack.sh                     # Check for updates (no changes)
#   ./update-stack.sh --apply             # Apply all available updates
#   ./update-stack.sh --service openclaw  # Update only OpenClaw gateway
#   ./update-stack.sh --service grafana   # Update only Grafana
#   ./update-stack.sh --rollback          # Rollback to previous versions
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$REPO_DIR/docker/docker-compose.yml"
GATEWAY_DOCKERFILE="$REPO_DIR/docker/openclaw-gateway/Dockerfile"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
LOG_DIR="$OPENCLAW_HOME/logs"
LOG_FILE="$LOG_DIR/updates.log"
BACKUP_DIR="$OPENCLAW_HOME/backups"
DATE=$(date +%Y-%m-%d_%H-%M)

# -- Parse args ----------------------------------------------------------------
MODE="check"          # check | apply | rollback
TARGET_SERVICE=""     # empty = all services
SKIP_BACKUP=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)        MODE="apply" ;;
    --rollback)     MODE="rollback" ;;
    --service)      shift; TARGET_SERVICE="${1:-}" ;;
    --skip-backup)  SKIP_BACKUP=true ;;
    --force)        FORCE=true ;;
    -h|--help)      MODE="help" ;;
    *)              echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# -- Colors & Helpers ----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✅ $*${NC}"; }
warn() { echo -e "  ${YELLOW}⚠️  $*${NC}"; }
err()  { echo -e "  ${RED}❌ $*${NC}" >&2; }
info() { echo -e "  ${DIM}$*${NC}"; }
step() { echo -e "\n${BLUE}${BOLD}── $* ──${NC}"; }
log()  { mkdir -p "$LOG_DIR"; echo "[$(date -Iseconds)] $*" >> "$LOG_FILE"; }

banner() {
cat << 'BANNER'
  ____   ____ ____   ____ _
 |  _ \ / ___|  _ \ / ___| | __ ___      __
 | |_) | |  _| |_) | |   | |/ _` \ \ /\ / /
 |  __/| |_| |  __/| |___| | (_| |\ V  V /
 |_|    \____|_|    \____|_|\__,_| \_/\_/
       Stack Update Manager

BANNER
  echo "  Mode:     $MODE"
  [[ -n "$TARGET_SERVICE" ]] && echo "  Target:   $TARGET_SERVICE"
  echo "  Compose:  $COMPOSE_FILE"
  echo ""
}

show_help() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  (no flags)          Check for available updates (read-only)"
  echo "  --apply             Apply available updates"
  echo "  --service NAME      Target a specific service (see list below)"
  echo "  --rollback          Restore previous versions from snapshot"
  echo "  --skip-backup       Skip pre-update backup (not recommended)"
  echo "  --force             Skip confirmation prompts"
  echo "  -h, --help          Show this help"
  echo ""
  echo "Service names:"
  echo "  openbao, openclaw, prometheus, grafana, alertmanager,"
  echo "  n8n, nango-server, postgres, redis"
  echo ""
  echo "Examples:"
  echo "  $0                          # See what updates are available"
  echo "  $0 --apply                  # Update everything"
  echo "  $0 --apply --service grafana  # Update only Grafana"
  echo "  $0 --rollback               # Restore previous versions"
  exit 0
}

# ══════════════════════════════════════════════════════════════
# SERVICE REGISTRY
# Using indexed arrays for bash 3.2 compatibility
# ══════════════════════════════════════════════════════════════

# Service list (update order: infra first, then gateway, then monitoring, then oauth)
ALL_SERVICES="openbao openclaw prometheus grafana alertmanager n8n nango-server postgres redis"

# Parse current versions from docker-compose.yml and Dockerfile
get_current_version() {
  local service="$1"
  case "$service" in
    openbao)
      grep 'image: openbao/openbao:' "$COMPOSE_FILE" | head -1 | sed 's/.*openbao://' | tr -d '[:space:]' ;;
    openclaw)
      grep 'ARG OPENCLAW_VERSION=' "$GATEWAY_DOCKERFILE" | head -1 | sed 's/.*OPENCLAW_VERSION=//' | tr -d '[:space:]' ;;
    prometheus)
      grep 'image: prom/prometheus:' "$COMPOSE_FILE" | head -1 | sed 's/.*prometheus://' | tr -d '[:space:]' ;;
    grafana)
      grep 'image: grafana/grafana:' "$COMPOSE_FILE" | head -1 | sed 's/.*grafana://' | tr -d '[:space:]' ;;
    alertmanager)
      grep 'image: prom/alertmanager:' "$COMPOSE_FILE" | head -1 | sed 's/.*alertmanager://' | tr -d '[:space:]' ;;
    n8n)
      grep 'image: n8nio/n8n:' "$COMPOSE_FILE" | head -1 | sed 's/.*n8n://' | tr -d '[:space:]' ;;
    nango-server)
      grep 'image: nangohq/nango-server:' "$COMPOSE_FILE" | head -1 | sed 's/.*nango-server://' | tr -d '[:space:]' ;;
    postgres)
      grep 'image: postgres:' "$COMPOSE_FILE" | head -1 | sed 's/.*postgres://' | tr -d '[:space:]' ;;
    redis)
      grep 'image: redis:' "$COMPOSE_FILE" | head -1 | sed 's/.*redis://' | tr -d '[:space:]' ;;
    *)
      echo "unknown" ;;
  esac
}

# Fetch latest stable version from Docker Hub for a given service
# Uses service-specific tag patterns since Docker Hub has no universal "latest stable" API
get_latest_docker_tag() {
  local repo="$1"
  local service="$2"

  local response
  response=$(curl -sf --max-time 10 \
    "https://hub.docker.com/v2/repositories/${repo}/tags/?page_size=100&ordering=last_updated" \
    2>/dev/null || echo "")

  if [[ -z "$response" ]]; then
    echo "fetch-failed"
    return
  fi

  local all_tags
  all_tags=$(echo "$response" | jq -r '.results[]?.name // empty' 2>/dev/null)

  if [[ -z "$all_tags" ]]; then
    echo "fetch-failed"
    return
  fi

  # Service-specific tag patterns to match only stable releases
  case "$service" in
    openbao)
      # Tags like: 2.5.0, 2.4.1 (semver, no prefix)
      echo "$all_tags" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1nr -k2,2nr -k3,3nr | head -1
      ;;
    prometheus|alertmanager)
      # Tags like: v3.5.1, v0.27.0 (v-prefixed semver)
      # Strip v prefix, sort numerically, then re-add v prefix
      echo "$all_tags" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        | sed 's/^v//' \
        | sort -t. -k1,1nr -k2,2nr -k3,3nr \
        | head -1 \
        | sed 's/^/v/'
      ;;
    grafana)
      # Tags like: 11.5.2, 11.4.0 (semver, no prefix)
      echo "$all_tags" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1nr -k2,2nr -k3,3nr | head -1
      ;;
    n8n)
      # Tags like: 2.8.2, 1.75.0 (semver, no prefix)
      echo "$all_tags" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1nr -k2,2nr -k3,3nr | head -1
      ;;
    nango-server)
      # Tags like: hosted-0.69.30 (hosted- prefix with semver)
      echo "$all_tags" | grep -E '^hosted-[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1Vr | head -1
      ;;
    postgres)
      # Tags like: 16.0-alpine, 16.8-alpine (match current suffix pattern)
      local current_suffix
      current_suffix=$(get_current_version "postgres" | sed 's/^[0-9.]*//')  # e.g. "-alpine"
      local current_major
      current_major=$(get_current_version "postgres" | cut -d. -f1)  # e.g. "16"
      echo "$all_tags" | grep -E "^${current_major}\.[0-9]+${current_suffix}$" | sort -t. -k2,2nr | head -1
      ;;
    redis)
      # Tags like: 7.2.4, 7.4.3 (semver, matching major version)
      local current_major
      current_major=$(get_current_version "redis" | cut -d. -f1)  # e.g. "7"
      echo "$all_tags" | grep -E "^${current_major}\.[0-9]+\.[0-9]+$" | sort -t. -k2,2nr -k3,3nr | head -1
      ;;
    *)
      # Generic: match X.Y.Z pattern
      echo "$all_tags" | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | head -1
      ;;
  esac
}

# Fetch latest OpenClaw version from npm
get_latest_npm_version() {
  local pkg="$1"
  npm view "$pkg" version 2>/dev/null || echo "fetch-failed"
}

# Get Docker Hub repo name for a service
get_docker_repo() {
  local service="$1"
  case "$service" in
    openbao)       echo "openbao/openbao" ;;
    prometheus)    echo "prom/prometheus" ;;
    grafana)       echo "grafana/grafana" ;;
    alertmanager)  echo "prom/alertmanager" ;;
    n8n)           echo "n8nio/n8n" ;;
    nango-server)  echo "nangohq/nango-server" ;;
    postgres)      echo "library/postgres" ;;
    redis)         echo "library/redis" ;;
    *)             echo "" ;;
  esac
}

# Get compose service name
get_compose_service() {
  local service="$1"
  case "$service" in
    openbao)       echo "openbao" ;;
    openclaw)      echo "openclaw" ;;
    prometheus)    echo "prometheus" ;;
    grafana)       echo "grafana" ;;
    alertmanager)  echo "alertmanager" ;;
    n8n)           echo "n8n" ;;
    nango-server)  echo "nango-server" ;;
    postgres)      echo "nango-db" ;;
    redis)         echo "nango-redis" ;;
    *)             echo "" ;;
  esac
}

# Get health check URL for a service
get_health_url() {
  local service="$1"
  case "$service" in
    openbao)       echo "http://127.0.0.1:8200/v1/sys/health" ;;
    openclaw)      echo "http://127.0.0.1:18789/health" ;;
    prometheus)    echo "http://127.0.0.1:9090/-/healthy" ;;
    grafana)       echo "http://127.0.0.1:3000/api/health" ;;
    alertmanager)  echo "http://127.0.0.1:9093/-/healthy" ;;
    n8n)           echo "http://127.0.0.1:5678/healthz" ;;
    nango-server)  echo "http://127.0.0.1:3003/health" ;;
    postgres)      echo "" ;;
    redis)         echo "" ;;
    *)             echo "" ;;
  esac
}

# Get the profile a service belongs to
get_service_profile() {
  local service="$1"
  case "$service" in
    openbao|openclaw)                        echo "core" ;;
    prometheus|grafana|alertmanager|n8n)      echo "monitoring" ;;
    nango-server|postgres|redis)             echo "oauth" ;;
    *)                                        echo "full" ;;
  esac
}

# Get image pattern for sed replacement
get_image_pattern() {
  local service="$1"
  case "$service" in
    openbao)       echo "openbao/openbao:" ;;
    prometheus)    echo "prom/prometheus:" ;;
    grafana)       echo "grafana/grafana:" ;;
    alertmanager)  echo "prom/alertmanager:" ;;
    n8n)           echo "n8nio/n8n:" ;;
    nango-server)  echo "nangohq/nango-server:" ;;
    postgres)      echo "postgres:" ;;
    redis)         echo "redis:" ;;
    *)             echo "" ;;
  esac
}

# ══════════════════════════════════════════════════════════════
# PREFLIGHT
# ══════════════════════════════════════════════════════════════
preflight() {
  step "Pre-flight checks"

  local fail=false

  if ! command -v docker &>/dev/null; then
    err "Docker not found"; fail=true
  fi
  if ! command -v curl &>/dev/null; then
    err "curl not found"; fail=true
  fi
  if ! command -v jq &>/dev/null; then
    err "jq not found"; fail=true
  fi
  if ! command -v npm &>/dev/null; then
    warn "npm not found — OpenClaw version check will be skipped"
  fi
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    err "docker-compose.yml not found at: $COMPOSE_FILE"; fail=true
  fi
  if [[ ! -f "$GATEWAY_DOCKERFILE" ]]; then
    warn "Gateway Dockerfile not found — OpenClaw updates will be skipped"
  fi

  # Validate target service if specified
  if [[ -n "$TARGET_SERVICE" ]]; then
    local valid=false
    for svc in $ALL_SERVICES; do
      if [[ "$svc" == "$TARGET_SERVICE" ]]; then
        valid=true
        break
      fi
    done
    if [[ "$valid" == "false" ]]; then
      err "Unknown service: $TARGET_SERVICE"
      echo "  Valid services: $ALL_SERVICES"
      exit 1
    fi
  fi

  if [[ "$fail" == "true" ]]; then
    exit 1
  fi

  ok "Pre-flight checks passed"
}

# ══════════════════════════════════════════════════════════════
# VERSION CHECK
# Store results in temp files for bash 3.2 compatibility
# ══════════════════════════════════════════════════════════════

TMPDIR_UPDATE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_UPDATE"' EXIT

UPDATE_COUNT=0

check_versions() {
  step "Checking versions"

  local services_to_check="$ALL_SERVICES"
  if [[ -n "$TARGET_SERVICE" ]]; then
    services_to_check="$TARGET_SERVICE"
  fi

  for service in $services_to_check; do
    local current latest

    # Get current version
    current=$(get_current_version "$service")
    echo "$current" > "$TMPDIR_UPDATE/${service}.current"

    if [[ -z "$current" || "$current" == "unknown" ]]; then
      warn "$service: could not determine current version"
      echo "unknown" > "$TMPDIR_UPDATE/${service}.latest"
      echo "false" > "$TMPDIR_UPDATE/${service}.update"
      continue
    fi

    # Get latest version
    if [[ "$service" == "openclaw" ]]; then
      if command -v npm &>/dev/null; then
        latest=$(get_latest_npm_version "openclaw")
      else
        latest="fetch-failed"
      fi
    else
      local repo
      repo=$(get_docker_repo "$service")
      latest=$(get_latest_docker_tag "$repo" "$service")
    fi

    echo "$latest" > "$TMPDIR_UPDATE/${service}.latest"

    # Compare
    if [[ "$latest" == "fetch-failed" || -z "$latest" ]]; then
      echo "unknown" > "$TMPDIR_UPDATE/${service}.update"
      info "$service: could not fetch latest version"
    elif [[ "$current" == "$latest" ]]; then
      echo "false" > "$TMPDIR_UPDATE/${service}.update"
    else
      echo "true" > "$TMPDIR_UPDATE/${service}.update"
      UPDATE_COUNT=$((UPDATE_COUNT + 1))
    fi
  done
}

print_version_table() {
  step "Version Report"

  printf "\n  %-16s %-24s %-24s %s\n" "SERVICE" "CURRENT" "LATEST" "STATUS"
  printf "  %-16s %-24s %-24s %s\n" "───────────────" "───────────────────────" "───────────────────────" "──────────"

  local services_to_show="$ALL_SERVICES"
  if [[ -n "$TARGET_SERVICE" ]]; then
    services_to_show="$TARGET_SERVICE"
  fi

  for service in $services_to_show; do
    local current="unknown"
    local latest="unknown"
    local status="unknown"

    [[ -f "$TMPDIR_UPDATE/${service}.current" ]] && current=$(cat "$TMPDIR_UPDATE/${service}.current")
    [[ -f "$TMPDIR_UPDATE/${service}.latest" ]]  && latest=$(cat "$TMPDIR_UPDATE/${service}.latest")
    [[ -f "$TMPDIR_UPDATE/${service}.update" ]]  && status=$(cat "$TMPDIR_UPDATE/${service}.update")

    local status_text
    case "$status" in
      true)    status_text="${GREEN}UPDATE AVAILABLE${NC}" ;;
      false)   status_text="${DIM}up to date${NC}" ;;
      unknown) status_text="${YELLOW}check failed${NC}" ;;
    esac

    printf "  %-16s %-24s %-24s " "$service" "$current" "$latest"
    echo -e "$status_text"
  done

  echo ""
  if [[ $UPDATE_COUNT -gt 0 ]]; then
    echo -e "  ${BOLD}${UPDATE_COUNT} update(s) available.${NC}"
    if [[ "$MODE" == "check" ]]; then
      echo -e "  Run with ${BOLD}--apply${NC} to install updates."
    fi
  else
    echo -e "  ${GREEN}All services are up to date.${NC}"
  fi
  echo ""
}

# ══════════════════════════════════════════════════════════════
# VERSION SNAPSHOT (for rollback)
# ══════════════════════════════════════════════════════════════

save_version_snapshot() {
  mkdir -p "$BACKUP_DIR"
  local snapshot_file="$BACKUP_DIR/versions-${DATE}.json"

  # Build JSON manually for bash 3.2 compatibility
  {
    echo "{"
    echo "  \"date\": \"$(date -Iseconds)\","
    echo "  \"versions\": {"
    local first=true
    for service in $ALL_SERVICES; do
      local ver
      ver=$(get_current_version "$service")
      if [[ "$first" == "true" ]]; then
        first=false
      else
        echo ","
      fi
      printf "    \"%s\": \"%s\"" "$service" "$ver"
    done
    echo ""
    echo "  }"
    echo "}"
  } > "$snapshot_file"

  ok "Version snapshot saved: $snapshot_file"
  log "Version snapshot saved: $snapshot_file"
}

get_latest_snapshot() {
  ls -t "$BACKUP_DIR"/versions-*.json 2>/dev/null | head -1
}

# ══════════════════════════════════════════════════════════════
# UPDATE LOGIC
# ══════════════════════════════════════════════════════════════

wait_for_health() {
  local service="$1"
  local url
  url=$(get_health_url "$service")

  if [[ -z "$url" ]]; then
    # No health URL (internal services like postgres, redis)
    # Check docker health status instead
    local compose_svc container_name
    compose_svc=$(get_compose_service "$service")
    container_name="pgpclaw-${compose_svc}"

    info "Waiting for $service container health..."
    local i
    for i in $(seq 1 30); do
      local health
      health=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "unknown")
      if [[ "$health" == "healthy" ]]; then
        return 0
      fi
      sleep 2
    done
    return 1
  fi

  info "Waiting for $service health check ($url)..."
  local i
  for i in $(seq 1 30); do
    if curl -sf --max-time 5 "$url" -o /dev/null 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

update_docker_service() {
  local service="$1"
  local old_version="$2"
  local new_version="$3"
  local image_pattern compose_svc profile

  image_pattern=$(get_image_pattern "$service")
  compose_svc=$(get_compose_service "$service")
  profile=$(get_service_profile "$service")

  echo -e "  ${BOLD}Updating $service: $old_version → $new_version${NC}"
  log "Updating $service: $old_version → $new_version"

  # Step 1: Update version in docker-compose.yml
  # macOS sed requires '' after -i
  sed -i '' "s|${image_pattern}${old_version}|${image_pattern}${new_version}|" "$COMPOSE_FILE"

  # Step 2: Pull new image
  local full_image
  case "$service" in
    postgres) full_image="postgres:${new_version}" ;;
    redis)    full_image="redis:${new_version}" ;;
    *)
      local repo
      repo=$(get_docker_repo "$service")
      full_image="${repo}:${new_version}"
      ;;
  esac

  info "Pulling $full_image..."
  if ! docker pull "$full_image" 2>/dev/null; then
    err "Failed to pull $full_image — rolling back"
    sed -i '' "s|${image_pattern}${new_version}|${image_pattern}${old_version}|" "$COMPOSE_FILE"
    return 1
  fi

  # Step 3: Recreate the service
  info "Recreating $compose_svc..."
  docker compose -f "$COMPOSE_FILE" --profile "$profile" up -d "$compose_svc" 2>/dev/null

  # Step 4: Health check
  if wait_for_health "$service"; then
    ok "$service updated to $new_version"
    log "$service updated successfully to $new_version"
    return 0
  else
    err "$service failed health check after update — rolling back"
    log "$service FAILED health check after update to $new_version"

    # Rollback
    sed -i '' "s|${image_pattern}${new_version}|${image_pattern}${old_version}|" "$COMPOSE_FILE"
    docker compose -f "$COMPOSE_FILE" --profile "$profile" up -d "$compose_svc" 2>/dev/null
    wait_for_health "$service" || true
    warn "$service rolled back to $old_version"
    log "$service rolled back to $old_version"
    return 1
  fi
}

update_openclaw() {
  local old_version="$1"
  local new_version="$2"

  echo -e "  ${BOLD}Updating OpenClaw: $old_version → $new_version${NC}"
  log "Updating OpenClaw: $old_version → $new_version"

  # Step 1: Update version in Dockerfile
  sed -i '' "s|ARG OPENCLAW_VERSION=${old_version}|ARG OPENCLAW_VERSION=${new_version}|" "$GATEWAY_DOCKERFILE"

  # Step 2: Rebuild image
  info "Rebuilding pgpclaw/openclaw-gateway:local..."
  if ! docker compose -f "$COMPOSE_FILE" --profile build build gateway-build 2>/dev/null; then
    err "Failed to build new gateway image — rolling back"
    sed -i '' "s|ARG OPENCLAW_VERSION=${new_version}|ARG OPENCLAW_VERSION=${old_version}|" "$GATEWAY_DOCKERFILE"
    return 1
  fi

  # Step 3: Recreate the gateway container
  info "Recreating gateway..."
  docker compose -f "$COMPOSE_FILE" --profile core up -d openclaw 2>/dev/null

  # Step 4: Health check
  if wait_for_health "openclaw"; then
    ok "OpenClaw updated to $new_version"
    log "OpenClaw updated successfully to $new_version"
    return 0
  else
    err "OpenClaw failed health check after update — rolling back"
    log "OpenClaw FAILED health check after update to $new_version"

    # Rollback: rebuild old version
    sed -i '' "s|ARG OPENCLAW_VERSION=${new_version}|ARG OPENCLAW_VERSION=${old_version}|" "$GATEWAY_DOCKERFILE"
    docker compose -f "$COMPOSE_FILE" --profile build build gateway-build 2>/dev/null
    docker compose -f "$COMPOSE_FILE" --profile core up -d openclaw 2>/dev/null
    wait_for_health "openclaw" || true
    warn "OpenClaw rolled back to $old_version"
    log "OpenClaw rolled back to $old_version"
    return 1
  fi
}

# ══════════════════════════════════════════════════════════════
# APPLY UPDATES
# ══════════════════════════════════════════════════════════════

apply_updates() {
  if [[ $UPDATE_COUNT -eq 0 ]]; then
    echo -e "  ${GREEN}Nothing to update — all services are current.${NC}"
    return
  fi

  # Confirmation
  if [[ "$FORCE" != "true" ]]; then
    echo -e "  ${YELLOW}This will update $UPDATE_COUNT service(s).${NC}"
    echo -n "  Proceed? [y/N]: "
    read -r CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" && "$CONFIRM" != "yes" ]]; then
      echo "  Aborted."
      exit 0
    fi
  fi

  # Pre-update backup
  if [[ "$SKIP_BACKUP" != "true" ]]; then
    step "Pre-update backup"
    if [[ -x "$REPO_DIR/scripts/backup.sh" ]]; then
      info "Running backup.sh..."
      "$REPO_DIR/scripts/backup.sh" 2>&1 | while IFS= read -r line; do echo "    $line"; done
      ok "Backup completed"
    else
      warn "backup.sh not found — skipping pre-update backup"
    fi
  fi

  # Save version snapshot
  step "Saving version snapshot"
  save_version_snapshot

  # Apply updates
  step "Applying updates"
  local success=0
  local failed=0

  local services_to_update="$ALL_SERVICES"
  if [[ -n "$TARGET_SERVICE" ]]; then
    services_to_update="$TARGET_SERVICE"
  fi

  for service in $services_to_update; do
    local update_status="false"
    [[ -f "$TMPDIR_UPDATE/${service}.update" ]] && update_status=$(cat "$TMPDIR_UPDATE/${service}.update")

    if [[ "$update_status" != "true" ]]; then
      continue
    fi

    local old new
    old=$(cat "$TMPDIR_UPDATE/${service}.current")
    new=$(cat "$TMPDIR_UPDATE/${service}.latest")

    if [[ "$service" == "openclaw" ]]; then
      if update_openclaw "$old" "$new"; then
        success=$((success + 1))
      else
        failed=$((failed + 1))
      fi
    else
      if update_docker_service "$service" "$old" "$new"; then
        success=$((success + 1))
      else
        failed=$((failed + 1))
      fi
    fi
  done

  # Summary
  step "Update Summary"
  ok "$success service(s) updated successfully"
  if [[ $failed -gt 0 ]]; then
    err "$failed service(s) failed (rolled back)"
  fi
  log "Update complete: $success succeeded, $failed failed"
}

# ══════════════════════════════════════════════════════════════
# ROLLBACK
# ══════════════════════════════════════════════════════════════

do_rollback() {
  step "Rolling back to previous versions"

  local snapshot
  snapshot=$(get_latest_snapshot)

  if [[ -z "$snapshot" || ! -f "${snapshot:-/nonexistent}" ]]; then
    err "No version snapshot found in $BACKUP_DIR"
    echo "  Cannot rollback without a previous version snapshot."
    echo "  Snapshots are created automatically when running --apply."
    exit 1
  fi

  echo "  Snapshot: $snapshot"
  echo ""

  # Read versions from snapshot
  local snap_date
  snap_date=$(jq -r '.date' "$snapshot")
  echo "  Snapshot date: $snap_date"
  echo ""

  printf "  %-16s %-24s %-24s\n" "SERVICE" "CURRENT" "ROLLBACK TO"
  printf "  %-16s %-24s %-24s\n" "───────────────" "───────────────────────" "───────────────────────"

  local rollback_needed=false
  for service in $ALL_SERVICES; do
    local current snap_ver
    current=$(get_current_version "$service")
    snap_ver=$(jq -r ".versions.\"$service\" // \"unknown\"" "$snapshot")

    if [[ "$current" != "$snap_ver" && "$snap_ver" != "unknown" ]]; then
      printf "  %-16s %-24s %-24s\n" "$service" "$current" "$snap_ver"
      rollback_needed=true
    fi
  done

  if [[ "$rollback_needed" == "false" ]]; then
    echo ""
    echo -e "  ${GREEN}All versions already match the snapshot. Nothing to rollback.${NC}"
    return
  fi

  echo ""
  if [[ "$FORCE" != "true" ]]; then
    echo -n "  Rollback to these versions? [y/N]: "
    read -r CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" && "$CONFIRM" != "yes" ]]; then
      echo "  Aborted."
      exit 0
    fi
  fi

  # Apply rollback for each service
  for service in $ALL_SERVICES; do
    local current snap_ver
    current=$(get_current_version "$service")
    snap_ver=$(jq -r ".versions.\"$service\" // \"unknown\"" "$snapshot")

    if [[ "$current" == "$snap_ver" || "$snap_ver" == "unknown" ]]; then
      continue
    fi

    if [[ "$service" == "openclaw" ]]; then
      # Rollback OpenClaw: update Dockerfile ARG and rebuild
      sed -i '' "s|ARG OPENCLAW_VERSION=${current}|ARG OPENCLAW_VERSION=${snap_ver}|" "$GATEWAY_DOCKERFILE"
      info "Rebuilding gateway with openclaw@${snap_ver}..."
      docker compose -f "$COMPOSE_FILE" --profile build build gateway-build 2>/dev/null
      docker compose -f "$COMPOSE_FILE" --profile core up -d openclaw 2>/dev/null
    else
      # Rollback Docker service: update image tag and recreate
      local image_pattern compose_svc profile
      image_pattern=$(get_image_pattern "$service")
      compose_svc=$(get_compose_service "$service")
      profile=$(get_service_profile "$service")

      sed -i '' "s|${image_pattern}${current}|${image_pattern}${snap_ver}|" "$COMPOSE_FILE"
      docker compose -f "$COMPOSE_FILE" --profile "$profile" up -d "$compose_svc" 2>/dev/null
    fi

    if wait_for_health "$service"; then
      ok "$service rolled back to $snap_ver"
    else
      warn "$service rolled back but health check is uncertain"
    fi
  done

  log "Rollback completed from snapshot: $snapshot"
  echo ""
  ok "Rollback complete"
}

# ══════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════

if [[ "$MODE" == "help" ]]; then
  show_help
fi

banner
preflight
check_versions
print_version_table

case "$MODE" in
  check)
    # Already printed the table above — done
    ;;
  apply)
    apply_updates
    ;;
  rollback)
    do_rollback
    ;;
esac
