#!/usr/bin/env bash
# Shared helpers. Source this file:  source "$(dirname "$0")/lib/common.sh"

# Repository root = parent of the scripts directory.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

if [ -t 2 ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_OFF=""
fi

# If LOG_FILE is set (for example logs/deploy.log) every message is also written there.
_log() {
  local level="$1" colour="$2"; shift 2
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
  printf '%s%s%s\n' "$colour" "$line" "$C_OFF" >&2
  if [ -n "${LOG_FILE:-}" ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s\n' "$line" >> "$LOG_FILE"
  fi
}
log_info()  { _log INFO  "$C_BLUE"   "$@"; }
log_ok()    { _log OK    "$C_GREEN"  "$@"; }
log_warn()  { _log WARN  "$C_YELLOW" "$@"; }
log_error() { _log ERROR "$C_RED"    "$@"; }
die()       { log_error "$@"; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
  done
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Run a command with root rights (directly if already root, else through sudo).
as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

confirm() {
  # confirm "Question?"  -> returns 0 only when the user types y/yes. Non-interactive = no.
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  [ -t 0 ] || return 1
  local reply
  read -r -p "$1 [y/N] " reply
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Load docker/.env (if present) into the environment.
load_env() {
  local f="${1:-$REPO_ROOT/docker/.env}"
  if [ -f "$f" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
  fi
}

compose() {
  # Always run compose from the docker/ directory with its own project settings.
  ( cd "$REPO_ROOT/docker" && docker compose "$@" )
}

short_sha() { git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "nogit"; }
