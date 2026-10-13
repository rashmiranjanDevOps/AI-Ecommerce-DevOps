#!/usr/bin/env bash
# Safe housekeeping for the Nexvion host.
#
# Usage: cleanup.sh [--dry-run] [--deep] [--volumes] [--days N]
#   (default)  remove stopped containers, dangling images, old build cache,
#              and backups / reports / logs older than N days (default 14); compress yesterday's logs
#   --deep     also remove ALL unused images (not only dangling ones)
#   --volumes  also remove unused Docker volumes (asks for confirmation; this deletes data)
#   --dry-run  only show what would happen
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
LOG_FILE="${LOG_FILE:-$REPO_ROOT/logs/cleanup.log}"

DRY=0; DEEP=0; VOLS=0; DAYS=14
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --deep) DEEP=1; shift ;;
    --volumes) VOLS=1; shift ;;
    --days) DAYS="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

run() { if [ "$DRY" = 1 ]; then log_info "[dry-run] $*"; else "$@"; fi; }

if have_cmd docker && docker info >/dev/null 2>&1; then
  log_info "Docker: stopped containers"
  run docker container prune -f
  log_info "Docker: dangling images"
  run docker image prune -f
  log_info "Docker: build cache older than 24h"
  run docker builder prune -f --filter 'until=24h'
  if [ "$DEEP" = 1 ]; then
    log_info "Docker: all unused images"
    run docker image prune -a -f
  fi
  if [ "$VOLS" = 1 ]; then
    if [ "$DRY" = 1 ]; then log_info "[dry-run] docker volume prune"
    elif confirm "Delete ALL unused Docker volumes (data is lost)?"; then docker volume prune -f
    else log_warn "Skipped volume prune"; fi
  fi
else
  log_warn "Docker not available, skipping Docker cleanup"
fi

prune_old() {   # dir pattern
  local dir="$1" pattern="$2" files
  [ -d "$dir" ] || return 0
  files="$(find "$dir" -maxdepth 1 -type f -name "$pattern" -mtime +"$DAYS" 2>/dev/null || true)"
  [ -n "$files" ] || return 0
  log_info "Removing $(echo "$files" | wc -l) old file(s) from ${dir#$REPO_ROOT/} ($pattern)"
  if [ "$DRY" = 1 ]; then echo "$files" | sed 's/^/    /'; else echo "$files" | xargs rm -f; fi
}
prune_old "$REPO_ROOT/backups" 'nexvion-*.tar.gz*'
prune_old "$REPO_ROOT/backups" 'volume-*.tar.gz'
prune_old "$REPO_ROOT/reports" '*'
prune_old "$REPO_ROOT/logs"    '*.gz'

# Compress yesterday's plain logs
if [ -d "$REPO_ROOT/logs" ]; then
  while IFS= read -r f; do
    [ "$(basename "$f")" = "$(basename "${LOG_FILE}")" ] && continue
    log_info "Compressing $(basename "$f")"
    run gzip -f "$f"
  done < <(find "$REPO_ROOT/logs" -maxdepth 1 -type f -name '*.log' -mtime +0 2>/dev/null)
fi

# Disk summary
df -h / | awk 'NR==2{printf "Disk: %s used of %s (%s)\n",$3,$2,$5}' >&2
log_ok "Cleanup finished"
