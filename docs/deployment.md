# Deployment guide

> For a step-by-step version with the terminal and folder for every command, use [RUNBOOK.md](RUNBOOK.md).

Three ways to run the platform. Use them in this order: **A** (laptop) -> **B** (one server) -> **C** (AWS EKS).

## A. Local: Docker Compose (about 5 minutes)

```bash
sudo ./scripts/setup.sh --tools minimal        # Docker + Compose (re-login for the docker group)
cp docker/.env.example docker/.env             # set GRAFANA_ADMIN_PASSWORD
./scripts/deploy.sh compose up                 # site only: proxy + web
./scripts/deploy.sh compose up --monitoring    # + Prometheus, Alertmanager, Grafana, exporters
./scripts/deploy.sh compose up --logging       # + Elasticsearch, Logstash, Kibana, Filebeat (needs 4 GB RAM)
```

| What | Address |
|---|---|
| Site (through the proxy) | http://localhost |
| Site (web container directly) | http://localhost:8080 |
| Health | http://localhost/health |
| Prometheus / Alertmanager | http://localhost:9090 / http://localhost:9093 |
| Grafana (dashboard *Nexvion - Platform Overview (Docker)*) | http://localhost:3000 |
| Kibana (data views `nexvion-logs-*`, `nexvion-system-*`) | http://localhost:5601 |

Check: `./scripts/health-check.sh --url http://localhost --compose`. Stop: `./scripts/deploy.sh compose down`.
Monitoring and logging ports are bound to `127.0.0.1` on purpose: from another machine use an SSH tunnel
(`ssh -L 3000:localhost:3000 ubuntu@<server>`).

## B. One server with Ansible

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
cp group_vars/all/vault.yml.example group_vars/all/vault.yml    # set the passwords, then:
ansible-vault encrypt group_vars/all/vault.yml
# put your public key in group_vars/all/main.yml (admin_ssh_public_keys), and edit nexvion_repo_url
ansible-playbook -i inventory.dev.ini playbook.yml --ask-vault-pass --check --diff   # dry run
ansible-playbook -i inventory.dev.ini playbook.yml --ask-vault-pass
```

`inventory.dev.ini` is written by Terraform (step C2). To use your own server, copy `ansible/inventory`,
uncomment a host and use `-i inventory`.
Result: hardened server (SSH keys only, ufw, fail2ban), Docker, and the Nexvion stack running under systemd
(`systemctl status nexvion`) with a nightly backup and a weekly cleanup.

## C. AWS (EKS) end to end

Cost: while everything runs it is roughly **USD 0.50 per hour** (EKS control plane, 2 x t3.large nodes,
NAT gateway, two EC2 servers, application load balancer; estimate, check the AWS pricing page for your region).
**Tear down after every session** (section D).

### C1. Remote state (once)
```bash
aws configure                                   # or aws sso login
./terraform/bootstrap-backend.sh                # S3 bucket (versioned, encrypted) + DynamoDB lock table
```

### C2. Infrastructure
```bash
cd terraform
cp environments/dev/secret.tfvars.example environments/dev/secret.tfvars   # your IP, key pair name
terraform init -backend-config=environments/dev/backend.hcl
terraform plan  -var-file=environments/dev/terraform.tfvars -var-file=environments/dev/secret.tfvars -out=tfplan
terraform apply tfplan                          # about 15-20 minutes
terraform output
```
Creates: VPC (2 public + 2 private subnets), EKS with a managed node group and add-ons (vpc-cni with NetworkPolicy,
coredns, kube-proxy, EBS CSI), ECR, Jenkins server, Docker host, IAM roles, KMS key, flow logs,
and `ansible/inventory.dev.ini`.

After the first apply, tighten `eks_public_access_cidrs` to your IP plus the Jenkins server IP
(`terraform output jenkins_public_ip`) and apply again, because Jenkins must reach the Kubernetes API.

### C3. Cluster bootstrap (once, as the person who ran Terraform = cluster admin)
```bash
$(terraform output -raw update_kubeconfig_command)
cd .. && kubectl get nodes                      # nodes Ready
kubectl apply -f kubernetes/namespace.yaml -f kubernetes/rbac.yaml
./scripts/deploy.sh addons                      # AWS Load Balancer Controller, metrics-server, kube-prometheus-stack, dashboards, alert rules
./scripts/deploy.sh elk                         # Elasticsearch, Logstash, Kibana, Filebeat
```
Note the Grafana admin password printed once by `addons` (stored in the Secret `grafana-admin`).

### C4. Servers (Jenkins, Docker host)
```bash
cd ansible && ansible-playbook -i inventory.dev.ini playbook.yml --ask-vault-pass
```
Jenkins opens at `terraform output jenkins_url`. Ansible already sets the global variables
`ECR_REGISTRY`, `EKS_CLUSTER_NAME`, `AWS_REGION` and creates the job `nexvion` (pipeline from `jenkins/Jenkinsfile`).
Then in GitHub: *Settings > Webhooks > Add* `http://<jenkins-ip>:8080/github-webhook/` (push events).
Add `webhook_cidrs` (GitHub hook IPs) in Terraform so GitHub can reach Jenkins; otherwise start builds by hand.

### C5. First release
Run the Jenkins job once with `DEPLOY_STRATEGY=rolling`. Without Jenkins, from your laptop:
```bash
REG=$(cd terraform && terraform output -raw ecr_registry)
./scripts/deploy.sh build --registry $REG --tag v1
./security/scan-image.sh $REG/nexvion-web:v1
./scripts/deploy.sh push  --registry $REG --tag v1
./scripts/deploy.sh helm  --image-repo $REG/nexvion-web --tag v1 --env dev
./scripts/deploy.sh ingress-host                                 # waits for the ALB and prints its address
./scripts/health-check.sh --k8s --url http://<ALB-address>
```

### C6. Release strategies

| Strategy | Jenkins parameter | Manual commands |
|---|---|---|
| **Rolling** (default): new pods replace old ones one at a time, never fewer ready pods than desired | `rolling` | `./scripts/deploy.sh helm --tag <new>` |
| **Blue-green**: new version runs beside the old; traffic is switched at once | `bluegreen` (asks for approval before the switch) | `deploy.sh bluegreen deploy <image>` -> test with `kubectl port-forward svc/nexvion-web-green-preview 8081:80` -> `deploy.sh bluegreen promote` -> `deploy.sh helm ... --set service.activeColor=green` -> `deploy.sh bluegreen finalize`. Undo before finalize: `deploy.sh bluegreen rollback` |
| **Canary**: a small share of real traffic goes to the new version first (ALB weighted routing) | `canary` + `CANARY_WEIGHT` | `deploy.sh canary start <image> 10` -> watch Grafana/Kibana -> `deploy.sh canary weight 50` -> `deploy.sh helm --tag <new>` then `deploy.sh canary abort`, or `deploy.sh canary abort` to cancel |

### C7. Verify
Follow `docs/implementation.md` (the checklist at the end) and take the screenshots listed in the README.

### Rollback
`./scripts/deploy.sh rollback helm` (previous Helm revision) or `rollback k8s` (previous ReplicaSet).
`helm upgrade --atomic` already rolls back by itself when the new pods do not become ready.

## D. Teardown (order matters)

The ALB is created by the AWS Load Balancer Controller. If the controller or the cluster is removed first, the ALB stays
attached to the VPC and `terraform destroy` then hangs on the subnets.

```bash
helm -n nexvion uninstall nexvion                        # deletes the Ingress -> the controller deletes the ALB
kubectl -n nexvion delete -f kubernetes/strategies/canary/canary.yaml --ignore-not-found
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn'    # must be EMPTY - repeat every minute until it is
helm -n kube-system uninstall aws-load-balancer-controller   # only after the ALB is gone
helm -n monitoring uninstall monitoring
kubectl delete ns nexvion logging --ignore-not-found
kubectl delete pvc --all -A --ignore-not-found           # EBS volumes of Prometheus / Elasticsearch
cd terraform && terraform destroy -var-file=environments/dev/terraform.tfvars -var-file=environments/dev/secret.tfvars
```
Then check nothing is left (each should print an empty list): EC2 instances, NAT gateways, load balancers,
EBS volumes, Elastic IPs, EKS clusters, ECR repositories. The S3 state bucket and the lock table cost almost
nothing and may stay.
