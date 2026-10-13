#!/usr/bin/env bash
# Container image scan. Fails (exit 1) when HIGH or CRITICAL vulnerabilities are present.
# Usage: security/scan-image.sh <image:tag> [--sbom]
set -euo pipefail
source "$(dirname "$0")/../scripts/lib/common.sh"
cd "$REPO_ROOT"; mkdir -p reports
IMAGE="${1:?usage: scan-image.sh <image:tag> [--sbom]}"
require_cmd trivy

# Lint the Dockerfile too when hadolint is available.
if have_cmd hadolint; then hadolint docker/Dockerfile && log_ok "Dockerfile lint passed" || log_warn "hadolint reported issues"; fi

log_info "Scanning $IMAGE"
trivy image --severity "${SEVERITY:-HIGH,CRITICAL}" --ignore-unfixed --exit-code 1 \
  --ignorefile security/.trivyignore "$IMAGE" | tee reports/trivy-image.txt
log_ok "Image scan passed (no fixable HIGH/CRITICAL vulnerabilities)"

if [ "${2:-}" = "--sbom" ]; then
  trivy image --format cyclonedx --output reports/sbom.cdx.json "$IMAGE" >/dev/null && log_ok "SBOM written to reports/sbom.cdx.json"
fi
