## What changed and why
<!-- One or two sentences. Link the issue if there is one. -->

## Type
- [ ] Application / Docker
- [ ] CI/CD pipeline
- [ ] Infrastructure (Terraform / Ansible)
- [ ] Kubernetes / Helm
- [ ] Monitoring / logging
- [ ] Security
- [ ] Documentation

## Checklist (reviewer ticks too)
- [ ] `./scripts/test.sh` passes locally
- [ ] No secrets, `.env` files or Terraform state committed
- [ ] If `docker/nginx/default.conf` changed: `./scripts/sync-config.sh` was run
- [ ] If Terraform changed: the `terraform plan` output is pasted below
- [ ] Docs updated (README / docs/) where behaviour changed
- [ ] Rollback is possible (`./scripts/deploy.sh rollback ...`)

## Evidence
<!-- Screenshot, command output or plan summary. -->
