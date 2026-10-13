#!/usr/bin/env bash
# Health check for Nexvion. Exit code 0 = healthy, 1 = at least one check failed.
#
# Usage:
#   health-check.sh [--url http://localhost] [--retries 10] [--delay 5] [--max-time 3]
#                   [--compose] [--k8s] [--namespace nexvion] [--json]
#
#   --compose   also check the Docker containers (health status)
#   --k8s       also check the Kubernetes deployment and pods
#   --json      print the result as JSON (for dashboards / the AI analyzer)
set -uo pipefail
source "$(dirname "$0")/lib/common.sh"

URL="${HEALTH_URL:-http://localhost}"; RETRIES=1; DELAY=5; MAX_TIME=3; SLOW=2
DO_COMPOSE=0; DO_K8S=0; NS="nexvion"; JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="${2:?}"; shift 2 ;;
    --retries) RETRIES="${2:?}"; shift 2 ;;
    --delay) DELAY="${2:?}"; shift 2 ;;
    --max-time) MAX_TIME="${2:?}"; shift 2 ;;
    --compose) DO_COMPOSE=1; shift ;;
    --k8s) DO_K8S=1; shift ;;
    --namespace) NS="${2:?}"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
URL="${URL%/}"
require_cmd curl

RESULTS=()   # "name|status|detail"
FAILED=0
record() { RESULTS+=("$1|$2|$3"); [ "$2" = "FAIL" ] && FAILED=$((FAILED+1)); return 0; }

check_http() {   # name path expected_substring
  local name="$1" path="$2" needle="${3:-}" out code time body
  body="$(mktemp)"
  out="$(curl -s -o "$body" -w '%{http_code} %{time_total}' --max-time "$MAX_TIME" "$URL$path" 2>/dev/null)" || out="000 0"
  code="${out%% *}"; time="${out##* }"
  if [ "$code" != "200" ]; then record "$name" FAIL "HTTP $code"; rm -f "$body"; return; fi
  if [ -n "$needle" ] && ! grep -qi -- "$needle" "$body"; then record "$name" FAIL "HTTP 200 but body does not contain '$needle'"; rm -f "$body"; return; fi
  if awk -v t="$time" -v s="$SLOW" 'BEGIN{exit !(t>s)}'; then record "$name" WARN "HTTP 200 but slow (${time}s)"; else record "$name" PASS "HTTP 200 in ${time}s"; fi
  rm -f "$body"
}

run_checks() {
  RESULTS=(); FAILED=0
  check_http "health endpoint"  "/health" '"status":"ok"'
  check_http "home page"        "/"               "nexvion"
  check_http "products page"    "/products.html"  "nexvion"
  check_http "payment page"     "/payment.html"   "nexvion"
  check_http "stylesheet"       "/style.css"
  check_http "main script"      "/script.js"
  check_http "logo"             "/logo.png"

  local hdr
  hdr="$(curl -sI --max-time "$MAX_TIME" "$URL/" 2>/dev/null | tr -d '\r')"
  if echo "$hdr" | grep -qi '^x-content-type-options: *nosniff'; then record "security headers" PASS "X-Content-Type-Options present"
  else record "security headers" WARN "X-Content-Type-Options missing (a proxy may strip it)"; fi

  # Host resources (the machine this script runs on)
  local disk mem
  disk="$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')"
  if [ "${disk:-0}" -ge 90 ]; then record "disk usage /" FAIL "${disk}% used"; elif [ "${disk:-0}" -ge 80 ]; then record "disk usage /" WARN "${disk}% used"; else record "disk usage /" PASS "${disk}% used"; fi
  if [ -r /proc/meminfo ]; then
    mem="$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%d",(t-a)*100/t}' /proc/meminfo)"
    if [ "$mem" -ge 90 ]; then record "memory usage" WARN "${mem}% used"; else record "memory usage" PASS "${mem}% used"; fi
  fi

  if [ "$DO_COMPOSE" = 1 ]; then
    require_cmd docker
    local c st
    for c in nexvion-web nexvion-proxy; do
      st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo missing)"
      if [ "$st" = "healthy" ] || [ "$st" = "running" ]; then record "container $c" PASS "$st"; else record "container $c" FAIL "$st"; fi
    done
  fi

  if [ "$DO_K8S" = 1 ]; then
    require_cmd kubectl
    local want have notready
    want="$(kubectl -n "$NS" get deploy nexvion-web -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    have="$(kubectl -n "$NS" get deploy nexvion-web -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
    if [ -n "$want" ] && [ "${have:-0}" -ge "${want:-1}" ] && [ "${want:-0}" -gt 0 ]; then record "k8s deployment" PASS "${have}/${want} replicas available"; else record "k8s deployment" FAIL "${have:-0}/${want:-0} replicas available"; fi
    notready="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '{split($2,r,"/"); if (r[1] != r[2] || $3 != "Running") c++} END{print c+0}')"
    if [ "$notready" -eq 0 ]; then record "k8s pods" PASS "all pods ready"; else record "k8s pods" FAIL "$notready pod(s) not ready"; fi
  fi
}

attempt=1
while :; do
  run_checks
  [ "$FAILED" -eq 0 ] && break
  [ "$attempt" -ge "$RETRIES" ] && break
  log_warn "Attempt $attempt/$RETRIES: $FAILED check(s) failed, retrying in ${DELAY}s ..."
  attempt=$((attempt+1)); sleep "$DELAY"
done

if [ "$JSON" = 1 ]; then
  printf '%s\n' "${RESULTS[@]}" | python3 -c '
import json, sys
rows = [l.rstrip("\n").split("|", 2) for l in sys.stdin if l.strip()]
checks = [{"name": n, "status": s, "detail": d} for n, s, d in rows]
failed = sum(1 for c in checks if c["status"] == "FAIL")
print(json.dumps({"healthy": failed == 0, "failed": failed, "checks": checks}, indent=2))'
else
  printf '\n%-22s %-6s %s\n' CHECK STATUS DETAIL
  printf '%-22s %-6s %s\n' ---------------------- ------ ------
  for r in "${RESULTS[@]}"; do IFS='|' read -r n s d <<<"$r"; printf '%-22s %-6s %s\n' "$n" "$s" "$d"; done
  echo
fi

if [ "$FAILED" -eq 0 ]; then log_ok "Health check passed"; exit 0; fi
log_error "Health check FAILED ($FAILED check(s))"; exit 1
