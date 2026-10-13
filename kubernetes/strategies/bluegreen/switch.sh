#!/usr/bin/env bash
# Blue-green release helper.
#   switch.sh deploy <image>   deploy <image> as GREEN and wait until it is ready (no live traffic yet)
#   switch.sh promote          send live traffic to GREEN (health-checked first)
#   switch.sh rollback         send live traffic back to BLUE
#   switch.sh finalize         after BLUE has been updated to the new version: point traffic to BLUE, remove GREEN
#   switch.sh status           show which colour is live
set -euo pipefail
NS="${NAMESPACE:-nexvion}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

live() { kubectl -n "$NS" get svc nexvion-web -o jsonpath='{.spec.selector.color}'; }
point_to() {
  kubectl -n "$NS" patch svc nexvion-web --type merge \
    -p "{\"spec\":{\"selector\":{\"color\":\"$1\"}}}" >/dev/null
  echo "Live traffic now goes to: $1"
}

case "${1:-status}" in
  deploy)
    IMAGE="${2:?usage: switch.sh deploy <image>}"
    sed "s#image: nexvion-web:latest#image: ${IMAGE}#" "$DIR/deployment-green.yaml" | kubectl apply -f -
    kubectl apply -f "$DIR/service-green-preview.yaml"
    kubectl -n "$NS" rollout status deployment/nexvion-web-green --timeout=180s
    echo "Green is ready. Test it, then run: $0 promote"
    ;;
  promote)
    kubectl -n "$NS" rollout status deployment/nexvion-web-green --timeout=60s
    READY=$(kubectl -n "$NS" get deploy nexvion-web-green -o jsonpath='{.status.readyReplicas}')
    [ "${READY:-0}" -ge 1 ] || { echo "Green has no ready pods - not switching" >&2; exit 1; }
    point_to green
    ;;
  rollback)
    point_to blue
    ;;
  finalize)
    kubectl -n "$NS" rollout status deployment/nexvion-web --timeout=300s
    point_to blue
    kubectl -n "$NS" delete deployment nexvion-web-green --ignore-not-found
    kubectl -n "$NS" delete service nexvion-web-green-preview --ignore-not-found
    echo "Blue-green release finished: blue runs the new version, green removed."
    ;;
  status)
    echo "Live colour: $(live)"
    kubectl -n "$NS" get deploy -l app.kubernetes.io/name=ecommerce -L color
    ;;
  *) echo "usage: $0 {deploy <image>|promote|rollback|finalize|status}" >&2; exit 2 ;;
esac
