#!/usr/bin/env bash
# Secret scanning (Gitleaks) over the working tree and the Git history.
# Exit code 1 if a secret is found.  Report: reports/gitleaks.json
set -euo pipefail
source "$(dirname "$0")/../scripts/lib/common.sh"
cd "$REPO_ROOT"; mkdir -p reports

CFG="security/gitleaks.toml"
if have_cmd gitleaks; then
  RUN=(gitleaks)
elif have_cmd docker; then
  RUN=(docker run --rm -v "$REPO_ROOT":/repo -w /repo zricethezav/gitleaks:latest)
else
  die "Install gitleaks (scripts/setup.sh --tools all) or Docker"
fi

log_info "Scanning for secrets ..."
if [ -d .git ]; then
  "${RUN[@]}" detect --source . --config "$CFG" --report-format json --report-path reports/gitleaks.json --redact --no-banner \
    && log_ok "No secrets found (history + working tree)" || { log_error "Secrets found - see reports/gitleaks.json"; exit 1; }
else
  "${RUN[@]}" detect --no-git --source . --config "$CFG" --report-format json --report-path reports/gitleaks.json --redact --no-banner \
    && log_ok "No secrets found (working tree)" || { log_error "Secrets found - see reports/gitleaks.json"; exit 1; }
fi
