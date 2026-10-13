# Linux environment

Linux (Ubuntu 22.04/24.04; Debian, Amazon Linux and RHEL family are supported by `scripts/setup.sh`)
is the base of every part of the platform. This page lists what the project uses and the commands to check it.

| Topic | What the project does | Check it |
|---|---|---|
| Package management | `apt` installs Docker, Java, Jenkins, Trivy, Node.js from signed repositories (keys in `/etc/apt/keyrings`) | `apt-cache policy docker-ce jenkins` |
| Process / service management | `systemd` runs Docker, Jenkins and the `nexvion` Compose stack at boot | `systemctl status docker jenkins nexvion` |
| Users and groups | personal admin user, `nexvion` system user (no login shell), `jenkins` and CI users in the `docker` group | `id jenkins`, `getent passwd nexvion` |
| Permissions | `.env` is 0600, `/etc/shadow` 0640, Jenkins systemd override 0600, project files owned by `nexvion` | `stat -c '%a %U %n' docker/.env` |
| SSH | key-only login, no root login, 3 tries, fail2ban bans repeated failures | `sshd -T \| grep -E 'permitrootlogin|passwordauth'` |
| Firewall | `ufw` default deny; only 22, 80, 443 (Jenkins server: 22, 8080) | `sudo ufw status verbose` |
| Environment variables | `docker/.env` for Compose; Jenkins global variables (`ECR_REGISTRY`, `EKS_CLUSTER_NAME`, `AWS_REGION`) | `docker compose config`, Jenkins > System |
| Networking | listening ports, DNS, routes; containers on a bridge network | `ss -tlnp`, `dig`, `ip route`, `docker network ls` |
| Kernel settings | `vm.max_map_count=262144` for Elasticsearch; sysctl hardening | `sysctl vm.max_map_count` |
| Disk and memory | health check warns at 80% / fails at 90% disk; cleanup script frees space | `df -h`, `free -m`, `docker system df` |
| Logs | JSON Nginx logs to stdout -> Docker `json-file` (rotated 10 MB x 3) -> Filebeat; host logs `/var/log/syslog`, `auth.log` | `docker logs nexvion-proxy`, `journalctl -u jenkins` |
| Scheduling | cron: nightly backup 02:15, weekly cleanup Sunday 03:30 | `sudo crontab -l` |
| Troubleshooting toolbox | `curl -v`, `ss`, `journalctl`, `docker logs`, `kubectl describe`, the AI analyzer | `./ai/incident-analysis/run.sh docker` |

## Prepare a machine

```bash
git clone <repo-url> && cd ai-ecommerce-devops
sudo ./scripts/setup.sh --tools all     # Docker, Compose, kubectl, helm, terraform, ansible, aws, trivy, gitleaks
newgrp docker                            # or log out and in, so the docker group applies
sudo ./security/linux-hardening.sh       # audit; add --apply to fix
```
