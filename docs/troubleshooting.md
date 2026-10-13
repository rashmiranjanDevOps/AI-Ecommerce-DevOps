# Troubleshooting

First step for any problem: `./ai/incident-analysis/run.sh docker` (or `k8s`, `elk`, `file <log>`).
It reads the logs and prints error class, severity, possible cause, what to check and how to fix it.

| Symptom | Likely cause | Fix |
|---|---|---|
| `docker compose` says `Set GRAFANA_ADMIN_PASSWORD in docker/.env` | monitoring profile started without the variable | edit `docker/.env` |
| `port is already allocated` / `address already in use` on 80 | another web server uses port 80 | set `PROXY_PORT=8081` in `docker/.env`, or stop the other service |
| Browser shows the site but no pictures or fonts | the browser cannot reach `images.unsplash.com` / Google Fonts (offline, proxy) | check the browser's internet access. The servers do not need it |
| `elasticsearch` exits, log has `max virtual memory areas vm.max_map_count` | kernel limit too low | `sudo sysctl -w vm.max_map_count=262144` (`scripts/setup.sh` makes it permanent) |
| Kibana "data view not found" | `elk-setup` did not run yet | `docker compose --profile logging run --rm elk-setup` |
| `/nginx_status` returns 403/404 on the web container | request does not come from an internal network | normal from the internet; Prometheus reaches it from inside Docker/Kubernetes |
| Nginx container restarts with `[emerg]` | invalid `default.conf` | `docker run --rm -v $PWD/docker/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro nginxinc/nginx-unprivileged:1.27-alpine nginx -t` |
| `scripts/test.sh` fails "Nginx config out of sync" | `default.conf` changed without syncing | `./scripts/sync-config.sh` and commit |
| Jenkins stage *Install Dependencies* fails `npm ERR!` | no internet on the agent, or old Node | Node 20 and outbound HTTPS (role `devops_tools`) |
| Jenkins "Set the global environment variable ECR_REGISTRY" | Ansible role not applied, or variables empty | Manage Jenkins > System > Global properties, or re-run the playbook with Terraform's inventory |
| apt error `NO_PUBKEY` for Jenkins | Jenkins rotated its signing key | read https://www.jenkins.io/blog/2025/12/23/repository-signing-keys-changing/ and set `jenkins_apt_key_url` |
| Trivy stage fails with `Total: N (HIGH...)` | vulnerable package in the base image | rebuild with the newest base image; if it is a false positive add it to `security/.trivyignore` with a reason |
| Gitleaks stage fails | a secret is in the code or history | revoke it, remove it, never just "allow-list" a real secret |
| `docker push` -> `no basic auth credentials` | not logged in to ECR | `deploy.sh push` logs in; the Jenkins role needs the ECR push policy (Terraform module `compute`) |
| `ErrImagePull` / `ImagePullBackOff` | tag does not exist in ECR, or node role cannot pull | `aws ecr describe-images --repository-name nexvion-web`; node role has `AmazonEC2ContainerRegistryReadOnly` |
| `docker push` fails "tag invalid: immutable" | the tag already exists (tags are immutable) | use a new tag (the pipeline uses build number + commit) |
| Helm: `UPGRADE FAILED: timed out waiting for the condition` | new pods not ready; `--atomic` rolled back | `kubectl -n nexvion describe pod`, `logs`; fix the cause (probe, image, resources) |
| Helm: `ingress.basicAuth.enabled is true but the secret ... does not exist` | the chart refuses to start without the secret | create it (see `helm/ecommerce/templates/secret.yaml`), or `--set ingress.basicAuth.skipLookup=true` for `helm template` |
| `kubectl` -> `Forbidden` from Jenkins | access entry / RBAC missing | `terraform apply` (access entry), `kubectl apply -f kubernetes/rbac.yaml`; group `nexvion-deployers` |
| Pods rejected: `violates PodSecurity "restricted"` | a manifest lacks `runAsNonRoot`, seccomp or dropped capabilities | copy the `securityContext` from `kubernetes/deployment.yaml` |
| HPA shows `<unknown>` | metrics-server missing | `./scripts/deploy.sh addons` |
| PVC stays `Pending` (Prometheus, Elasticsearch) | EBS CSI driver not installed/ready | check the EKS add-on `aws-ebs-csi-driver` and its IAM role (Terraform module `eks`) |
| NetworkPolicy has no effect | CNI not enforcing | VPC CNI add-on with `enableNetworkPolicy=true` (set in Terraform) |
| Ingress has no ADDRESS after 5 minutes | the load balancer controller is not running or lacks permission | `kubectl -n kube-system logs deploy/aws-load-balancer-controller`; check the IAM role annotation on its service account and the subnet tags `kubernetes.io/role/elb` |
| ALB shows targets *unhealthy* / site gives 503 or 504 | NetworkPolicy blocks the ALB, or the health path fails | the policy `allow-alb` must allow the VPC CIDR to port 8080; `kubectl -n nexvion exec <pod> -- wget -qO- localhost:8080/health` |
| `terraform apply` fails: Kubernetes version not supported | `cluster_version` is no longer in support | `aws eks describe-cluster-versions`, pick a STANDARD_SUPPORT version, set it in `environments/dev/terraform.tfvars` |
| Canary shows 0% traffic | the ALB action annotation was lost (a Helm upgrade can reset it) | `kubectl -n nexvion get ingress nexvion-web -o yaml` must show annotation `alb.ingress.kubernetes.io/actions.weighted-routing` and backend `weighted-routing`; re-run `deploy.sh canary weight 10` |
| Blue-green switch does nothing | Service selector still `color: blue` | `deploy.sh bluegreen status`; the Helm release resets the selector to `service.activeColor` |
| Grafana panels empty (Kubernetes dashboard) | ServiceMonitor not applied or no network path | `kubectl apply -f monitoring/kubernetes/servicemonitor.yaml`; check `allow-prometheus-scrape` NetworkPolicy |
| Prometheus target for `nginx` is down (Compose) | the web container is not healthy, or the allow-list in `default.conf` does not cover the Docker network | `docker compose ps`; allow-list covers 10/8, 172.16/12, 192.168/16 |
| `terraform destroy` hangs on subnets / VPC | a load balancer or ENI still exists | follow the teardown order in `docs/deployment.md` section D |
| `terraform apply`: `Error acquiring the state lock` | another run (or a crashed run) holds the lock | wait; if sure nobody runs it: `terraform force-unlock <ID>` |
| Ansible: `UNREACHABLE` / `Permission denied (publickey)` | wrong key, user or security group | the inventory has the right `.pem` path; `admin_cidrs` contains your current IP |
| Ansible `grafana_admin_password` assertion | vault file missing | create `group_vars/all/vault.yml` (see `.example`) |
| AI analyzer prints "No known error patterns" | the pattern is not in the knowledge base | add a rule with `--rules my-rules.json` (same fields as `RULES` in `analyzer.py`) |
| AI analyzer `LLM call failed` | no `ANTHROPIC_API_KEY`, no internet, wrong `AI_MODEL` | the rule-based report is still produced; fix the key or leave `--llm` off |
