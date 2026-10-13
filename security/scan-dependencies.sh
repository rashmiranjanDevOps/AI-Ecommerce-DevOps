#!/usr/bin/env bash
# Dependency and configuration scanning.
# Nexvion has no package manager files (no npm/pip), so "dependencies" means:
#   1. third-party resources the pages load (fonts, images)   -> listed by scripts/check_assets.py
#   2. vulnerable packages / misconfiguration in the repo      -> Trivy filesystem + config scan
#      (Dockerfile, Kubernetes, Helm, Terraform, Compose)
# Reports: reports/external-resources.txt, reports/trivy-fs.txt
set -euo pipefail
source "$(dirname "$0")/../scripts/lib/common.sh"
cd "$REPO_ROOT"; mkdir -p reports

log_info "Third-party resources used by the site"
python3 scripts/check_assets.py application | tee reports/external-resources.txt >/dev/null
sed -n '1,12p' reports/external-resources.txt

require_cmd trivy
log_info "Trivy filesystem scan (vulnerabilities, secrets, misconfigurations)"
SEVERITY="${SEVERITY:-HIGH,CRITICAL}"
# --exit-code 1 makes the pipeline fail on findings of the chosen severity.
trivy fs --config security/trivy.yaml --severity "$SEVERITY" --exit-code 1 \
  --skip-dirs terraform/.terraform --skip-dirs node_modules --skip-dirs reports . | tee reports/trivy-fs.txt
log_ok "Dependency and configuration scan passed"
