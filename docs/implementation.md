# Implementation map and verification checklist

Every requirement of the project specification, where it is implemented, and how to prove it works
(proof = command output or screenshot for the report).

## Requirements -> implementation

| # | Spec section | Implemented in | Verify |
|---|---|---|---|
| 1 | Version control, branching, PRs, review, `.gitignore`, README | `.gitignore`, `.github/`, `docs/git-workflow.md`, `scripts/git-init.sh`, `README.md` | `git branch`, a PR screenshot |
| 2 | Linux environment | `docs/linux-environment.md`, `scripts/setup.sh`, role `common`, `hardening` | `./scripts/setup.sh`, `systemctl status docker` |
| 3 | Bash automation | `scripts/setup.sh`, `deploy.sh`, `health-check.sh`, `backup.sh`, `cleanup.sh` (+ `test.sh`, `sync-config.sh`) | run each with `--help` |
| 4 | Web server / reverse proxy, access + error logs | `docker/nginx/default.conf`, `proxy.conf` | `curl -i localhost`, `docker logs nexvion-proxy` (JSON lines) |
| 5 | Containerization | `docker/Dockerfile`, `.dockerignore`, `docker-compose.yml` | `docker compose ps` (healthy) |
| 6 | CI/CD (Jenkins, GitHub integration) | `jenkins/Jenkinsfile`, `.github/workflows/ci.yml` | Jenkins stage view (all stages green) |
| 7 | Infrastructure as Code | `terraform/` (providers, resources, variables, outputs, state, modules, environments) | `terraform plan`, `terraform output` |
| 8 | Configuration management | `ansible/` (inventory, playbook, group_vars, roles) | `ansible-playbook --check`, then a real run |
| 9 | Kubernetes: namespace, deployment, service, configmap, secret, ingress, scaling, rolling update | `kubernetes/` | `kubectl -n nexvion get all,ingress,hpa` |
| 10 | Helm packaging | `helm/ecommerce/` | `helm lint helm/ecommerce`, `helm -n nexvion list` |
| 11 | Monitoring (Prometheus, Grafana) | `monitoring/` | Grafana dashboards, Prometheus targets page |
| 12 | Centralized logging (ELK) | `logging/elk/` | Kibana Discover with `nexvion-logs-*` |
| 13 | DevSecOps (dependency, secret, image scan, hardening, K8s secrets, least privilege) | `security/`, `kubernetes/rbac.yaml`, `networkpolicy.yaml`, Terraform IAM | `./security/scan-*.sh`, `linux-hardening.sh` |
| 14 | Deployment strategy (rolling; blue-green, canary) | `kubernetes/strategies/`, Helm, Jenkins parameter | `./scripts/deploy.sh bluegreen status` |
| 15 | AI-assisted DevOps analysis | `ai/incident-analysis/` | `python3 ai/incident-analysis/analyzer.py --file ai/incident-analysis/samples/db-timeout.log` |
| 16 | Cloud deployment, same lifecycle | `terraform/` + Jenkins deploys to EKS | the site open on the load balancer address |
| 17 | Documentation | `docs/`, `README.md`, `security/README.md`, `jenkins/README.md`, `ai/incident-analysis/README.md` | read them |

## "Expected final state" checklist (specification section 28)

Run each check, save the output or a screenshot.

- [ ] Source code is version controlled: `git log --oneline | head`
- [ ] Collaboration through GitHub: pull request with review and green CI
- [ ] Operational tasks automated: `./scripts/health-check.sh`, `./scripts/backup.sh`, `./scripts/cleanup.sh --dry-run`
- [ ] Application runs consistently in containers: `docker compose ps`; same image in the cluster (`kubectl -n nexvion get deploy -o wide`)
- [ ] CI/CD through Jenkins: build history with the stages Checkout ... Deployment Success
- [ ] Infrastructure through Terraform: `terraform output`, AWS console resources
- [ ] Server configuration through Ansible: `ansible-playbook ... --check` shows `changed=0` after the first run (idempotent)
- [ ] Kubernetes manages the deployment: `kubectl -n nexvion get pods,svc,ingress,hpa`
- [ ] Health and infrastructure metrics monitored: Prometheus targets UP
- [ ] Grafana gives visibility: both dashboards (Docker, Kubernetes) with data
- [ ] Logs collected centrally: Kibana shows requests (`nginx.status`, `nginx.request_uri`)
- [ ] Security checks in delivery: Jenkins stages "Secret scan", "Dependency + IaC scan", "Image Scan"
- [ ] Controlled deployment strategy: a rolling update (`kubectl rollout status`), plus a canary or blue-green demo
- [ ] Runs in a cloud environment: the site on the ALB address (`./scripts/deploy.sh ingress-host`)
- [ ] AI assists incident analysis: `reports/incident-*.md` from a real or simulated failure
- [ ] Continuously deployable: push a small change to `main` and watch it reach production unattended

### Simulate an incident for the AI demo
```bash
docker stop nexvion-web                          # the proxy now returns 502
for i in $(seq 1 20); do curl -s -o /dev/null localhost/; done
./ai/incident-analysis/run.sh docker             # "Bad gateway / no healthy upstream", "High rate of server errors"
docker start nexvion-web
```
