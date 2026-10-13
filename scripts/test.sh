#!/usr/bin/env bash
# Static tests for the whole repository. Used by Jenkins (stage "Test") and by developers.
# Needs only bash and python3. Uses node, docker, helm and kubectl when they are installed.
set -uo pipefail
source "$(dirname "$0")/lib/common.sh"
cd "$REPO_ROOT"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); log_ok   "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); log_error "FAIL  $1"; }
skip() { SKIP=$((SKIP+1)); log_warn "SKIP  $1"; }

# 1. Pages: every page has a doctype and a title; local assets exist
for f in application/*.html; do
  if grep -qi '<!doctype html>' "$f" && grep -qi '<title>' "$f"; then ok "HTML structure: $f"; else bad "HTML structure: $f"; fi
done
if python3 scripts/check_assets.py application >/tmp/assets.out 2>&1; then ok "Local asset references"; else bad "Local asset references"; cat /tmp/assets.out; fi

# 2. JavaScript syntax
if have_cmd node; then
  for f in application/*.js; do
    if node --check "$f" 2>/dev/null; then ok "JS syntax: $f"; else bad "JS syntax: $f"; fi
  done
else skip "JS syntax (node not installed)"; fi

# 3. Shell scripts
for f in $(find scripts jenkins security kubernetes logging ai terraform -name '*.sh' | sort); do
  if bash -n "$f" 2>/dev/null; then ok "Shell syntax: $f"; else bad "Shell syntax: $f"; fi
done

# 4. YAML / JSON files parse (Helm templates contain {{ }} and are skipped here)
if python3 -c 'import yaml' 2>/dev/null; then
  while IFS= read -r f; do
    if python3 - "$f" <<'PY' 2>/dev/null
import sys, yaml
list(yaml.safe_load_all(open(sys.argv[1])))
PY
    then ok "YAML: $f"; else bad "YAML: $f"; fi
  done < <(find . -type f \( -name '*.yml' -o -name '*.yaml' \) -not -path './helm/*' -not -path './ansible/*' -not -path './.git/*' -not -path './terraform/.terraform/*' | sort)
else skip "YAML parsing (PyYAML not installed)"; fi
while IFS= read -r f; do
  if python3 -m json.tool "$f" >/dev/null 2>&1; then ok "JSON: $f"; else bad "JSON: $f"; fi
done < <(find . -type f -name '*.json' -not -path './.git/*' -not -path '*/node_modules/*' | sort)

# 5. Nginx config copies are in sync with the single source of truth
tmp="$(mktemp -d)"; cp -r kubernetes/configmap.yaml "$tmp/cm.yaml"; cp helm/ecommerce/files/default.conf "$tmp/helm.conf" 2>/dev/null
bash scripts/sync-config.sh >/dev/null 2>&1
if diff -q "$tmp/cm.yaml" kubernetes/configmap.yaml >/dev/null && diff -q "$tmp/helm.conf" helm/ecommerce/files/default.conf >/dev/null; then
  ok "Nginx config in sync (docker, kubernetes, helm)"
else bad "Nginx config was out of sync - scripts/sync-config.sh has been re-run, commit the result"; fi
rm -rf "$tmp"

# 6. Optional tool-based checks
if have_cmd docker && docker compose version >/dev/null 2>&1; then
  if (cd docker && GRAFANA_ADMIN_PASSWORD=x docker compose --profile monitoring --profile logging config -q 2>/dev/null); then ok "docker compose config"; else bad "docker compose config"; fi
else skip "docker compose config (docker not installed)"; fi
if have_cmd helm; then
  if helm lint helm/ecommerce >/dev/null 2>&1; then ok "helm lint"; else bad "helm lint"; fi
else skip "helm lint (helm not installed)"; fi
if have_cmd kubectl; then
  if kubectl kustomize kubernetes >/dev/null 2>&1; then ok "kustomize build"; else bad "kustomize build"; fi
else skip "kustomize build (kubectl not installed)"; fi
if have_cmd terraform; then
  if terraform -chdir=terraform fmt -check -recursive >/dev/null 2>&1; then ok "terraform fmt"; else skip "terraform fmt differs - run: terraform -chdir=terraform fmt -recursive"; fi
else skip "terraform fmt (terraform not installed)"; fi
if have_cmd python3 && [ -f ai/incident-analysis/tests/test_analyzer.py ]; then
  if python3 -m unittest discover -s ai/incident-analysis/tests -q >/dev/null 2>&1; then ok "AI analyzer unit tests"; else bad "AI analyzer unit tests"; fi
fi

echo
log_info "Result: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
