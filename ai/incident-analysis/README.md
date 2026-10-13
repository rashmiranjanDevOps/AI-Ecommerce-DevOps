# AI-assisted incident analysis

Input: logs. Output, for every problem found: **error classification, severity, possible root cause,
suggested investigation, suggested remediation**, plus the evidence lines.

```
Application logs -> centralized logging (ELK) -> error / incident -> AI analysis -> insights
```

## Use

```bash
# From a file, stdin, a Jenkins console, or Elasticsearch
python3 ai/incident-analysis/analyzer.py --file ai/incident-analysis/samples/db-timeout.log
docker logs nexvion-proxy 2>&1 | python3 ai/incident-analysis/analyzer.py --stdin --format markdown
python3 ai/incident-analysis/analyzer.py --url "$BUILD_URL/consoleText"          # JENKINS_USER / JENKINS_TOKEN if needed
python3 ai/incident-analysis/analyzer.py --es-url http://localhost:9200 --minutes 30

# Collect and analyse in one step -> reports/incident-<source>-<time>.md
./ai/incident-analysis/run.sh docker        # Docker Compose containers
./ai/incident-analysis/run.sh k8s           # pods, events, describe (namespace nexvion)
./ai/incident-analysis/run.sh elk           # last 30 minutes of errors in Elasticsearch
./ai/incident-analysis/run.sh file build.log
```

Options: `--format text|markdown|json`, `--output FILE`, `--tail N`, `--fail-on high` (exit code 2 for CI gates),
`--rules extra.json`, `--llm`.

## Example (the case from the specification)

Input line: `SequelizeConnectionError: connect ETIMEDOUT 10.0.12.5:3306`

```
[1] Database connection timeout  (HIGH)
    Possible cause : Database connectivity or configuration issue.
    Investigate    : - Database availability  - Network connectivity  - Credentials  - Connection limits
```

## How it works

1. **Knowledge base** (`RULES` in `analyzer.py`): 24 patterns for the failures this platform can produce
   (database timeout, connection refused, 502/503/504, Nginx config errors, OOMKilled, image pull, crash loop,
   failing probes, disk full, permissions/RBAC, TLS, DNS, port in use, rate limiting, Docker build, Trivy and
   Gitleaks findings, test failures, Terraform lock and AWS errors, Ansible, Helm, Elasticsearch).
2. **Detectors** on the Nginx JSON access log: share of 5xx responses, slow responses (p95 > 2 s), 404 floods, 429s.
3. **Redaction**: passwords, tokens, AWS keys and webhook URLs are masked in all output and before anything is sent to an LLM.
4. **Optional LLM** (`--llm`): the findings (not the raw log) are sent to the Anthropic API for a 150-word assessment
   (most likely root cause, first three checks, rollback advice). Needs `ANTHROPIC_API_KEY`; model from `AI_MODEL`
   (default `claude-sonnet-5-5`). If the call fails the report is still produced.

The rule engine works offline and is deterministic, so it is testable. The LLM only adds a summary.

## Add your own rule

```json
[{"id": "payment_gateway", "name": "Payment gateway timeout", "severity": "high",
  "patterns": ["gateway\\.example\\.com.*timeout"],
  "cause": "The payment provider did not answer in time.",
  "investigate": ["Provider status page", "Egress rules"], "remediate": ["Retry with backoff"]}]
```
`python3 analyzer.py --file app.log --rules my-rules.json`

## Tests
`python3 -m unittest discover -s ai/incident-analysis/tests -v` (10 tests, also run by `scripts/test.sh`).
