#!/usr/bin/env bash
# Prepare a Linux server (Ubuntu/Debian, Amazon Linux/RHEL family) for the Nexvion platform.
#
# Usage: sudo ./scripts/setup.sh [--tools minimal|all] [--user NAME] [--skip-sysctl]
#   minimal (default): git, curl, jq, python3, htpasswd, make, Docker Engine + Compose plugin
#   all              : minimal + kubectl, helm, terraform, ansible, AWS CLI v2, trivy, gitleaks
#
# Safe to run more than once: tools that are already installed are skipped.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
LOG_FILE="${LOG_FILE:-$REPO_ROOT/logs/setup.log}"

TOOLS=minimal
TARGET_USER="${SUDO_USER:-${USER:-root}}"
SKIP_SYSCTL=0
GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.21.2}"

while [ $# -gt 0 ]; do
  case "$1" in
    --tools) TOOLS="${2:?}"; shift 2 ;;
    --user) TARGET_USER="${2:?}"; shift 2 ;;
    --skip-sysctl) SKIP_SYSCTL=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
case "$TOOLS" in minimal|all) ;; *) die "--tools must be minimal or all" ;; esac

[ "$(uname -s)" = "Linux" ] || die "This script supports Linux only"
[ -r /etc/os-release ] || die "Cannot detect the operating system"
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"; OS_LIKE="${ID_LIKE:-}"
case "$(uname -m)" in x86_64) ARCH=amd64; ALT=x86_64; GL=x64 ;; aarch64|arm64) ARCH=arm64; ALT=aarch64; GL=arm64 ;; *) die "Unsupported CPU: $(uname -m)" ;; esac

FAMILY=other
case "$OS_ID $OS_LIKE" in *debian*|*ubuntu*) FAMILY=debian ;; *rhel*|*fedora*|*centos*|*amzn*) FAMILY=rhel ;; esac
[ "$FAMILY" != other ] || die "Unsupported distribution: $OS_ID"
log_info "Detected $PRETTY_NAME ($FAMILY family, $ARCH)"

if [ "$(id -u)" -ne 0 ]; then have_cmd sudo || die "Run as root or install sudo"; fi

pkg_install() {
  if [ "$FAMILY" = debian ]; then as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
  else as_root "$(have_cmd dnf && echo dnf || echo yum)" install -y "$@"; fi
}

# ---------- base packages ----------
log_info "Installing base packages"
if [ "$FAMILY" = debian ]; then
  as_root apt-get update -y
  pkg_install ca-certificates curl gnupg git jq unzip wget make openssl python3 python3-venv python3-pip apache2-utils lsb-release
else
  pkg_install ca-certificates curl git jq unzip wget make openssl python3 python3-pip httpd-tools
fi

# ---------- Docker ----------
install_docker() {
  if have_cmd docker && docker compose version >/dev/null 2>&1; then log_ok "Docker and Compose already installed"; return; fi
  log_info "Installing Docker Engine and the Compose plugin"
  if [ "$FAMILY" = debian ]; then
    local distro="$OS_ID"; [ "$distro" = ubuntu ] || distro=debian
    as_root install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$distro/gpg" | as_root gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    as_root chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$distro $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
      | as_root tee /etc/apt/sources.list.d/docker.list >/dev/null
    as_root apt-get update -y
    pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    pkg_install docker
    as_root mkdir -p /usr/local/lib/docker/cli-plugins
    as_root curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$ALT" -o /usr/local/lib/docker/cli-plugins/docker-compose
    as_root chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  fi
  as_root systemctl enable --now docker
}
install_docker
if id "$TARGET_USER" >/dev/null 2>&1 && ! id -nG "$TARGET_USER" | grep -qw docker; then
  as_root usermod -aG docker "$TARGET_USER"
  log_warn "$TARGET_USER was added to the docker group: log out and back in for it to take effect"
fi

# ---------- kernel setting Elasticsearch needs ----------
if [ "$SKIP_SYSCTL" = 0 ]; then
  echo "vm.max_map_count=262144" | as_root tee /etc/sysctl.d/99-nexvion.conf >/dev/null
  as_root sysctl -q --system >/dev/null 2>&1 || as_root sysctl -w vm.max_map_count=262144 >/dev/null
  log_ok "vm.max_map_count set to 262144 (needed by Elasticsearch)"
fi

# ---------- extra DevOps tools ----------
install_extra_tools() {
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN

  have_cmd kubectl || { log_info "Installing kubectl"
    local v; v="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
    curl -fsSLo "$tmp/kubectl" "https://dl.k8s.io/release/$v/bin/linux/$ARCH/kubectl"
    as_root install -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl; }

  have_cmd helm || { log_info "Installing Helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | as_root bash; }

  have_cmd aws || { log_info "Installing AWS CLI v2"
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$ALT.zip" -o "$tmp/awscli.zip"
    unzip -q "$tmp/awscli.zip" -d "$tmp" && as_root "$tmp/aws/install" --update; }

  have_cmd terraform || { log_info "Installing Terraform"
    if [ "$FAMILY" = debian ]; then
      curl -fsSL https://apt.releases.hashicorp.com/gpg | as_root gpg --dearmor --yes -o /usr/share/keyrings/hashicorp.gpg
      echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo "${VERSION_CODENAME}") main" | as_root tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
      as_root apt-get update -y && pkg_install terraform
    else
      as_root curl -fsSLo /etc/yum.repos.d/hashicorp.repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo && pkg_install terraform
    fi; }

  have_cmd ansible || { log_info "Installing Ansible"
    if [ "$FAMILY" = debian ]; then pkg_install ansible; else as_root python3 -m pip install ansible; fi; }

  have_cmd trivy || { log_info "Installing Trivy"
    curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | as_root sh -s -- -b /usr/local/bin; }

  have_cmd gitleaks || { log_info "Installing Gitleaks $GITLEAKS_VERSION"
    curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${GL}.tar.gz" | tar -xz -C "$tmp" gitleaks
    as_root install -m 0755 "$tmp/gitleaks" /usr/local/bin/gitleaks; }
}
[ "$TOOLS" = all ] && install_extra_tools

# ---------- project folders ----------
mkdir -p "$REPO_ROOT/backups" "$REPO_ROOT/reports" "$REPO_ROOT/logs"
[ -f "$REPO_ROOT/docker/.env" ] || { cp "$REPO_ROOT/docker/.env.example" "$REPO_ROOT/docker/.env"; log_warn "Created docker/.env from the example - set GRAFANA_ADMIN_PASSWORD before using monitoring"; }

# ---------- summary ----------
log_info "Installed versions:"
for c in git docker kubectl helm terraform ansible aws trivy gitleaks jq python3; do
  if have_cmd "$c"; then printf '  %-10s %s\n' "$c" "$("$c" --version 2>&1 | head -1)" >&2; else printf '  %-10s %s\n' "$c" "not installed" >&2; fi
done
log_ok "Setup finished"
