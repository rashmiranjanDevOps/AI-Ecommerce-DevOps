# Security (DevSecOps)

Security checks run inside the delivery pipeline, not after it.

| Layer | Tool | Script | Fails the build? |
|---|---|---|---|
| Secrets in code and Git history | Gitleaks | `security/scan-secrets.sh` | yes |
| Dependencies / third-party resources | `scripts/check_assets.py`, Trivy fs | `security/scan-dependencies.sh` | yes on HIGH/CRITICAL |
| IaC and config misconfiguration | Trivy config (Dockerfile, Kubernetes, Helm, Terraform) | `security/scan-dependencies.sh` | yes on HIGH/CRITICAL |
| Container image | Trivy image (+ optional SBOM) | `security/scan-image.sh IMAGE` | yes on fixable HIGH/CRITICAL |
| Container runtime | non-root user, read-only filesystem, all capabilities dropped | `docker/Dockerfile`, compose, Kubernetes manifests | n/a |
| Cluster | Pod Security `restricted`, NetworkPolicy default-deny, least-privilege RBAC | `kubernetes/` | n/a |
| Cloud | IAM roles instead of keys, encrypted EBS, no public SSH by default | `terraform/` | n/a |
| Linux host | SSH, firewall, fail2ban, sysctl, file permissions | `security/linux-hardening.sh`, Ansible role `hardening` | audit mode exits 1 |
| Kubernetes secrets | never committed; created from the command line | `kubernetes/secret.yaml` (placeholder only) | Gitleaks |

## Run everything locally
```bash
./scripts/setup.sh --tools all      # installs gitleaks and trivy
./security/scan-secrets.sh
./security/scan-dependencies.sh
./scripts/deploy.sh build --tag test
./security/scan-image.sh local/nexvion-web:test --sbom
sudo ./security/linux-hardening.sh          # audit
sudo ./security/linux-hardening.sh --apply  # fix
```

## Accepting a finding
Add the ID to `security/.trivyignore` with a reason, an owner and a review date. Do not lower the severity
to make a build pass.

## Known finding in the application (not changed: it is the company's code)
`script.js` and `payment.js` create `<img onerror="...">` attributes as strings. Inline event handlers force
the Content-Security-Policy to allow `'unsafe-inline'` scripts (see `docker/nginx/default.conf`).
Recommended fix for the application team: use `addEventListener('error', ...)` and then remove
`'unsafe-inline'` from `script-src`.
