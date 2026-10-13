#!/usr/bin/env bash
# Deployment helper for Nexvion.
#
#   deploy.sh build   [--tag T] [--registry R]              build the Docker image
#   deploy.sh push    --registry R [--tag T] [--region RG]  push to a registry (ECR login when R is an ECR host)
#   deploy.sh compose [up|down|restart|logs|ps] [--monitoring] [--logging] [--tag T]
#   deploy.sh addons                                         install AWS Load Balancer Controller, metrics-server, kube-prometheus-stack
#   deploy.sh elk                                            install the ELK stack in the cluster
#   deploy.sh k8s     --image IMAGE [--basic-auth user:pass] deploy the plain manifests (rolling update)
#   deploy.sh helm    --image-repo REPO --tag T [--env dev|prod] [--set k=v ...]
#   deploy.sh ingress-host                                   wait for and print the ALB address of the site
#   deploy.sh bluegreen {deploy IMAGE|promote|rollback|finalize|status}
#   deploy.sh canary    {start IMAGE [WEIGHT]|weight N|promote IMAGE|abort}
#   deploy.sh rollback  {k8s|helm}                           undo the last release
#
# Rolling update is the default strategy of "k8s" and "helm". Blue-green and canary are separate commands.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
LOG_FILE="${LOG_FILE:-$REPO_ROOT/logs/deploy.log}"
NS="${NAMESPACE:-nexvion}"
cd "$REPO_ROOT"

usage() { sed -n '2,21p' "$0"; exit "${1:-0}"; }
[ $# -ge 1 ] || usage 1
CMD="$1"; shift

TAG="${IMAGE_TAG:-$(short_sha)}"; REGISTRY="${REGISTRY:-local}"; IMAGE=""; IMAGE_REPO=""; ENVIRONMENT="dev"
REGION="${AWS_REGION:-ap-south-1}"; BASIC_AUTH=""; MON=0; LOG=0; SUB=""; EXTRA_SET=(); POS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:?}"; shift 2 ;;
    --registry) REGISTRY="${2:?}"; shift 2 ;;
    --image) IMAGE="${2:?}"; shift 2 ;;
    --image-repo) IMAGE_REPO="${2:?}"; shift 2 ;;
    --env) ENVIRONMENT="${2:?}"; shift 2 ;;
    --region) REGION="${2:?}"; shift 2 ;;
    --basic-auth) BASIC_AUTH="${2:?}"; shift 2 ;;
    --monitoring) MON=1; shift ;;
    --logging) LOG=1; shift ;;
    --set) EXTRA_SET+=(--set "${2:?}"); shift 2 ;;
    -h|--help) usage 0 ;;
    *) POS+=("$1"); shift ;;
  esac
done
SUB="${POS[0]:-}"

full_image() { echo "${REGISTRY}/nexvion-web:${TAG}"; }

ecr_login() {
  case "$REGISTRY" in
    *.dkr.ecr.*.amazonaws.com*)
      require_cmd aws docker
      aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${REGISTRY%%/*}" ;;
  esac
}

# Wait (up to 5 minutes) until the ALB has an address, print it on stdout (messages go to stderr).
ingress_host() {
  local host="" i
  for i in $(seq 1 30); do
    host="$(kubectl -n "$NS" get ingress nexvion-web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [ -n "$host" ] && break
    log_info "Waiting for the load balancer address ($i/30) ..."; sleep 10
  done
  [ -n "$host" ] || die "The Ingress has no address yet. Check: kubectl -n $NS describe ingress nexvion-web  and  kubectl -n kube-system logs deploy/aws-load-balancer-controller"
  echo "$host"
}

wait_rollout() { kubectl -n "$NS" rollout status "deployment/$1" --timeout="${2:-300s}"; }

case "$CMD" in
  build)
    require_cmd docker
    log_info "Building $(full_image)"
    DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile \
      --build-arg APP_VERSION="$TAG" --build-arg VCS_REF="$(short_sha)" \
      -t "$(full_image)" -t "${REGISTRY}/nexvion-web:latest" .
    log_ok "Built $(full_image)"
    ;;

  push)
    [ "$REGISTRY" != local ] || die "--registry is required for push"
    ecr_login
    docker push "$(full_image)"
    log_ok "Pushed $(full_image)"
    ;;

  compose)
    require_cmd docker
    ACTION="${SUB:-up}"
    profiles=(); [ "$MON" = 1 ] && profiles+=(--profile monitoring); [ "$LOG" = 1 ] && profiles+=(--profile logging)
    export IMAGE_TAG="$TAG" REGISTRY
    [ -f docker/.env ] || { cp docker/.env.example docker/.env; log_warn "Created docker/.env from the example"; }
    case "$ACTION" in
      up)      compose "${profiles[@]}" up -d --build ;;
      down)    compose --profile monitoring --profile logging down ;;
      restart) compose "${profiles[@]}" up -d --build --force-recreate ;;
      logs)    compose "${profiles[@]}" logs -f --tail=100 ;;
      ps)      compose --profile monitoring --profile logging ps ;;
      *) die "Unknown compose action: $ACTION" ;;
    esac
    if [ "$ACTION" = up ] || [ "$ACTION" = restart ]; then
      bash scripts/health-check.sh --url "http://localhost:${PROXY_PORT:-80}" --compose --retries 12 --delay 5
    fi
    ;;

  addons)
    require_cmd kubectl helm
    tf_out() { terraform -chdir="$REPO_ROOT/terraform" output -raw "$1" 2>/dev/null || true; }
    CLUSTER_NAME="${CLUSTER_NAME:-$(tf_out eks_cluster_name)}"
    LBC_ROLE_ARN="${LBC_ROLE_ARN:-$(tf_out lbc_role_arn)}"
    VPC_ID="${VPC_ID:-$(tf_out vpc_id)}"
    [ -n "$CLUSTER_NAME" ] && [ -n "$LBC_ROLE_ARN" ] && [ -n "$VPC_ID" ] \
      || die "Cannot read the Terraform outputs. Run this on the machine where you ran terraform apply, or export CLUSTER_NAME, LBC_ROLE_ARN and VPC_ID."
    helm repo add eks https://aws.github.io/eks-charts >/dev/null
    helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
    helm repo update >/dev/null
    log_info "AWS Load Balancer Controller (creates the ALB for the Ingress; ingress-nginx is retired)"
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
      --set clusterName="$CLUSTER_NAME" --set region="$REGION" --set vpcId="$VPC_ID" \
      --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller \
      --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$LBC_ROLE_ARN" \
      --wait --timeout 5m
    log_info "metrics-server (needed by the HPA)"
    helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system --wait --timeout 5m
    log_info "kube-prometheus-stack (Prometheus, Alertmanager, Grafana)"
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
      GPASS="${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)}"
      kubectl -n monitoring create secret generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password="$GPASS"
      log_warn "Grafana admin password (shown once, also stored in the Secret grafana-admin): $GPASS"
    fi
    helm upgrade --install monitoring prometheus-community/kube-prometheus-stack -n monitoring \
      -f monitoring/kubernetes/kube-prometheus-stack-values.yaml --wait --timeout 10m
    kubectl apply -f monitoring/kubernetes/grafana-dashboard-configmap.yaml
    kubectl apply -f monitoring/kubernetes/servicemonitor.yaml -f monitoring/kubernetes/prometheusrule.yaml
    log_ok "Add-ons installed. Grafana:  kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80"
    ;;

  elk)
    require_cmd kubectl
    kubectl apply -f logging/elk/kubernetes/elk-stack.yaml
    kubectl -n logging rollout status statefulset/elasticsearch --timeout=300s
    kubectl -n logging rollout status deployment/kibana --timeout=300s
    log_ok "ELK is running. Kibana:  kubectl -n logging port-forward svc/kibana 5601:5601"
    ;;

  k8s)
    require_cmd kubectl
    [ -n "$IMAGE" ] || IMAGE="$(full_image)"
    bash scripts/sync-config.sh >/dev/null
    kubectl apply -f kubernetes/namespace.yaml
    if [ -n "$BASIC_AUTH" ]; then
      require_cmd htpasswd
      htpasswd -nbB "${BASIC_AUTH%%:*}" "${BASIC_AUTH#*:}" > /tmp/nexvion-htpasswd
      kubectl -n "$NS" create secret generic nexvion-basic-auth \
        --from-file=htpasswd=/tmp/nexvion-htpasswd \
        --from-literal=auth.conf='auth_basic "Nexvion staging"; auth_basic_user_file /etc/nginx/auth.d/htpasswd;' \
        --dry-run=client -o yaml | kubectl apply -f -
      rm -f /tmp/nexvion-htpasswd
    fi
    log_info "Deploying $IMAGE (rolling update)"
    kubectl kustomize kubernetes | sed "s#image: nexvion-web:latest#image: ${IMAGE}#" | kubectl apply -f -
    wait_rollout nexvion-web
    HOST="$(ingress_host)"
    log_info "Site address: http://${HOST}  (the ALB may need 1-2 more minutes before it answers)"
    bash scripts/health-check.sh --k8s --namespace "$NS" --url "http://${HOST}" --retries 12 --delay 10 || log_warn "Health check not green yet - re-run it in a minute"
    kubectl -n "$NS" get deploy,pods,svc,ingress,hpa
    ;;

  ingress-host) require_cmd kubectl; ingress_host ;;

  helm)
    require_cmd helm kubectl
    [ -n "$IMAGE_REPO" ] || IMAGE_REPO="${REGISTRY}/nexvion-web"
    VALUES=(-f "helm/ecommerce/values.yaml"); [ -f "helm/ecommerce/values-${ENVIRONMENT}.yaml" ] && VALUES+=(-f "helm/ecommerce/values-${ENVIRONMENT}.yaml")
    log_info "Helm release nexvion (${ENVIRONMENT}) -> ${IMAGE_REPO}:${TAG}"
    helm upgrade --install nexvion helm/ecommerce -n "$NS" --create-namespace "${VALUES[@]}" \
      --set image.repository="$IMAGE_REPO" --set image.tag="$TAG" \
      ${EXTRA_SET[@]+"${EXTRA_SET[@]}"} --atomic --timeout 5m
    helm -n "$NS" status nexvion | head -12
    log_info "Address of the site: kubectl -n $NS get ingress nexvion-web   (or: ./scripts/deploy.sh ingress-host)"
    ;;

  bluegreen) require_cmd kubectl; exec bash kubernetes/strategies/bluegreen/switch.sh "${SUB:-status}" "${POS[@]:1}" ;;
  canary)    require_cmd kubectl; exec bash kubernetes/strategies/canary/canary.sh "${SUB:-}" "${POS[@]:1}" ;;

  rollback)
    case "$SUB" in
      k8s)  require_cmd kubectl; kubectl -n "$NS" rollout undo deployment/nexvion-web; wait_rollout nexvion-web ;;
      helm) require_cmd helm;    helm -n "$NS" rollback nexvion --wait --timeout 5m ;;
      *) die "usage: deploy.sh rollback {k8s|helm}" ;;
    esac
    log_ok "Rolled back"
    ;;

  *) usage 1 ;;
esac
