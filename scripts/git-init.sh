#!/usr/bin/env bash
# Prepare the Git workflow: main + develop branches, and a pre-commit hook that scans for secrets.
# Usage: ./scripts/git-init.sh [remote-url]
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
cd "$REPO_ROOT"
require_cmd git

[ -d .git ] || git init -b main
git rev-parse --verify HEAD >/dev/null 2>&1 || { git add -A && git commit -m "chore: initial import of Nexvion DevOps platform"; }
git branch -M main
git show-ref --verify --quiet refs/heads/develop || git branch develop
if [ -n "${1:-}" ]; then
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "$1"
fi

hook=.git/hooks/pre-commit
cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
# Block commits that contain secrets (needs gitleaks; skips with a warning if it is not installed).
if command -v gitleaks >/dev/null 2>&1; then
  gitleaks protect --staged --config security/gitleaks.toml --redact -v || { echo "Commit blocked: possible secret found"; exit 1; }
else
  echo "warning: gitleaks not installed, secret scan skipped" >&2
fi
HOOK
chmod +x "$hook"
log_ok "Branches: $(git branch --format='%(refname:short)' | tr '\n' ' ')"
log_info "Work flow: git switch develop && git switch -c feature/<name> ... open a Pull Request into develop; release by merging develop into main."
