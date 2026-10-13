# AI-Powered E-Commerce DevOps & Cloud-Native Delivery Platform

**Domain:** DevOps  |  **Application:** Nexvion e-commerce website (provided by the company, not modified)

This repository is **not** about building the shop. It builds everything *around* the shop: version control,
automation, containers, CI/CD, infrastructure as code, configuration management, Kubernetes, monitoring,
centralized logging, security checks, controlled releases, cloud deployment and AI-assisted incident analysis,
all connected into one delivery chain.

![Architecture](docs/architecture.png)

```
code -> GitHub -> Jenkins (build, test, scan) -> Docker image -> ECR -> Helm -> Kubernetes (EKS)
          Terraform builds AWS -> Ansible configures servers
          Prometheus + Grafana (metrics)  |  ELK (logs)  |  AI analyzer (incidents)
```

## Quick start

| I want to... | Run |
|---|---|
| Try it on my laptop | `sudo ./scripts/setup.sh` then `./scripts/deploy.sh compose up` -> http://localhost |
| Add monitoring and logging | `./scripts/deploy.sh compose up --monitoring --logging` (Grafana :3000, Kibana :5601) |
| Check the repository | `./scripts/test.sh` |
| **Follow the full step-by-step run book** (which terminal, which folder, every command) | [docs/RUNBOOK.md](docs/RUNBOOK.md) |
| Put it on AWS | [docs/RUNBOOK.md](docs/RUNBOOK.md) parts 3 to 7 (details: [docs/deployment.md](docs/deployment.md)) |
| Analyse a failure | `./ai/incident-analysis/run.sh docker` |

`make help` lists the shortcuts.

## Repository layout

```
ai-ecommerce-devops/
├── application/        Nexvion site (company code, unchanged)
├── scripts/            setup.sh, deploy.sh, health-check.sh, backup.sh, cleanup.sh (+ test.sh, sync-config.sh, git-init.sh)
├── docker/             Dockerfile, .dockerignore, docker-compose.yml, Nginx config
├── jenkins/            Jenkinsfile, lint rules
├── terraform/          main.tf, provider.tf, variables.tf, outputs.tf, modules/, environments/
├── ansible/            inventory, playbook.yml, group_vars/, roles/
├── kubernetes/         namespace, deployment, service, configmap, secret, ingress, hpa, rbac, network policy, strategies/
├── helm/ecommerce/     Chart.yaml, values.yaml, templates/
├── monitoring/         Prometheus, Alertmanager, Grafana dashboards, Kubernetes monitoring
├── logging/elk/        Filebeat, Logstash, Elasticsearch, Kibana (Compose and Kubernetes)
├── security/           Gitleaks, Trivy, Linux hardening
├── ai/incident-analysis/  log analyzer, samples, tests
├── docs/               architecture, app analysis, deployment, troubleshooting, implementation checklist
├── .github/            CI workflow, PR template, Dependabot
└── README.md
```

## What is in each layer

| Layer | Highlights |
|---|---|
| **Git / GitHub** | `main` / `develop` / `feature/*`, PR template and review checklist, pre-commit secret scan |
| **Bash** | idempotent scripts with logging, retries, dry-run, JSON output; health check exits non-zero on failure |
| **Nginx** | reverse proxy + web server, JSON access logs, `/health`, security headers, rate limit |
| **Docker** | unprivileged Nginx, read-only file system, no capabilities, health checks, log rotation, Compose profiles |
| **Jenkins** | 11 stages, parallel security scans, smoke test, approval step for canary / blue-green, AI report on failure |
| **GitHub Actions** | the same checks on every pull request; optional keyless push to ECR (OIDC) |
| **Terraform** | VPC, EKS (KMS-encrypted secrets, access entries, EBS CSI, network policy), ECR (immutable, scanned), EC2 with instance roles, remote state with lock, dev/prod environments |
| **Ansible** | roles: common, hardening (SSH, ufw, fail2ban, sysctl), docker, devops_tools, jenkins (plugins, job, global vars), app (systemd, cron backups) |
| **Kubernetes** | namespace with Pod Security `restricted`, AWS Load Balancer Controller (ALB), probes, HPA, PDB, NetworkPolicy, least-privilege RBAC, rolling update |
| **Helm** | one chart, dev/prod values, config checksum restarts, optional ServiceMonitor |
| **Monitoring** | availability probes, Nginx metrics, node and container metrics, 2 dashboards, 12 alert rules |
| **ELK** | JSON parsing, 14-day retention, ready-made data views |
| **DevSecOps** | Gitleaks, Trivy (fs, IaC, image), SBOM, Linux hardening audit, OIDC / IAM roles |
| **Release strategies** | rolling (default), blue-green, canary (ALB weighted routing), rollback commands |
| **AI** | 24 failure patterns + 4 access-log detectors, secret redaction, optional LLM summary |

## Security notes

* No secrets in Git: `.env`, state, keys are ignored; `kubernetes/secret.yaml` is a placeholder that is never applied.
* Elasticsearch runs **without authentication** in this lab setup (localhost / NetworkPolicy only). Turn on `xpack.security` before any real use.
* Nexvion itself stores account passwords in plain text in the browser (demo behaviour, see `docs/app-analysis.md`).
* `eks_public_access_cidrs` defaults to open; restrict it to your IP.
* **ingress-nginx is not used**: the Kubernetes project retired and archived it on 24 March 2026 (no more security patches). The ALB is created by the AWS Load Balancer Controller instead.
* Use an EKS version that is in *standard* support (`cluster_version`, default 1.35). Extended support costs about six times more.

## Evidence for the project report

Screenshots to collect while following `docs/deployment.md`: `terraform apply`, AWS console (VPC, EKS, ECR),
Ansible run (`changed`/`ok` summary), Jenkins stage view, Trivy and Gitleaks stage logs, ECR images,
`kubectl get all,ingress,hpa`, Helm list, the site over the load balancer, `/health`, Grafana (both dashboards),
Prometheus targets, Kibana Discover, a canary or blue-green release, and an AI incident report.
The checklist is in [docs/implementation.md](docs/implementation.md).

## Documentation

[**Run book**](docs/RUNBOOK.md) · [Architecture](docs/architecture.md) · [Application analysis](docs/app-analysis.md) ·
[Deployment guide](docs/deployment.md) · [Troubleshooting](docs/troubleshooting.md) ·
[Implementation map & checklist](docs/implementation.md) · [Git workflow](docs/git-workflow.md) ·
[Linux environment](docs/linux-environment.md) · [Security](security/README.md) ·
[Jenkins](jenkins/README.md) · [AI analyzer](ai/incident-analysis/README.md)
