# Git workflow

```
main        <- always deployable; protected; changes only by pull request
 └─ develop <- integration branch
     ├─ feature/<short-name>
     ├─ feature/<short-name>
     └─ fix/<short-name>
```

## Day to day

```bash
./scripts/git-init.sh <remote-url>            # once: creates main + develop and the pre-commit secret scan
git switch develop && git pull
git switch -c feature/add-nginx-metrics
# ... edit ...
./scripts/test.sh                              # must pass
git add -A && git commit -m "feat(monitoring): add nginx exporter"
git push -u origin feature/add-nginx-metrics
# open a Pull Request into develop (template: .github/pull_request_template.md)
```

Release: open a Pull Request **develop -> main**. When it is merged, the Jenkins webhook starts the pipeline,
which builds, scans, pushes and deploys.

## Branch protection (GitHub settings)

* `main` and `develop`: require a pull request, at least 1 approval, and the **CI** checks (GitHub Actions) to pass.
* No force-push, no deletion.

## Commit messages

`type(scope): summary` with type = `feat`, `fix`, `docs`, `chore`, `ci`, `refactor`, `test`.
Examples: `fix(nginx): return 404 for /nginx_status on the proxy`, `ci(jenkins): add canary stage`.

## Code review checklist

1. Does `./scripts/test.sh` pass? (shown by the CI check)
2. No secrets, `.env`, `*.tfstate`, private keys. (Gitleaks runs in CI and as a pre-commit hook.)
3. Terraform change: is the `terraform plan` pasted in the PR and does it destroy anything unexpected?
4. Nginx config change: was `./scripts/sync-config.sh` run?
5. Can this change be rolled back? How?
6. Are docs updated?

## Repository hygiene

`.gitignore` excludes `.env`, state files, keys, generated inventory, reports and backups.
`README.md` at the root and the `docs/` folder are the documentation. Version history is the Git log;
image tags map to commits (`<build>-<short sha>`).
