#!/usr/bin/env bash
# Basic Linux hardening for a Nexvion server.
#   linux-hardening.sh            audit only: prints PASS/FAIL for each control (changes nothing)
#   linux-hardening.sh --apply    apply the fixes (needs root)
# The same controls are applied by the Ansible role "hardening".
#
# SSH safety: password login and root login are only disabled when the target user already has an
# authorized_keys file, so you cannot lock yourself out.
set -uo pipefail
source "$(dirname "$0")/../scripts/lib/common.sh"
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
[ "$APPLY" = 0 ] || [ "$(id -u)" -eq 0 ] || die "--apply needs root (use sudo)"
TARGET_USER="${SUDO_USER:-${USER:-root}}"
SSHD=/etc/ssh/sshd_config
FAILS=0
check() { # name, command that returns 0 when compliant
  if eval "$2" >/dev/null 2>&1; then log_ok "PASS  $1"; return 0; fi
  FAILS=$((FAILS+1)); log_warn "FAIL  $1"; return 1
}
sshd_has() { grep -Eiq "^\s*$1\s+$2\b" "$SSHD" /etc/ssh/sshd_config.d/*.conf 2>/dev/null; }
set_sshd() { # key value
  as_root sed -i -E "/^\s*#?\s*$1\s+/d" "$SSHD"; echo "$1 $2" | as_root tee -a "$SSHD" >/dev/null
}
home_of() { getent passwd "$1" | cut -d: -f6; }
has_keys() { [ -s "$(home_of "$TARGET_USER")/.ssh/authorized_keys" ]; }

# ---- SSH ----
check "SSH: root login disabled"        "sshd_has PermitRootLogin no" || { [ "$APPLY" = 1 ] && has_keys && set_sshd PermitRootLogin no; }
check "SSH: password login disabled"    "sshd_has PasswordAuthentication no" || { [ "$APPLY" = 1 ] && has_keys && set_sshd PasswordAuthentication no; }
check "SSH: max 3 auth tries"           "sshd_has MaxAuthTries 3" || { [ "$APPLY" = 1 ] && set_sshd MaxAuthTries 3; }
check "SSH: X11 forwarding off"         "sshd_has X11Forwarding no" || { [ "$APPLY" = 1 ] && set_sshd X11Forwarding no; }
[ "$APPLY" = 1 ] && ! has_keys && log_warn "No authorized_keys for $TARGET_USER: SSH password/root login left unchanged to avoid lock-out"

# ---- Firewall ----
if have_cmd ufw; then
  check "Firewall (ufw) active" "ufw status | grep -q 'Status: active'" || {
    [ "$APPLY" = 1 ] && { as_root ufw default deny incoming; as_root ufw default allow outgoing; for p in 22 80 443; do as_root ufw allow "$p"/tcp; done; as_root ufw --force enable; }; }
else
  FAILS=$((FAILS+1)); log_warn "FAIL  Firewall: ufw not installed (use security groups or install ufw)"
  [ "$APPLY" = 1 ] && have_cmd apt-get && as_root apt-get install -y ufw
fi

# ---- Brute force protection and automatic updates ----
check "fail2ban installed"              "have_cmd fail2ban-client" || { [ "$APPLY" = 1 ] && have_cmd apt-get && as_root apt-get install -y fail2ban && as_root systemctl enable --now fail2ban; }
check "Automatic security updates"      "dpkg -s unattended-upgrades" || { [ "$APPLY" = 1 ] && have_cmd apt-get && as_root apt-get install -y unattended-upgrades; }

# ---- Kernel / network ----
SYSCTL=/etc/sysctl.d/98-nexvion-hardening.conf
check "sysctl: SYN cookies on"          "[ \"\$(sysctl -n net.ipv4.tcp_syncookies)\" = 1 ]"
check "sysctl: no source routing"       "[ \"\$(sysctl -n net.ipv4.conf.all.accept_source_route)\" = 0 ]"
check "sysctl: ignore ICMP redirects"   "[ \"\$(sysctl -n net.ipv4.conf.all.accept_redirects)\" = 0 ]"
check "sysctl: ASLR enabled"            "[ \"\$(sysctl -n kernel.randomize_va_space)\" = 2 ]"
if [ "$APPLY" = 1 ]; then
  as_root tee "$SYSCTL" >/dev/null <<'CONF'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 1
kernel.randomize_va_space = 2
CONF
  as_root sysctl --system >/dev/null 2>&1
fi

# ---- Files and accounts ----
check "/etc/shadow not world readable"  "[ \"\$(stat -c %a /etc/shadow)\" -le 640 ]" || { [ "$APPLY" = 1 ] && as_root chmod 640 /etc/shadow; }
check "No empty passwords"              "! awk -F: '(\$2==\"\"){f=1} END{exit !f}' /etc/shadow"
check "Only root has UID 0"             "[ \"\$(awk -F: '\$3==0{print \$1}' /etc/passwd)\" = root ]"
check "Docker socket not world writable" "[ ! -S /var/run/docker.sock ] || [ \"\$(stat -c %a /var/run/docker.sock)\" -le 660 ]"
check "No .env file readable by others" "! find '$REPO_ROOT' -name .env -perm /o+r 2>/dev/null | grep -q ."  || { [ "$APPLY" = 1 ] && find "$REPO_ROOT" -name .env -exec chmod 600 {} +; }

if [ "$APPLY" = 1 ]; then
  as_root sshd -t && as_root systemctl reload ssh 2>/dev/null || as_root systemctl reload sshd 2>/dev/null || true
  log_ok "Hardening applied. Re-run without --apply to verify."
else
  [ "$FAILS" -eq 0 ] && log_ok "All controls pass" || { log_warn "$FAILS control(s) failed. Run with --apply to fix."; exit 1; }
fi
