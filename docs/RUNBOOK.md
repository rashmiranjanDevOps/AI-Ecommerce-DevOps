# RUNBOOK: deploy the project step by step

Follow the parts in order. Every step tells you **which terminal**, **which folder**, **what to type** and
**what you should see**.

## How to read this runbook

| Name | Meaning |
|---|---|
| **T1** | Your main terminal on your Linux machine (Ubuntu, or WSL on Windows). |
| **T2, T3, T4** | Extra terminals you open only when a step says so (port-forwards and SSH tunnels). Leave them running. |
| `~/ai-ecommerce-devops` | The **project root**. The folder you get after unzipping. |
| **Browser** | A normal web browser on the same machine. |
| `<...>` | A value you replace, for example `<jenkins-ip>`. |

Rule: **every command is run from the project root unless the step names another folder.**
To get back to the root from anywhere: `cd ~/ai-ecommerce-devops`.

| Part | What | Time | Costs money? |
|---|---|---|---|
| 0 | Install tools | 20 min | no |
| 1 | Run everything on your laptop (Docker) | 15 min | no |
| 2 | GitHub repository and branches | 10 min | no |
| 3 | AWS account preparation | 10 min | no |
| 4 | Terraform: build AWS | 30 min | **yes, from here** |
| 5 | Kubernetes and add-ons | 25 min | yes |
| 6 | Ansible: configure servers | 20 min | yes |
| 7 | Jenkins: first release | 25 min | yes |
| 8 | Demonstrate canary, blue-green, monitoring, logging, AI | 45 min | yes |
| 9 | Screenshots checklist | | |
| 10 | **Teardown (do this at the end of every session)** | 25 min | stops the cost |

AWS costs roughly USD 0.50 per hour while Parts 4 to 8 are running. **Always finish with Part 10.**

---

## PART 0. Install the tools (T1)

**0.1 Unzip the project.** T1, folder `~` (your home folder).
```bash
cd ~
unzip ai-ecommerce-devops.zip
cd ~/ai-ecommerce-devops
```
On WSL, if the zip is in your Windows Downloads folder, copy it first:
`cp /mnt/c/Users/<your-windows-name>/Downloads/ai-ecommerce-devops.zip ~/`

**0.2 Install Docker, Terraform, Ansible, kubectl, Helm, AWS CLI, Trivy, Gitleaks.** T1, project root. Takes about 10 minutes.
```bash
sudo ./scripts/setup.sh --tools all
newgrp docker
```
Check (every line must print a version, none may say "command not found"):
```bash
docker --version && docker compose version && terraform version | head -1 && ansible --version | head -1
kubectl version --client | head -1 && helm version --short && aws --version && trivy --version | head -1 && gitleaks version
```

**0.3 Run the repository tests.** T1, project root.
```bash
./scripts/test.sh
```
You should see `Result: ... passed, 0 failed`.

---

## PART 1. Run it on your laptop (Docker Compose)

No AWS needed. This proves the application, Nginx, monitoring and logging work before you spend money.

**1.1 Create the settings file.** T1, project root.
```bash
cp docker/.env.example docker/.env
nano docker/.env
```
Change the line `GRAFANA_ADMIN_PASSWORD=` to a password of your own (12+ characters). Save with `Ctrl+O`, `Enter`, `Ctrl+X`.

**1.2 Check your memory.** Logging (ELK) needs about 4 GB free.
```bash
free -m
```
If "available" is under 4000, use `--monitoring` only in step 1.3.

**1.3 Start everything.** T1, project root.
```bash
./scripts/deploy.sh compose up --monitoring --logging
```
This builds the image and starts about 14 containers. It ends with a health table where every line is `PASS`.
If port 80 is busy, set `PROXY_PORT=8081` in `docker/.env` and run it again (use `:8081` in the URLs below).

**1.4 Open it.** Browser:

| What | Address |
|---|---|
| The shop | http://localhost |
| Health | http://localhost/health |
| Grafana (login `admin` + your password) | http://localhost:3000 → Dashboards → folder *Nexvion* → *Platform Overview (Docker)* |
| Prometheus targets (all should be UP) | http://localhost:9090/targets |
| Alertmanager | http://localhost:9093 |
| Kibana | http://localhost:5601 → menu → Discover → data view *Nexvion application logs* |

**1.5 Create some traffic** so the dashboards and logs have data. T1, project root.
```bash
for i in $(seq 1 100); do curl -s -o /dev/null http://localhost/; curl -s -o /dev/null http://localhost/products.html; done
./scripts/health-check.sh --url http://localhost --compose
```

**1.6 Try the AI incident analysis.** T1, project root.
```bash
docker stop nexvion-web
for i in $(seq 1 20); do curl -s -o /dev/null http://localhost/; done
./ai/incident-analysis/run.sh docker
docker start nexvion-web
```
You get a report with *error class, severity, possible cause, investigation, remediation*
(for example "Bad gateway / no healthy upstream"). The file is in `reports/`.

**1.7 Try the other scripts.** T1, project root.
```bash
./scripts/backup.sh && ./scripts/backup.sh --list
./scripts/cleanup.sh --dry-run
./security/scan-secrets.sh
```

**1.8 Stop it.** T1, project root.
```bash
./scripts/deploy.sh compose down
```

---

## PART 2. GitHub repository and branches

Jenkins pulls the code from GitHub, so this part is required.

**2.1 Create an empty repository** in the browser: GitHub → New repository → name `ai-ecommerce-devops`,
**Public** (simplest for the lab), do **not** add a README. Copy its URL.

**2.2 Tell Git who you are (once).** T1, anywhere.
```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

**2.3 Create the branches and push.** T1, project root.
```bash
./scripts/git-init.sh https://github.com/<your-github-name>/ai-ecommerce-devops.git
git push -u origin main
git push origin develop
```
GitHub asks for a username and a **personal access token** as the password
(GitHub → Settings → Developer settings → Personal access tokens → "repo" permission).

**2.4 Practise the pull-request workflow** (this is a project requirement; take a screenshot). T1, project root.
```bash
git switch develop
git switch -c feature/readme-note
echo "" >> docs/git-workflow.md
git add -A && git commit -m "docs: touch workflow doc"
git push -u origin feature/readme-note
```
In the browser, open the link GitHub prints, create a Pull Request into `develop`, review it, merge it.
Then: `git switch develop && git pull`.

---

## PART 3. Prepare your AWS account (T1)

**3.1 Log in the CLI.** You need an IAM user (or SSO) with administrator rights for this lab.
```bash
aws configure
```
Enter: Access Key ID, Secret Access Key, region **`ap-south-1`**, output format `json`. Check:
```bash
aws sts get-caller-identity
```
It must print your account number.

**3.2 Create the SSH key pair for the servers.** T1, anywhere.
```bash
aws ec2 create-key-pair --key-name nexvion-key --region ap-south-1 --query KeyMaterial --output text > ~/.ssh/nexvion-key.pem
chmod 400 ~/.ssh/nexvion-key.pem
```

**3.3 Find your public IP** (only this address will be allowed into the servers and the Kubernetes API).
```bash
curl -s https://checkip.amazonaws.com
```
Write it down as `<my-ip>`.

**3.4 Check which Kubernetes version AWS supports today.**
```bash
aws eks describe-cluster-versions --region ap-south-1 \
  --query "clusterVersions[?status=='STANDARD_SUPPORT'].[clusterVersion,endOfStandardSupportDate]" --output table
```
The project uses **1.35**. If 1.35 is not in the list, note the newest version listed and use it in step 4.2.

---

## PART 4. Terraform: build the AWS infrastructure

**4.1 Create the state bucket and lock table (once).** T1, folder `~/ai-ecommerce-devops/terraform`.
```bash
cd ~/ai-ecommerce-devops/terraform
./bootstrap-backend.sh ap-south-1
```
It prints `Done. Next: ...`. It also fills the bucket name into `environments/*/backend.hcl`.

**4.2 Write your settings.** T1, folder `~/ai-ecommerce-devops/terraform`.
```bash
cp environments/dev/secret.tfvars.example environments/dev/secret.tfvars
nano environments/dev/secret.tfvars
```
Set the three lines like this (use your own IP):
```hcl
admin_cidrs             = ["<my-ip>/32"]
eks_public_access_cidrs = ["<my-ip>/32"]
ssh_key_name            = "nexvion-key"
```
If step 3.4 showed a different version, also edit `cluster_version` in `environments/dev/terraform.tfvars`.

**4.3 Initialise and check.** T1, folder `~/ai-ecommerce-devops/terraform`.
```bash
terraform init -backend-config=environments/dev/backend.hcl
terraform fmt -recursive
terraform validate
```
Expected: `Terraform has been successfully initialized!` and `The configuration is valid.`

**4.4 Plan.** T1, folder `~/ai-ecommerce-devops/terraform`.
```bash
terraform plan -var-file=environments/dev/terraform.tfvars -var-file=environments/dev/secret.tfvars -out=tfplan
```
Read the end: `Plan: N to add, 0 to change, 0 to destroy.` (N is about 60). Take a screenshot.

**4.5 Apply** (this is when billing starts; about 15 to 20 minutes). Same folder.
```bash
terraform apply tfplan
terraform output
```
`terraform output` shows the Jenkins address, app server address, ECR address and cluster name.
This also writes `ansible/inventory.dev.ini`.

**4.6 Let Jenkins reach the Kubernetes API.** Same folder.
```bash
terraform output -raw jenkins_public_ip
nano environments/dev/secret.tfvars
```
Change the second line to include both addresses:
```hcl
eks_public_access_cidrs = ["<my-ip>/32", "<jenkins-ip>/32"]
```
Then apply again (takes a few minutes):
```bash
terraform plan  -var-file=environments/dev/terraform.tfvars -var-file=environments/dev/secret.tfvars -out=tfplan
terraform apply tfplan
```

---

## PART 5. Kubernetes access and add-ons

**5.1 Connect kubectl to the new cluster.** T1, project root.
```bash
cd ~/ai-ecommerce-devops
$(cd terraform && terraform output -raw update_kubeconfig_command)
kubectl get nodes
```
Expected: 2 nodes, `STATUS Ready`.

**5.2 Create the namespace and the deployer permissions (once).** T1, project root.
```bash
kubectl apply -f kubernetes/namespace.yaml -f kubernetes/rbac.yaml
```

**5.3 Install the add-ons.** T1, project root. Takes 10 to 15 minutes.
```bash
./scripts/deploy.sh addons
```
It installs the AWS Load Balancer Controller (creates the load balancer), metrics-server, and Prometheus + Grafana.
**Copy the Grafana password it prints** (shown once; you can read it later, see 8.4). Check:
```bash
kubectl get pods -n kube-system | grep load-balancer
kubectl get pods -n monitoring
```
All pods should be `Running`.

**5.4 Install the logging stack (ELK) in the cluster.** T1, project root.
```bash
./scripts/deploy.sh elk
kubectl get pods -n logging
```
If a pod stays `Pending`, the nodes are full: set `node_desired_size = 3` in `terraform/environments/dev/terraform.tfvars`
(and `node_max_size = 4`), then repeat 4.4 and 4.5 from the `terraform` folder.

---

## PART 6. Ansible: configure the two servers

**6.1 Go to the ansible folder and install its collections.** T1, folder `~/ai-ecommerce-devops/ansible`.
```bash
cd ~/ai-ecommerce-devops/ansible
ansible-galaxy collection install -r requirements.yml
```

**6.2 Create the encrypted password file.** Same folder.
```bash
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
nano group_vars/all/vault.yml
ansible-vault encrypt group_vars/all/vault.yml
```
In the file that `nano` opens, set `grafana_admin_password` and `jenkins_admin_password` (12+ characters each).
`ansible-vault encrypt` asks you to choose a vault password: remember it.

**6.3 Set your repository address and public key.** Same folder.
```bash
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
nano group_vars/all/main.yml
```
Edit two values: `nexvion_repo_url` (your GitHub URL from Part 2) and `admin_ssh_public_keys` (paste the key printed by `cat`):
```yaml
nexvion_repo_url: "https://github.com/<your-github-name>/ai-ecommerce-devops.git"
admin_ssh_public_keys:
  - "ssh-ed25519 AAAA... you@laptop"
```

**6.4 Test the connection.** Same folder.
```bash
ansible -i inventory.dev.ini all -m ping
```
Type `yes` if asked about host keys. Expected: two answers `"ping": "pong"`.

**6.5 Run the playbook** (about 15 minutes). Same folder.
```bash
ansible-playbook -i inventory.dev.ini playbook.yml --ask-vault-pass
```
It asks for the vault password. At the end: `failed=0` for both servers. Take a screenshot of the summary.
Run it a second time: almost everything now says `ok` (not `changed`), which proves it is repeatable.

**6.6 Check the application server.** Browser: `http://<app-server-ip>` (from `terraform output app_server_public_ip`) shows the shop.

---

## PART 7. Jenkins: the first release

**7.1 Open Jenkins.** Browser: the address from `terraform output jenkins_url` (like `http://<jenkins-ip>:8080`).
Log in as **`admin`** with the `jenkins_admin_password` from Part 6. You should see the job **nexvion**.
Check: Manage Jenkins → System → *Global properties* shows `ECR_REGISTRY`, `EKS_CLUSTER_NAME`, `AWS_REGION`.

**7.2 Start the pipeline.** Jenkins browser page: open job **nexvion** → **Build Now**.
(The first run uses the defaults: `dev`, `rolling`, deploy on.) Open the build and watch the **Stage View**.
It takes 10 to 15 minutes. Stages, in order: Checkout Source, Install Dependencies, Build, Test, Security Checks,
Docker Build, Image Scan, Push Image, Deploy, Health Check, Deployment Success. Take a screenshot when all are green.

If a stage is red, click it → *Logs*. The most common causes are in `docs/troubleshooting.md`. Two likely ones on a first run:
* **Build** stage: a lint rule complains about the company's CSS/JS. Edit the matching rule file in `jenkins/lint/`, push, run again.
* **Checkout**: the repository is private. Make it public, or add GitHub credentials to the job.

**7.3 Find the address of the live site.** T1, project root.
```bash
cd ~/ai-ecommerce-devops
./scripts/deploy.sh ingress-host
```
It waits for the load balancer and prints something like `k8s-nexvion-xxxx.ap-south-1.elb.amazonaws.com`.
Open `http://<that-address>` in the browser (the first minute after creation it may not answer yet).

**7.4 Check the deployment.** T1, project root.
```bash
kubectl -n nexvion get all,ingress,hpa
helm -n nexvion list
./scripts/health-check.sh --k8s --url http://<alb-address>
curl -s http://<alb-address>/health ; echo
curl -s http://<alb-address>/version.txt
```
Expected: 2 pods `Running 2/2`, an Ingress with an ADDRESS, and `/health` returns `{"status":"ok",...}`.

**7.5 Optional: start builds automatically on every push.** GitHub must be able to reach Jenkins for this.
In `terraform/environments/dev/secret.tfvars` add `webhook_cidrs` with the GitHub hook IPs
(`curl -s https://api.github.com/meta | python3 -c "import sys,json;print(json.load(sys.stdin)['hooks'])"`) and run the apply from 4.6 again.
Then in GitHub → your repository → Settings → Webhooks → Add webhook: Payload URL `http://<jenkins-ip>:8080/github-webhook/`,
content type `application/json`, event "Just the push event". If you skip this, just click **Build Now** after each push.

---

## PART 8. Demonstrate the remaining requirements

### 8.1 A change that goes live by itself (rolling update)
T1, project root.
```bash
git switch develop && git pull
echo "" >> docs/git-workflow.md
git add -A && git commit -m "docs: trigger a release"
git push origin develop
```
GitHub: open a Pull Request `develop` → `main` and merge it. Jenkins: **Build Now** (or the webhook starts it).
Watch the rolling update in a second terminal:

**T2**, project root:
```bash
cd ~/ai-ecommerce-devops && kubectl -n nexvion get pods -w
```
New pods start and old ones stop one at a time. Stop watching with `Ctrl+C`.

### 8.2 Canary release (a small share of real traffic first)
Jenkins browser: job nexvion → **Build with Parameters** → `DEPLOY_STRATEGY = canary`, `CANARY_WEIGHT = 10` → Build.
The pipeline pauses at *"Promote to 100%?"*. While it waits, T1, project root:
```bash
HOST=$(./scripts/deploy.sh ingress-host)
for i in $(seq 1 60); do curl -s http://$HOST/version.txt; done | sort | uniq -c
```
You see two different version tags: about 90% old, 10% new. Take a screenshot, then click **Promote** in Jenkins.
To cancel instead: `./scripts/deploy.sh canary abort`.

### 8.3 Blue-green release (switch all traffic at once)
Jenkins: **Build with Parameters** → `DEPLOY_STRATEGY = bluegreen` → Build. At the pause, test the new (green) version privately:

**T2**, project root:
```bash
cd ~/ai-ecommerce-devops && kubectl -n nexvion port-forward svc/nexvion-web-green-preview 8081:80
```
**T1**, project root:
```bash
curl -s http://localhost:8081/version.txt
./scripts/deploy.sh bluegreen status
```
Click **Switch to green** in Jenkins. Stop the port-forward in T2 with `Ctrl+C`.

### 8.4 Monitoring in the cluster (Grafana and Prometheus)
**T2**, project root (leave running):
```bash
cd ~/ai-ecommerce-devops && kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
```
**T3**, project root (leave running):
```bash
cd ~/ai-ecommerce-devops && kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
```
**T1**, project root: read the Grafana password if you lost it:
```bash
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```
Browser: http://localhost:3000 (user `admin`) → Dashboards → folder *Nexvion* → **Nexvion - Kubernetes Overview**
(pod status, node status, CPU, memory). http://localhost:9090/targets shows the scrape targets.
Create traffic first: `for i in $(seq 1 200); do curl -s -o /dev/null http://$HOST/; done`

### 8.5 Centralized logging in the cluster (Kibana)
Close T2 and T3 (`Ctrl+C`) or open new terminals.

**T2**, project root: `kubectl -n logging port-forward svc/kibana 5601:5601`
**T3**, project root: `kubectl -n logging port-forward svc/elasticsearch 9200:9200`
**T1**, project root (creates the data views once):
```bash
ES_URL=http://localhost:9200 KIBANA_URL=http://localhost:5601 sh logging/elk/setup-elk.sh
```
Browser: http://localhost:5601 → Discover → data view *Nexvion application logs*. Search `nginx.status : 200`.

### 8.6 AI incident analysis on a real failure, and rollback
T1, project root. This starts a release with an image that does not exist. The old pods keep serving.
```bash
REG=$(cd terraform && terraform output -raw ecr_registry)
kubectl -n nexvion set image deploy/nexvion-web web=$REG/nexvion-web:does-not-exist
kubectl -n nexvion get pods
./ai/incident-analysis/run.sh k8s
./scripts/deploy.sh rollback k8s
kubectl -n nexvion get pods
```
The report names *Image pull failure* with severity, cause, and fix. The rollback restores the previous version.

### 8.7 Security evidence
T1, project root:
```bash
./security/scan-secrets.sh
./security/scan-dependencies.sh
./scripts/deploy.sh build --tag scan-test
./security/scan-image.sh local/nexvion-web:scan-test --sbom
```
On the application server (T4, an SSH session):
```bash
ssh -i ~/.ssh/nexvion-key.pem ubuntu@<app-server-ip>
sudo /opt/nexvion/security/linux-hardening.sh      # audit: every line should say PASS
sudo /opt/nexvion/scripts/backup.sh --volumes && sudo /opt/nexvion/scripts/backup.sh --list
exit
```

### 8.8 Monitoring and logs on the application server (Docker Compose on EC2)
**T4**, project root (leave running; opens tunnels to Grafana and Kibana on that server):
```bash
ssh -i ~/.ssh/nexvion-key.pem -L 3001:localhost:3000 -L 5602:localhost:5601 ubuntu@<app-server-ip>
```
Browser: Grafana http://localhost:3001 (user `admin`, the password from the Ansible vault) and Kibana http://localhost:5602.

---

## PART 9. Screenshots checklist for the report

1. `./scripts/test.sh` result, and `docker compose ps` (Part 1).
2. The shop at http://localhost, Grafana (Docker dashboard), Prometheus targets, Kibana Discover (Part 1).
3. GitHub: branches, a merged Pull Request.
4. `terraform plan` summary and `terraform apply` complete; AWS console: VPC, EKS cluster, EC2 servers, ECR repository.
5. `ansible-playbook` summary (`failed=0`).
6. Jenkins Stage View, all stages green; the Trivy and Gitleaks stage logs.
7. ECR image list with tags like `12-1a2b3c4d`.
8. `kubectl -n nexvion get all,ingress,hpa`; `helm -n nexvion list`.
9. The shop on the load balancer address; `/health`.
10. Canary traffic split output (8.2); blue-green status (8.3).
11. Grafana Kubernetes dashboard; Kibana logs from the cluster.
12. The AI incident report (1.6 and 8.6).
13. Linux hardening audit and backup (8.7).

---

## PART 10. Teardown: do this at the end of EVERY session

Order matters. The load balancer must be deleted **before** the infrastructure, or `terraform destroy` hangs.

**10.1 Remove the application and wait for the load balancer to disappear.** T1, project root.
```bash
cd ~/ai-ecommerce-devops
helm -n nexvion uninstall nexvion
kubectl -n nexvion delete -f kubernetes/strategies/canary/canary.yaml --ignore-not-found
kubectl -n nexvion delete deployment nexvion-web-green --ignore-not-found
aws elbv2 describe-load-balancers --region ap-south-1 --query 'LoadBalancers[].LoadBalancerArn'
```
Repeat the last command every minute until it prints `[]`.

**10.2 Remove the add-ons and volumes.** T1, project root.
```bash
helm -n kube-system uninstall aws-load-balancer-controller
helm -n monitoring uninstall monitoring
kubectl delete ns nexvion logging monitoring --ignore-not-found
kubectl delete pvc --all -A --ignore-not-found
```

**10.3 Destroy the AWS infrastructure.** T1, folder `~/ai-ecommerce-devops/terraform` (takes 15 to 20 minutes).
```bash
cd ~/ai-ecommerce-devops/terraform
terraform destroy -var-file=environments/dev/terraform.tfvars -var-file=environments/dev/secret.tfvars
```
Type `yes` when asked.

**10.4 Check nothing is left that costs money.** T1, anywhere. Every command should print `[]` (or an empty table).
```bash
aws ec2 describe-instances --region ap-south-1 --filters Name=instance-state-name,Values=running,pending --query 'Reservations[].Instances[].InstanceId'
aws ec2 describe-nat-gateways --region ap-south-1 --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId'
aws elbv2 describe-load-balancers --region ap-south-1 --query 'LoadBalancers[].LoadBalancerArn'
aws ec2 describe-volumes --region ap-south-1 --query 'Volumes[].VolumeId'
aws ec2 describe-addresses --region ap-south-1 --query 'Addresses[].PublicIp'
aws eks list-clusters --region ap-south-1 --query clusters
aws ecr describe-repositories --region ap-south-1 --query 'repositories[].repositoryName'
```
The state bucket and the lock table cost almost nothing and can stay. To start again, repeat Parts 4 to 7.

---

## If something fails

1. Read the last 20 lines of the error. 2. Look it up in `docs/troubleshooting.md` (a table by symptom).
3. Ask the analyzer: `./ai/incident-analysis/run.sh file <logfile>`.
Never retry `terraform destroy` blindly: first look for leftover load balancers (10.1).
