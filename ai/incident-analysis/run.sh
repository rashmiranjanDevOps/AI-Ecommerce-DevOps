#!/usr/bin/env bash
# Collect logs from a source and run the analyzer.
#   run.sh docker [--llm]            analyse the Docker Compose containers (last 30 min)
#   run.sh k8s    [--llm]            analyse pods, events and descriptions in the nexvion namespace
#   run.sh elk    [--llm]            analyse the last 30 minutes of errors stored in Elasticsearch
#   run.sh file <path> [--llm]       analyse a log file
# The report goes to reports/incident-<source>-<time>.md and a short version is printed.
set -euo pipefail
source "$(dirname "$0")/../../scripts/lib/common.sh"
cd "$REPO_ROOT"; mkdir -p reports
SRC="${1:?usage: run.sh {docker|k8s|elk|file <path>} [--llm]}"; shift || true
NS="${NAMESPACE:-nexvion}"
OUT="reports/incident-${SRC}-$(date +%Y%m%d-%H%M%S).md"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
LLM=(); [ "${*: -1:1}" = "--llm" ] && LLM=(--llm)

case "$SRC" in
  docker)
    require_cmd docker
    for c in nexvion-web nexvion-proxy nexvion-prometheus nexvion-grafana nexvion-elasticsearch nexvion-logstash nexvion-kibana; do
      docker logs --since 30m "$c" >>"$TMP" 2>&1 || true
    done
    python3 ai/incident-analysis/analyzer.py --file "$TMP" --source docker --format markdown --output "$OUT" ${LLM[@]+"${LLM[@]}"} ;;
  k8s)
    require_cmd kubectl
    {
      kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -100
      kubectl -n "$NS" describe pods 2>&1 | tail -300
      for p in $(kubectl -n "$NS" get pods -o name 2>/dev/null); do kubectl -n "$NS" logs --tail=300 --all-containers "$p" 2>&1; done
    } >"$TMP"
    python3 ai/incident-analysis/analyzer.py --file "$TMP" --source "kubernetes/$NS" --format markdown --output "$OUT" ${LLM[@]+"${LLM[@]}"} ;;
  elk)
    python3 ai/incident-analysis/analyzer.py --es-url "${ES_URL:-http://localhost:9200}" --minutes "${MINUTES:-30}" --format markdown --output "$OUT" ${LLM[@]+"${LLM[@]}"} ;;
  file)
    F="${1:?usage: run.sh file <path>}"
    python3 ai/incident-analysis/analyzer.py --file "$F" --format markdown --output "$OUT" ${LLM[@]+"${LLM[@]}"} ;;
  *) die "Unknown source: $SRC" ;;
esac
echo "----"; sed -n '1,25p' "$OUT"
