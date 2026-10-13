#!/usr/bin/env bash
# Canary release helper (AWS ALB weighted routing).
#   canary.sh start <image> [weight]   deploy <image> as canary and send [weight]% (default 10) of traffic to it
#   canary.sh weight <percent>         change the share of traffic (e.g. 10 -> 50)
#   canary.sh promote <image>          make <image> the stable version (rolling update), then remove the canary
#   canary.sh abort                    send all traffic back to stable and remove the canary
#
# How it works: the main Ingress "nexvion-web" normally points at Service nexvion-web. While a canary runs, its
# backend is switched to an ALB "forward" action that splits traffic between nexvion-web and nexvion-web-canary.
set -euo pipefail
NS="${NAMESPACE:-nexvion}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANNOTATION="alb.ingress.kubernetes.io/actions.weighted-routing"

set_weight() {
  local canary="$1" stable=$((100 - $1))
  local action
  action=$(printf '{"type":"forward","forwardConfig":{"targetGroups":[{"serviceName":"nexvion-web","servicePort":"80","weight":%s},{"serviceName":"nexvion-web-canary","servicePort":"80","weight":%s}]}}' "$stable" "$canary")
  kubectl -n "$NS" annotate ingress nexvion-web "${ANNOTATION}=${action}" --overwrite >/dev/null
  kubectl -n "$NS" patch ingress nexvion-web --type=json -p \
    '[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend","value":{"service":{"name":"weighted-routing","port":{"name":"use-annotation"}}}}]' >/dev/null
  echo "Traffic split: stable ${stable}% / canary ${canary}%  (the ALB needs about 30-60 seconds to apply it)"
}

restore_stable() {
  kubectl -n "$NS" patch ingress nexvion-web --type=json -p \
    '[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend","value":{"service":{"name":"nexvion-web","port":{"name":"http"}}}}]' >/dev/null
  kubectl -n "$NS" annotate ingress nexvion-web "${ANNOTATION}-" >/dev/null 2>&1 || true
}

remove_canary() {
  restore_stable
  kubectl -n "$NS" delete -f "$DIR/canary.yaml" --ignore-not-found
}

case "${1:-}" in
  start)
    IMAGE="${2:?usage: canary.sh start <image> [weight]}"
    sed "s#image: nexvion-web:latest#image: ${IMAGE}#" "$DIR/canary.yaml" | kubectl apply -f -
    kubectl -n "$NS" rollout status deployment/nexvion-web-canary --timeout=180s
    set_weight "${3:-10}"
    ;;
  weight)
    set_weight "${2:?usage: canary.sh weight <percent>}"
    ;;
  promote)
    IMAGE="${2:?usage: canary.sh promote <image>}"
    kubectl -n "$NS" set image deployment/nexvion-web web="$IMAGE"
    kubectl -n "$NS" rollout status deployment/nexvion-web --timeout=300s
    remove_canary
    echo "Stable version is now $IMAGE"
    ;;
  abort)
    remove_canary
    echo "Canary removed. All traffic goes to the stable version."
    ;;
  *) echo "usage: $0 {start <image> [weight]|weight <percent>|promote <image>|abort}" >&2; exit 2 ;;
esac
