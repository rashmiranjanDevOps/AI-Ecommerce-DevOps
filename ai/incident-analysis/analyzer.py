#!/usr/bin/env python3
"""AI-assisted incident and log analysis for the Nexvion platform.

Reads logs (file, stdin, a Jenkins console URL, or Elasticsearch) and produces, for every problem found:
    error classification | severity | possible root cause | suggested investigation | suggested remediation

How it works
  1. A built-in knowledge base of 24 DevOps failure patterns classifies the log lines (works offline).
  2. Detectors look at Nginx JSON access logs for 5xx spikes, slow responses and 404 floods.
  3. Optional --llm: the findings (secrets redacted) are sent to an LLM for a short written assessment.
     Needs ANTHROPIC_API_KEY. If the call fails the rule-based report is still produced.

Examples
  python3 analyzer.py --file samples/db-timeout.log
  docker logs nexvion-proxy 2>&1 | python3 analyzer.py --stdin --format markdown
  python3 analyzer.py --es-url http://localhost:9200 --minutes 30 --llm
  python3 analyzer.py --file reports/pipeline.log --output reports/incident-report.md --format markdown
"""
import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request
from collections import Counter
from datetime import datetime, timezone

SEVERITY_ORDER = {"critical": 4, "high": 3, "medium": 2, "low": 1, "info": 0}

# ---------------------------------------------------------------------------------------------
# Knowledge base. Each rule: id, name (error class), severity, patterns (regex, case-insensitive),
# cause, investigate (list), remediate (list).
# ---------------------------------------------------------------------------------------------
RULES = [
    {"id": "db_timeout", "name": "Database connection timeout", "severity": "high",
     "patterns": [r"SequelizeConnectionError", r"(ETIMEDOUT|timed? ?out).{0,60}(3306|5432|mysql|postgres|database|\bdb\b)",
                  r"(mysql|postgres|database|\bdb\b).{0,60}(timed? ?out|ETIMEDOUT)", r"Lost connection to MySQL",
                  r"could not connect to server", r"too many connections", r"database connection (timed out|refused)"],
     "cause": "Database connectivity or configuration issue.",
     "investigate": ["Database availability (is the instance running and healthy?)",
                     "Network connectivity (security groups, routes, DNS between app and database)",
                     "Credentials (user, password, host and port in the secret / environment)",
                     "Connection limits (max_connections, pool size, leaked connections)"],
     "remediate": ["Restore or restart the database if it is down", "Open the DB port from the application security group",
                   "Correct the credentials/secret and restart the pods", "Raise max_connections or tune the connection pool"]},
    {"id": "conn_refused", "name": "Connection refused", "severity": "high",
     "patterns": [r"connection refused", r"ECONNREFUSED", r"connect\(\) failed \(111"],
     "cause": "The target service is not listening on that address/port (crashed, not started yet, wrong port).",
     "investigate": ["Is the target container/pod running? (docker ps / kubectl get pods)", "Does the service name and port match the configuration?",
                     "Did the target fail its health check or restart recently?"],
     "remediate": ["Start or restart the target service", "Fix the host/port in the configuration", "Add a readiness probe so traffic waits for the service"]},
    {"id": "upstream_timeout", "name": "Upstream timeout (504)", "severity": "high",
     "patterns": [r"upstream timed out", r"\b504\b.{0,30}gateway", r"gateway time-?out"],
     "cause": "The proxy waited too long for the backend. The backend is overloaded, hung or unreachable.",
     "investigate": ["CPU/memory of the upstream container (Grafana)", "Recent deployments or restarts", "proxy_read_timeout and upstream response times in the access log"],
     "remediate": ["Scale out the upstream (more replicas)", "Fix or roll back the slow release (scripts/deploy.sh rollback)", "Tune proxy timeouts only after finding the cause"]},
    {"id": "bad_gateway", "name": "Bad gateway / no healthy upstream (502/503)", "severity": "high",
     "patterns": [r"no live upstreams", r"upstream prematurely closed", r"\b502\b.{0,30}bad gateway", r"connect\(\) failed .{0,40}while connecting to upstream", r"\b503\b.{0,30}service (temporarily )?unavailable"],
     "cause": "The proxy has no healthy backend to send requests to.",
     "investigate": ["Are all web pods/containers Ready?", "Service selector and endpoints (kubectl get endpoints nexvion-web)", "Readiness probe failures"],
     "remediate": ["Restart or roll back the web deployment", "Fix the service selector / port name", "Check the last config change (nginx -t, ConfigMap)"]},
    {"id": "nginx_config", "name": "Nginx configuration error", "severity": "high",
     "patterns": [r"nginx: \[emerg\]", r"directive is not allowed here", r"unknown directive", r"duplicate (location|upstream|server)", r"invalid number of arguments in"],
     "cause": "The Nginx configuration is invalid, so Nginx cannot start or reload.",
     "investigate": ["Run nginx -t in the container", "Diff the last change to docker/nginx/default.conf", "Check that the ConfigMap matches docker/nginx/default.conf (scripts/test.sh)"],
     "remediate": ["Revert the config change", "Fix the syntax, run scripts/sync-config.sh, redeploy"]},
    {"id": "oom", "name": "Out of memory (OOMKilled)", "severity": "critical",
     "patterns": [r"OOMKilled", r"Out of memory", r"oom-?kill", r"Killed process \d+", r"Cannot allocate memory"],
     "cause": "A container used more memory than its limit, or the host ran out of memory.",
     "investigate": ["Memory usage and limits per pod (Grafana: memory panels)", "kubectl describe pod (Last State: OOMKilled)", "Memory growth after the last release"],
     "remediate": ["Raise the memory limit/request", "Fix the memory leak or heavy workload", "Add replicas / enable HPA"]},
    {"id": "image_pull", "name": "Image pull failure", "severity": "high",
     "patterns": [r"ImagePullBackOff", r"ErrImagePull", r"pull access denied", r"manifest unknown", r"no basic auth credentials", r"repository does not exist"],
     "cause": "The node cannot download the container image (wrong tag, missing image, or no registry permission).",
     "investigate": ["Does the tag exist in ECR? (aws ecr describe-images)", "Node IAM role has ecr:BatchGetImage / GetDownloadUrlForLayer", "Typo in image repository or tag in Helm values"],
     "remediate": ["Push the missing image or correct the tag", "Grant the node role ECR read access", "Re-run the pipeline"]},
    {"id": "crashloop", "name": "Container crash loop", "severity": "high",
     "patterns": [r"CrashLoopBackOff", r"Back-off restarting failed container"],
     "cause": "The container starts and exits repeatedly (bad config, missing file, failing command).",
     "investigate": ["kubectl logs <pod> --previous", "kubectl describe pod (exit code and events)", "Last change: image tag, ConfigMap, Secret"],
     "remediate": ["Roll back to the previous release", "Fix the configuration that makes the process exit"]},
    {"id": "probe_failed", "name": "Health probe failing", "severity": "medium",
     "patterns": [r"(Readiness|Liveness|Startup) probe failed", r"\bUnhealthy\b.{0,40}probe"],
     "cause": "The application does not answer /health in time, so Kubernetes marks it not ready or restarts it.",
     "investigate": ["Does GET /health return 200 from inside the pod?", "Probe timeouts versus real startup time", "CPU throttling (limits too low)"],
     "remediate": ["Fix the failing endpoint", "Increase probe timeouts or startup probe", "Raise CPU limits"]},
    {"id": "disk_full", "name": "Disk full", "severity": "critical",
     "patterns": [r"No space left on device", r"DiskPressure", r"disk watermark.{0,40}(exceeded|flood)", r"write error: no space"],
     "cause": "A volume or the node root disk is full (logs, images, Elasticsearch data).",
     "investigate": ["df -h and docker system df", "Largest directories (/var/lib/docker, /var/log)", "Elasticsearch index size and retention policy"],
     "remediate": ["Run scripts/cleanup.sh --deep", "Rotate/compress logs, shorten ILM retention", "Increase the volume size"]},
    {"id": "permission", "name": "Permission denied / access forbidden", "severity": "medium",
     "patterns": [r"Permission denied", r"\bEACCES\b", r"AccessDenied", r"is not authorized to perform", r"Forbidden", r"cannot (get|list|create|patch|delete) resource"],
     "cause": "The user, role or service account lacks the required permission.",
     "investigate": ["Which identity is used (aws sts get-caller-identity, kubectl auth whoami)", "IAM policy / RBAC Role for that identity", "File ownership and mode (non-root container, read-only filesystem)"],
     "remediate": ["Grant the minimum missing permission (do not use admin)", "Fix file ownership or mount a writable emptyDir"]},
    {"id": "tls", "name": "TLS / certificate problem", "severity": "high",
     "patterns": [r"certificate has expired", r"x509:", r"SSL_ERROR", r"unable to verify the first certificate", r"tls: .{0,30}(bad certificate|handshake)"],
     "cause": "A certificate is expired, not trusted or does not match the host name.",
     "investigate": ["Certificate expiry date and the host names it covers", "Ingress TLS secret / ACM certificate status", "System clock on the client"],
     "remediate": ["Renew or re-issue the certificate", "Update the TLS secret and reload the ingress"]},
    {"id": "dns", "name": "DNS resolution failure", "severity": "high",
     "patterns": [r"Name or service not known", r"no such host", r"EAI_AGAIN", r"ENOTFOUND", r"Temporary failure in name resolution"],
     "cause": "A host name cannot be resolved (typo, missing record, DNS server unreachable).",
     "investigate": ["dig/nslookup for the name from the same host/pod", "CoreDNS pods and /etc/resolv.conf", "Route 53 record exists and points to the load balancer"],
     "remediate": ["Create or correct the DNS record", "Restart CoreDNS if it is unhealthy"]},
    {"id": "port_in_use", "name": "Port already in use", "severity": "medium",
     "patterns": [r"address already in use", r"port is already allocated", r"bind\(\) to .{0,40} failed"],
     "cause": "Another process or container already uses that port.",
     "investigate": ["ss -tlnp | grep <port>", "docker ps for other containers publishing the port"],
     "remediate": ["Stop the other process", "Change the published port (PROXY_PORT / WEB_PORT in docker/.env)"]},
    {"id": "rate_limited", "name": "Requests rate-limited (429)", "severity": "medium",
     "patterns": [r"limiting requests, excess", r"\b429\b.{0,30}too many requests"],
     "cause": "Clients exceed the proxy rate limit (traffic spike, bot or load test).",
     "investigate": ["Top client IPs in the access log (Kibana)", "Is it a legitimate traffic increase?"],
     "remediate": ["Block abusive IPs", "Raise the limit only if the traffic is legitimate", "Scale out"]},
    {"id": "docker_build", "name": "Docker build failure", "severity": "medium",
     "patterns": [r"failed to solve", r"executor failed running", r"returned a non-zero code", r"npm ERR!", r"COPY failed"],
     "cause": "A Docker build step failed (missing file, bad command, network, or .dockerignore excluding a needed file).",
     "investigate": ["The failing step in the build output", "Is the build context correct (repo root) and not ignored by .dockerignore?", "Network access for package downloads"],
     "remediate": ["Fix the Dockerfile step or the missing file", "Re-run docker build with --no-cache to rule out cache problems"]},
    {"id": "vuln_found", "name": "Vulnerabilities found by Trivy", "severity": "high",
     "patterns": [r"Total: [1-9]\d* \((?:[A-Z]+: \d+, )*(HIGH|CRITICAL): [1-9]\d*", r"CVE-\d{4}-\d{4,}.{0,80}(HIGH|CRITICAL)"],
     "cause": "The image or repository contains a known HIGH/CRITICAL vulnerability, so the security gate stopped the pipeline.",
     "investigate": ["The package and fixed version in reports/trivy-image.txt", "Is the base image outdated?"],
     "remediate": ["Update the base image tag and rebuild (apk upgrade)", "Upgrade the vulnerable package", "If it is a false positive, add it to security/.trivyignore with a reason and review date"]},
    {"id": "secret_found", "name": "Secret detected in code", "severity": "critical",
     "patterns": [r"leaks found: [1-9]", r"\bRuleID\b", r"Finding:.{0,40}(REDACTED|key|token|secret)"],
     "cause": "A credential was committed to the repository.",
     "investigate": ["File and commit named in reports/gitleaks.json", "Was the credential real and is it already pushed?"],
     "remediate": ["Revoke and rotate the credential immediately", "Remove it from history (git filter-repo) and use Secrets Manager / Kubernetes Secrets"]},
    {"id": "test_failed", "name": "Test or lint failure", "severity": "medium",
     "patterns": [r"\bFAIL\b\s", r"AssertionError", r"Tests?:.{0,20}\d+ failed", r"^\s*\d+ problems? \(", r"\[ERROR\] .*(lint|test)", r"Traceback \(most recent call last\)"],
     "cause": "A test, lint rule or static check failed.",
     "investigate": ["The first failing test or lint message", "The commit that introduced it (git log -p)"],
     "remediate": ["Fix the code or the test", "Re-run scripts/test.sh locally before pushing"]},
    {"id": "terraform_lock", "name": "Terraform state lock", "severity": "medium",
     "patterns": [r"Error acquiring the state lock", r"ConditionalCheckFailedException"],
     "cause": "Another terraform run holds the state lock (or a previous run was interrupted).",
     "investigate": ["Is another apply running?", "Lock ID and owner in the error message"],
     "remediate": ["Wait for the other run to finish", "terraform force-unlock <ID> only when you are sure no run is active"]},
    {"id": "terraform_aws", "name": "Terraform / AWS API error", "severity": "high",
     "patterns": [r"Error: (creating|deleting|reading|updating|waiting)", r"UnauthorizedOperation", r"LimitExceeded", r"InvalidParameter(Value)?", r"VcpuLimitExceeded", r"AlreadyExists"],
     "cause": "AWS rejected a request: missing permission, quota, invalid value or a resource that already exists.",
     "investigate": ["The full error text with the resource address", "IAM permissions of the identity running terraform", "Service quotas in the region"],
     "remediate": ["Fix the variable or permission", "Request a quota increase", "Import the existing resource into the state (terraform import)"]},
    {"id": "ansible_failed", "name": "Ansible task failure / host unreachable", "severity": "high",
     "patterns": [r"fatal: \[", r"UNREACHABLE!", r"FAILED! =>", r"Permission denied \(publickey"],
     "cause": "A configuration task failed, or the server cannot be reached over SSH.",
     "investigate": ["Security group allows SSH from this machine", "Correct key file and user in the inventory", "The failing task and its module error"],
     "remediate": ["Fix SSH access (key, user, CIDR)", "Re-run the playbook; tasks are idempotent"]},
    {"id": "helm_failed", "name": "Helm / rollout failure", "severity": "high",
     "patterns": [r"UPGRADE FAILED", r"INSTALLATION FAILED", r"timed out waiting for the condition", r"exceeded its progress deadline", r"rollout .{0,40}(timed out|failed)"],
     "cause": "The new release did not become ready in time; --atomic rolls it back automatically.",
     "investigate": ["kubectl get pods and describe the new pods", "Pod logs and events (image pull, probes, resources)", "helm history nexvion"],
     "remediate": ["Fix the cause shown in the pod events and redeploy", "scripts/deploy.sh rollback helm"]},
    {"id": "es_problem", "name": "Elasticsearch problem", "severity": "high",
     "patterns": [r"ClusterBlockException", r"circuit_breaking_exception", r"vm\.max_map_count", r"max virtual memory areas", r"cluster_block_exception", r"read-only-allow-delete"],
     "cause": "Elasticsearch cannot start or has blocked writes (kernel setting, memory, or disk watermark).",
     "investigate": ["sysctl vm.max_map_count (needs 262144)", "Disk usage on the data volume", "JVM heap and memory limit"],
     "remediate": ["Run scripts/setup.sh (sets vm.max_map_count)", "Free disk space, then clear the read-only block", "Increase memory"]},
]

SECRET_PATTERNS = [
    (re.compile(r"AKIA[0-9A-Z]{16}"), "[REDACTED-AWS-KEY]"),
    (re.compile(r"(?i)(aws_secret_access_key|secret[_-]?key)\s*[=:]\s*\S+"), r"\1=[REDACTED]"),
    (re.compile(r"(?i)(password|passwd|pwd|token|api[_-]?key|authorization)\s*[=:]\s*\S+"), r"\1=[REDACTED]"),
    (re.compile(r"(?i)bearer\s+[A-Za-z0-9._\-]{16,}"), "Bearer [REDACTED]"),
    (re.compile(r"sk-[A-Za-z0-9_\-]{20,}"), "[REDACTED-API-KEY]"),
    (re.compile(r"hooks\.slack\.com/services/\S+"), "hooks.slack.com/services/[REDACTED]"),
]


def redact(text):
    for rx, repl in SECRET_PATTERNS:
        text = rx.sub(repl, text)
    return text


# ---------------------------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------------------------
def read_files(paths):
    lines = []
    for p in paths:
        with open(p, "r", errors="replace") as fh:
            lines.extend(fh.read().splitlines())
    return lines


def fetch_url(url):
    req = urllib.request.Request(url)
    user, token = os.environ.get("JENKINS_USER"), os.environ.get("JENKINS_TOKEN")
    if user and token:
        req.add_header("Authorization", "Basic " + base64.b64encode(f"{user}:{token}".encode()).decode())
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace").splitlines()


def fetch_elasticsearch(es_url, index, minutes, size=2000):
    """Pull recent error-looking events (HTTP >= 500 or error words) from Elasticsearch."""
    body = {
        "size": size, "sort": [{"@timestamp": "desc"}],
        "query": {"bool": {"filter": [{"range": {"@timestamp": {"gte": f"now-{minutes}m"}}}],
                           "should": [{"range": {"nginx.status": {"gte": 500}}},
                                      {"query_string": {"query": "message:(error OR exception OR fail* OR timeout OR refused OR denied)"}}],
                           "minimum_should_match": 1}},
    }
    req = urllib.request.Request(f"{es_url.rstrip('/')}/{index}/_search", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        hits = json.load(r)["hits"]["hits"]
    out = []
    for h in hits:
        src = h.get("_source", {})
        out.append(json.dumps(src["nginx"]) if isinstance(src.get("nginx"), dict) else str(src.get("message", "")))
    return out


# ---------------------------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------------------------
def compile_rules(rules):
    comp = []
    for r in rules:
        comp.append((r, [re.compile(p, re.IGNORECASE) for p in r["patterns"]]))
    return comp


def access_log_findings(lines):
    """Look at Nginx JSON access-log lines for 5xx spikes, slow responses and 404 floods."""
    entries = []
    for line in lines:
        s = line.strip()
        if not (s.startswith("{") and '"status"' in s):
            continue
        try:
            d = json.loads(s)
        except ValueError:
            continue
        if isinstance(d, dict) and "status" in d:
            entries.append(d)
    findings = []
    total = len(entries)
    if total < 5:
        return findings, total
    st = [int(e.get("status", 0)) for e in entries]
    n5, n404, n429 = sum(1 for s in st if s >= 500), sum(1 for s in st if s == 404), sum(1 for s in st if s == 429)
    times = sorted(float(e.get("request_time", 0) or 0) for e in entries)
    p95 = times[int(0.95 * (len(times) - 1))] if times else 0

    def add(rid, name, sev, count, cause, inv, rem, ev):
        findings.append({"id": rid, "name": name, "severity": sev, "count": count, "cause": cause,
                         "investigate": inv, "remediate": rem, "evidence": ev})

    if n5 / total >= 0.05:
        bad = Counter(e.get("request_uri", "?") for e in entries if int(e.get("status", 0)) >= 500)
        add("http_5xx", "High rate of server errors (HTTP 5xx)", "critical" if n5 / total >= 0.2 else "high", n5,
            f"{n5} of {total} requests ({n5 * 100 // total}%) returned 5xx. The web or upstream container is failing.",
            ["Top failing URLs: " + ", ".join(f"{u} x{c}" for u, c in bad.most_common(3)),
             "Container/pod health and restarts around the same time", "The last deployment (roll back if it started then)"],
            ["scripts/deploy.sh rollback helm (or k8s)", "Fix the failing component and redeploy"],
            [json.dumps(e) for e in entries if int(e.get("status", 0)) >= 500][:3])
    if p95 > 2.0:
        add("slow_responses", "Slow responses", "medium", sum(1 for t in times if t > 2.0),
            f"95th percentile response time is {p95:.2f}s (limit 2s). Likely CPU throttling, overload or a slow upstream.",
            ["CPU/memory per pod in Grafana", "Upstream response time field in the proxy log"], ["Scale out or raise limits", "Investigate the slow dependency"], [])
    if n404 / total >= 0.3:
        bad = Counter(e.get("request_uri", "?") for e in entries if int(e.get("status", 0)) == 404)
        add("http_404", "Many 'not found' responses (404)", "low", n404,
            f"{n404 * 100 // total}% of requests returned 404: broken links, missing assets after a deploy, or vulnerability scanners.",
            ["Most requested missing URLs: " + ", ".join(f"{u} x{c}" for u, c in bad.most_common(3)),
             "Does the missing file exist in the image? (scripts/check_assets.py)"], ["Fix links or restore the asset", "Block scanner IPs if the paths look like probes (/wp-admin, /.env)"], [])
    if n429:
        add("http_429", "Requests being rate-limited (429)", "medium", n429, "Clients exceeded the rate limit.",
            ["Top client IPs (remote_addr)"], ["Block abusive IPs or raise the limit if the traffic is legitimate"], [])
    return findings, total


def analyze(lines, source="unknown", rules=None, tail=None):
    if tail and len(lines) > tail:
        lines = lines[-tail:]
    comp = compile_rules(rules or RULES)
    findings = []
    for rule, rxs in comp:
        hits = [ln for ln in lines if any(rx.search(ln) for rx in rxs)]
        if hits:
            findings.append({"id": rule["id"], "name": rule["name"], "severity": rule["severity"], "count": len(hits),
                             "cause": rule["cause"], "investigate": rule["investigate"], "remediate": rule["remediate"],
                             "evidence": [redact(h.strip())[:300] for h in hits[:3]]})
    extra, access_total = access_log_findings(lines)
    for f in extra:
        f["evidence"] = [redact(e)[:300] for e in f["evidence"]]
    findings.extend(extra)
    findings.sort(key=lambda f: (-SEVERITY_ORDER[f["severity"]], -f["count"]))
    overall = findings[0]["severity"] if findings else "info"
    return {
        "source": source,
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ"),
        "lines_analyzed": len(lines),
        "access_log_entries": access_total,
        "overall_severity": overall,
        "findings": findings,
        "summary": (f"{len(findings)} problem type(s) found; highest severity: {overall.upper()}. Most important: {findings[0]['name']}."
                    if findings else "No known error patterns found in the analyzed logs."),
    }


# ---------------------------------------------------------------------------------------------
# Optional LLM enrichment
# ---------------------------------------------------------------------------------------------
def llm_assessment(report):
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        return None, "ANTHROPIC_API_KEY is not set - skipping the LLM step"
    compact = [{"error": f["name"], "severity": f["severity"], "count": f["count"], "evidence": f["evidence"]} for f in report["findings"][:8]]
    prompt = ("You are a senior DevOps engineer. Below are findings from an automated log analysis of an e-commerce platform "
              "(Nginx, Docker, Kubernetes on AWS EKS, Jenkins, Terraform). In at most 150 words: state the most likely single root "
              "cause, the first three checks to run, and whether a rollback is advisable. Do not invent facts that are not in the data.\n\n"
              + redact(json.dumps(compact, indent=1))[:6000])
    payload = {"model": os.environ.get("AI_MODEL", "claude-sonnet-5-5"), "max_tokens": 500,
               "messages": [{"role": "user", "content": prompt}]}
    req = urllib.request.Request(os.environ.get("AI_API_URL", "https://api.anthropic.com/v1/messages"),
                                 data=json.dumps(payload).encode(),
                                 headers={"content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01"})
    try:
        with urllib.request.urlopen(req, timeout=45) as r:
            data = json.load(r)
        return "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text").strip(), None
    except (urllib.error.URLError, ValueError, TimeoutError) as exc:
        return None, f"LLM call failed ({exc}); rule-based report only"


# ---------------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------------
def render_text(rep):
    out = [f"INCIDENT ANALYSIS  source={rep['source']}  lines={rep['lines_analyzed']}  overall={rep['overall_severity'].upper()}",
           rep["summary"], ""]
    for i, f in enumerate(rep["findings"], 1):
        out += [f"[{i}] {f['name']}  ({f['severity'].upper()}, {f['count']} occurrence(s))",
                f"    Possible cause : {f['cause']}", "    Investigate    :"]
        out += [f"      - {x}" for x in f["investigate"]]
        out += ["    Remediation    :"] + [f"      - {x}" for x in f["remediate"]]
        if f["evidence"]:
            out += ["    Evidence       :"] + [f"      > {e}" for e in f["evidence"]]
        out.append("")
    if rep.get("ai_assessment"):
        out += ["AI ASSESSMENT", rep["ai_assessment"], ""]
    if rep.get("ai_note"):
        out.append(f"(note: {rep['ai_note']})")
    return "\n".join(out)


def render_markdown(rep):
    out = ["# Incident analysis report", "",
           f"- **Source:** {rep['source']}", f"- **Generated:** {rep['generated']}",
           f"- **Lines analysed:** {rep['lines_analyzed']}", f"- **Overall severity:** {rep['overall_severity'].upper()}", "",
           "## Summary", "", rep["summary"], ""]
    if rep["findings"]:
        out += ["## Findings", ""]
    for i, f in enumerate(rep["findings"], 1):
        out += [f"### {i}. {f['name']} - {f['severity'].upper()} ({f['count']} occurrence(s))", "",
                f"**Possible root cause:** {f['cause']}", "", "**Suggested investigation**", ""]
        out += [f"- {x}" for x in f["investigate"]]
        out += ["", "**Suggested remediation**", ""] + [f"- {x}" for x in f["remediate"]]
        if f["evidence"]:
            out += ["", "**Evidence**", "", "```"] + f["evidence"] + ["```"]
        out.append("")
    if rep.get("ai_assessment"):
        out += ["## AI assessment", "", rep["ai_assessment"], ""]
    if rep.get("ai_note"):
        out += [f"_Note: {rep['ai_note']}_", ""]
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description="AI-assisted DevOps incident and log analysis")
    ap.add_argument("--file", action="append", help="log file (can be repeated)")
    ap.add_argument("--stdin", action="store_true", help="read the log from standard input")
    ap.add_argument("--url", help="URL of a text log, e.g. a Jenkins consoleText (uses JENKINS_USER/JENKINS_TOKEN if set)")
    ap.add_argument("--es-url", help="Elasticsearch URL to pull recent error events from")
    ap.add_argument("--es-index", default="nexvion-logs-*")
    ap.add_argument("--minutes", type=int, default=30, help="time window for --es-url (default 30)")
    ap.add_argument("--source", default=None, help="label shown in the report")
    ap.add_argument("--tail", type=int, default=20000, help="analyse only the last N lines (default 20000)")
    ap.add_argument("--format", choices=["text", "markdown", "json"], default="text")
    ap.add_argument("--output", help="write the report to this file instead of stdout")
    ap.add_argument("--llm", action="store_true", help="add an LLM-written assessment (needs ANTHROPIC_API_KEY)")
    ap.add_argument("--rules", help="JSON file with extra rules (same fields as the built-in ones)")
    ap.add_argument("--fail-on", choices=["critical", "high", "medium", "low"], help="exit with code 2 if a finding has at least this severity")
    a = ap.parse_args(argv)

    lines, label = [], a.source
    try:
        if a.file:
            lines += read_files(a.file); label = label or ",".join(a.file)
        if a.stdin:
            lines += sys.stdin.read().splitlines(); label = label or "stdin"
        if a.url:
            lines += fetch_url(a.url); label = label or a.url
        if a.es_url:
            lines += fetch_elasticsearch(a.es_url, a.es_index, a.minutes); label = label or f"elasticsearch ({a.minutes} min)"
    except (OSError, urllib.error.URLError, ValueError) as exc:
        print(f"error: could not read input: {exc}", file=sys.stderr)
        return 1
    if not lines and not (a.file or a.stdin or a.url or a.es_url):
        ap.print_help(sys.stderr)
        return 1

    rules = list(RULES)
    if a.rules:
        with open(a.rules) as fh:
            rules += json.load(fh)
    rep = analyze(lines, label or "unknown", rules, a.tail)

    if a.llm:
        text, note = llm_assessment(rep)
        if text:
            rep["ai_assessment"] = text
        if note:
            rep["ai_note"] = note

    rendered = json.dumps(rep, indent=2) if a.format == "json" else (render_markdown(rep) if a.format == "markdown" else render_text(rep))
    if a.output:
        os.makedirs(os.path.dirname(os.path.abspath(a.output)), exist_ok=True)
        with open(a.output, "w") as fh:
            fh.write(rendered + "\n")
        print(f"report written to {a.output} ({rep['overall_severity'].upper()}: {rep['summary']})")
    else:
        print(rendered)

    if a.fail_on and rep["findings"] and SEVERITY_ORDER[rep["overall_severity"]] >= SEVERITY_ORDER[a.fail_on]:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
