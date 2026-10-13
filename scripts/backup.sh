#!/usr/bin/env bash
# Backup and restore for the Nexvion platform.
# Nexvion is a static site with no database, so a backup is: the site, every config/IaC file in
# the repository, and (optionally) the Docker volumes of the monitoring/logging stack.
#
# Usage:
#   backup.sh [--dest DIR] [--keep-days N] [--volumes] [--s3 s3://bucket/prefix]
#   backup.sh --restore FILE.tar.gz [--restore-dir DIR]
#   backup.sh --list
#
# Never put .env files, Terraform state or private keys into a backup: they are excluded.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
LOG_FILE="${LOG_FILE:-$REPO_ROOT/logs/backup.log}"

DEST="$REPO_ROOT/backups"; KEEP_DAYS=14; VOLUMES=0; S3=""; RESTORE=""; RESTORE_DIR=""; LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="${2:?}"; shift 2 ;;
    --keep-days) KEEP_DAYS="${2:?}"; shift 2 ;;
    --volumes) VOLUMES=1; shift ;;
    --s3) S3="${2:?}"; shift 2 ;;
    --restore) RESTORE="${2:?}"; shift 2 ;;
    --restore-dir) RESTORE_DIR="${2:?}"; shift 2 ;;
    --list) LIST=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
mkdir -p "$DEST"

if [ "$LIST" = 1 ]; then ls -lh "$DEST"/nexvion-*.tar.gz 2>/dev/null || echo "No backups in $DEST"; exit 0; fi

# ---------- restore ----------
if [ -n "$RESTORE" ]; then
  [ -f "$RESTORE" ] || die "Backup file not found: $RESTORE"
  if [ -f "$RESTORE.sha256" ]; then
    ( cd "$(dirname "$RESTORE")" && sha256sum -c "$(basename "$RESTORE").sha256" ) || die "Checksum mismatch - backup is damaged"
  else log_warn "No checksum file next to the backup; skipping verification"; fi
  RESTORE_DIR="${RESTORE_DIR:-$REPO_ROOT/restore-$(date +%Y%m%d-%H%M%S)}"
  mkdir -p "$RESTORE_DIR"
  tar -xzf "$RESTORE" -C "$RESTORE_DIR"
  log_ok "Restored into $RESTORE_DIR (nothing was overwritten). Review, then copy what you need."
  [ -f "$RESTORE_DIR/MANIFEST.txt" ] && cat "$RESTORE_DIR/MANIFEST.txt"
  exit 0
fi

# ---------- backup ----------
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$DEST/nexvion-$STAMP.tar.gz"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT

{
  echo "Nexvion backup"
  echo "created    : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host       : $(hostname)"
  echo "git commit : $(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo n/a)"
  echo "git branch : $(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo n/a)"
  if have_cmd docker; then echo "images     : $(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep nexvion | tr '\n' ' ')"; fi
} > "$STAGE/MANIFEST.txt"

log_info "Archiving site and configuration ..."
tar -czf "$ARCHIVE" \
  --exclude='.git' --exclude='backups' --exclude='restore-*' --exclude='reports' --exclude='logs' \
  --exclude='.env' --exclude='*.tfstate*' --exclude='.terraform' --exclude='*.pem' --exclude='*.key' \
  --exclude='node_modules' --exclude='__pycache__' \
  -C "$REPO_ROOT" application docker kubernetes helm monitoring logging security ai ansible terraform jenkins scripts docs README.md \
  -C "$STAGE" MANIFEST.txt 2>/dev/null || die "tar failed"

if [ "$VOLUMES" = 1 ]; then
  require_cmd docker
  for v in nexvion_prometheus-data nexvion_grafana-data nexvion_es-data; do
    if docker volume inspect "$v" >/dev/null 2>&1; then
      log_info "Backing up volume $v ..."
      docker run --rm -v "$v":/data:ro -v "$DEST":/backup alpine:3.20 \
        tar -czf "/backup/volume-$v-$STAMP.tar.gz" -C /data . && log_ok "volume-$v-$STAMP.tar.gz"
    else log_warn "Volume $v does not exist, skipping"; fi
  done
fi

( cd "$DEST" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" )
log_ok "Backup created: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

if [ -n "$S3" ]; then
  require_cmd aws
  aws s3 cp "$ARCHIVE" "$S3/" --only-show-errors && aws s3 cp "$ARCHIVE.sha256" "$S3/" --only-show-errors \
    && log_ok "Uploaded to $S3/" || log_error "S3 upload failed"
fi

# Retention
old="$(find "$DEST" -maxdepth 1 -type f \( -name 'nexvion-*.tar.gz*' -o -name 'volume-*.tar.gz' \) -mtime +"$KEEP_DAYS" 2>/dev/null || true)"
if [ -n "$old" ]; then echo "$old" | xargs rm -f; log_info "Removed backups older than $KEEP_DAYS days"; fi
