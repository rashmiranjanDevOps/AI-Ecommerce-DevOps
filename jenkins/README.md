# Jenkins

`Jenkinsfile` is the main CI/CD pipeline. The Ansible roles `devops_tools` and `jenkins` prepare the server;
this page explains what the pipeline needs and does.

## Stages

| # | Stage | What it does | Fails when |
|---|---|---|---|
| 1 | Checkout Source | `checkout scm`, sets `IMAGE_TAG = <build>-<short sha>` | `ECR_REGISTRY` / `EKS_CLUSTER_NAME` not defined |
| 2 | Install Dependencies | `npm install` for the lint tools (`jenkins/lint`) | no internet / wrong Node |
| 3 | Build | HTML, CSS, JS lint; packages the validated site as `build/nexvion-site-<tag>.tar.gz` (archived) | lint errors |
| 4 | Test | `scripts/test.sh`: HTML structure, local assets, JS/shell syntax, YAML/JSON, config sync, analyzer tests | any test fails |
| 5 | Security Checks (parallel) | `security/scan-secrets.sh` (Gitleaks), `security/scan-dependencies.sh` (Trivy fs, IaC) | secret found, HIGH/CRITICAL finding |
| 6 | Docker Build | builds the image, starts it and runs `health-check.sh` against it (smoke test) | build or health failure |
| 7 | Image Scan | `security/scan-image.sh` (Trivy image + SBOM) | fixable HIGH/CRITICAL |
| 8 | Push Image | `deploy.sh push` -> ECR (logs in with the instance role) | permission / immutable tag clash |
| 9 | Deploy (main only) | `aws eks update-kubeconfig`, then rolling / canary / blue-green | Helm `--atomic` rollback |
| 10 | Health Check | `health-check.sh --k8s` against the ingress address, 20 retries | unhealthy |
| 11 | Deployment Success | message | |

`post failure`: the analyzer reads `reports/pipeline.log` and writes `reports/incident-report.md`
(class, severity, probable cause, investigation, remediation). `post always`: archives `reports/**`, prunes images.
Slack messages are sent only if the credential `slack-webhook` exists.

## Parameters
`DEPLOY_ENV` (dev/prod values file), `DEPLOY_STRATEGY` (rolling/bluegreen/canary), `CANARY_WEIGHT`, `APP_URL`, `DEPLOY` (untick to stop after the push).

## What the Jenkins server needs
git, docker, node 20, python3, aws cli v2, kubectl, helm, trivy, gitleaks (role `devops_tools`),
an instance role with ECR push + `eks:DescribeCluster` (Terraform), and an EKS access entry
(Terraform) that maps the role to read-only cluster access plus write access in the `nexvion` namespace only.

## Manual setup if you do not use Ansible
1. Install the tools above and the plugins: git, workflow-aggregator, pipeline-stage-view, github, credentials-binding, timestamper, ws-cleanup, build-timeout.
2. *Manage Jenkins > System > Global properties > Environment variables*: `ECR_REGISTRY`, `EKS_CLUSTER_NAME`, `AWS_REGION`.
3. *New Item > Pipeline > Pipeline script from SCM* > Git URL of this repository, branch `*/main`, script path `jenkins/Jenkinsfile`.
4. Run it once by hand (this registers the `githubPush()` trigger), then add the GitHub webhook `http://<jenkins>:8080/github-webhook/`.
5. Optional credentials: `slack-webhook` (secret text).

## Lint tools
`jenkins/lint/` holds `package.json` and the rule files (`.htmlhintrc`, `.stylelintrc.json`, `eslint.config.mjs`).
Only rules that catch real bugs are errors, so the company's code passes unchanged.
