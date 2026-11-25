#!/bin/sh
# 宿主机唯一维护的无状态服务部署与原子回滚脚本（Go / Python 服务通用）。
#
# 设计约定：
# 1. 业务配置已随 Dockerfile 打入业务镜像 (/app/config)，采集规则已打入公共 log-agent 镜像；
# 2. 宿主机不维护任何业务 YAML、证书或手工 .env 文件，本脚本内置标准 Compose 编排并通过 stdin 下发；
# 3. 每次更新仅记录非敏感的上一版健康参数至 /var/lib/service-ctl/，启动探针异常时自动秒级切回旧镜像。
#
# 用法 1（推荐命名参数，适合云效 Flow 主机部署脚本）：
#   printf '%s' "${OTLP_AUTH_TOKEN}" | /opt/bin/service-ctl.sh deploy \
#     --service order-service \
#     --env prod \
#     --port 18082 \
#     --image registry-vpc.cn-hangzhou.aliyuncs.com/ns/order-service:20261124 \
#     --agent-image registry-vpc.cn-hangzhou.aliyuncs.com/ns/log-agent:v1 \
#     --otlp-endpoint http://10.0.1.5:4318
#
# 用法 2（6 位置参数简写）：
#   printf '%s' "${OTLP_AUTH_TOKEN}" | /opt/bin/service-ctl.sh \
#     order-service prod 18082 <app_image> <agent_image> <otlp_endpoint>
#
# 用法 3（手动应急回滚 / 查看状态）：
#   printf '%s' "${OTLP_AUTH_TOKEN}" | /opt/bin/service-ctl.sh rollback --service order-service --env prod
#   /opt/bin/service-ctl.sh status --service order-service --env prod

set -eu

usage() {
  cat >&2 <<'USAGE'
Usage:
  service-ctl.sh deploy --service <name> --env <dev|test|prod> --port <port> \
    --image <app_image> --agent-image <agent_image> --otlp-endpoint <url> \
    [--bind <ip>] [--region <region>] [--wait-seconds <sec>] [--health-url <url>]

  service-ctl.sh <service> <dev|test|prod> <port> <app_image> <agent_image> <otlp_endpoint>

  service-ctl.sh rollback --service <name> --env <dev|test|prod>
  service-ctl.sh status   --service <name> --env <dev|test|prod>
USAGE
  exit 2
}

[ "$#" -ge 1 ] || usage

ACTION="deploy"
SERVICE_NAME=""
APP_ENV=""
HTTP_PORT=""
APP_IMAGE=""
LOG_AGENT_IMAGE=""
OTLP_ENDPOINT=""
BIND_ADDRESS="0.0.0.0"
APP_REGION="cn"
WAIT_SECONDS="5"
HEALTH_URL=""
STATE_ROOT="${SERVICE_CTL_STATE_ROOT:-/var/lib/service-ctl}"

case "$1" in
  deploy|rollback|status)
    ACTION="$1"
    shift
    ;;
  -h|--help)
    usage
    ;;
  --*)
    ACTION="deploy"
    ;;
  *)
    if [ "$#" -ge 6 ]; then
      ACTION="deploy"
      SERVICE_NAME="$1"
      APP_ENV="$2"
      HTTP_PORT="$3"
      APP_IMAGE="$4"
      LOG_AGENT_IMAGE="$5"
      OTLP_ENDPOINT="$6"
      shift 6
    else
      usage
    fi
    ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --service)
      [ "$#" -ge 2 ] || usage
      SERVICE_NAME="$2"
      shift 2
      ;;
    --env)
      [ "$#" -ge 2 ] || usage
      APP_ENV="$2"
      shift 2
      ;;
    --port)
      [ "$#" -ge 2 ] || usage
      HTTP_PORT="$2"
      shift 2
      ;;
    --image)
      [ "$#" -ge 2 ] || usage
      APP_IMAGE="$2"
      shift 2
      ;;
    --agent-image)
      [ "$#" -ge 2 ] || usage
      LOG_AGENT_IMAGE="$2"
      shift 2
      ;;
    --otlp-endpoint)
      [ "$#" -ge 2 ] || usage
      OTLP_ENDPOINT="$2"
      shift 2
      ;;
    --bind)
      [ "$#" -ge 2 ] || usage
      BIND_ADDRESS="$2"
      shift 2
      ;;
    --region)
      [ "$#" -ge 2 ] || usage
      APP_REGION="$2"
      shift 2
      ;;
    --wait-seconds)
      [ "$#" -ge 2 ] || usage
      WAIT_SECONDS="$2"
      shift 2
      ;;
    --health-url)
      [ "$#" -ge 2 ] || usage
      HEALTH_URL="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[ -n "$SERVICE_NAME" ] || { printf 'Error: --service is required\n' >&2; exit 2; }
case "$APP_ENV" in
  dev|test|prod) ;;
  *) printf 'Error: --env must be dev, test, or prod\n' >&2; exit 2 ;;
esac

PROJECT_NAME="${SERVICE_NAME}-${APP_ENV}"

if [ "$ACTION" = "status" ]; then
  exec docker compose -p "$PROJECT_NAME" ps
fi

read_auth_token() {
  if [ -z "${OTLP_AUTH_TOKEN:-}" ] && [ ! -t 0 ]; then
    OTLP_AUTH_TOKEN=$(cat)
  fi
  if [ -z "${OTLP_AUTH_TOKEN:-}" ]; then
    printf 'Error: OTLP_AUTH_TOKEN must be provided via stdin or environment\n' >&2
    exit 2
  fi
}

STATE_DIR="${STATE_ROOT}/${PROJECT_NAME}"
LAST_GOOD_FILE="${STATE_DIR}/last_good.env"

write_state_file() {
  target_file="$1"
  umask 077
  mkdir -p "$STATE_DIR"
  cat >"$target_file" <<EOF
SAVED_HTTP_PORT="${HTTP_PORT}"
SAVED_APP_IMAGE="${APP_IMAGE}"
SAVED_LOG_AGENT_IMAGE="${LOG_AGENT_IMAGE}"
SAVED_OTLP_ENDPOINT="${OTLP_ENDPOINT}"
SAVED_BIND_ADDRESS="${BIND_ADDRESS}"
SAVED_APP_REGION="${APP_REGION}"
EOF
}

load_state_file() {
  target_file="$1"
  if [ ! -f "$target_file" ]; then
    return 1
  fi
  # shellcheck disable=SC1090
  . "$target_file"
  return 0
}

compose_up() {
  target_app_image="$1"
  target_agent_image="$2"
  target_port="$3"
  target_endpoint="$4"
  target_bind="$5"
  target_region="$6"

  APP_IMAGE="$target_app_image" \
  LOG_AGENT_IMAGE="$target_agent_image" \
  APP_ENV="$APP_ENV" \
  APP_REGION="$target_region" \
  BIND_ADDRESS="$target_bind" \
  HTTP_PORT="$target_port" \
  OTLP_ENDPOINT="$target_endpoint" \
  OTLP_AUTH_TOKEN="$OTLP_AUTH_TOKEN" \
  docker compose -p "$PROJECT_NAME" -f - up -d --remove-orphans <<'EOF'
services:
  app:
    image: ${APP_IMAGE}
    restart: unless-stopped
    stop_grace_period: 20s
    depends_on:
      log-agent:
        condition: service_started
    environment:
      APP_ENV: ${APP_ENV}
      APP_REGION: ${APP_REGION}
      OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: http://log-agent:4318/v1/traces
    ports:
      - "${BIND_ADDRESS}:${HTTP_PORT}:8080"
    volumes:
      - app-logs:/app/.data/logs
    logging: &default_logging
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"

  log-agent:
    image: ${LOG_AGENT_IMAGE}
    restart: unless-stopped
    mem_limit: 256m
    user: "0:0"
    cap_drop: [ALL]
    logging: *default_logging
    environment:
      GOMEMLIMIT: 200MiB
      OTLP_ENDPOINT: ${OTLP_ENDPOINT}
      OTLP_AUTH_TOKEN: ${OTLP_AUTH_TOKEN}
    volumes:
      - type: volume
        source: app-logs
        target: /app/.data/logs
        read_only: true
        volume:
          nocopy: true
      - log-agent-state:/var/lib/otelcol

volumes:
  app-logs:
  log-agent-state:
EOF
}

verify_health() {
  sleep "$WAIT_SECONDS"
  running_count=$(docker compose -p "$PROJECT_NAME" ps --status running -q | wc -l | tr -d ' ')
  if [ "$running_count" -lt 2 ]; then
    return 1
  fi
  if [ -n "$HEALTH_URL" ]; then
    curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null || return 1
  fi
  return 0
}

if [ "$ACTION" = "rollback" ]; then
  read_auth_token
  if ! load_state_file "$LAST_GOOD_FILE"; then
    printf 'Error: no previous healthy release recorded for %s\n' "$PROJECT_NAME" >&2
    exit 1
  fi
  printf '==> Rolling back %s to %s...\n' "$PROJECT_NAME" "$SAVED_APP_IMAGE"
  compose_up \
    "$SAVED_APP_IMAGE" \
    "$SAVED_LOG_AGENT_IMAGE" \
    "$SAVED_HTTP_PORT" \
    "$SAVED_OTLP_ENDPOINT" \
    "$SAVED_BIND_ADDRESS" \
    "$SAVED_APP_REGION"
  verify_health
  printf '==> Rollback succeeded: %s\n' "$SAVED_APP_IMAGE"
  exit 0
fi

# deploy 分支校验必填参数
[ -n "$HTTP_PORT" ] || { printf 'Error: --port is required\n' >&2; exit 2; }
[ -n "$APP_IMAGE" ] || { printf 'Error: --image is required\n' >&2; exit 2; }
[ -n "$LOG_AGENT_IMAGE" ] || { printf 'Error: --agent-image is required\n' >&2; exit 2; }
[ -n "$OTLP_ENDPOINT" ] || { printf 'Error: --otlp-endpoint is required\n' >&2; exit 2; }
read_auth_token

HAVE_PREV=0
if load_state_file "$LAST_GOOD_FILE"; then
  HAVE_PREV=1
fi

printf '==> Pulling images for %s...\n' "$PROJECT_NAME"
docker pull "$APP_IMAGE"
docker pull "$LOG_AGENT_IMAGE"

printf '==> Applying Compose stack %s...\n' "$PROJECT_NAME"
compose_up "$APP_IMAGE" "$LOG_AGENT_IMAGE" "$HTTP_PORT" "$OTLP_ENDPOINT" "$BIND_ADDRESS" "$APP_REGION"

if ! verify_health; then
  printf '[ERROR] Health verification failed for %s (%s)\n' "$PROJECT_NAME" "$APP_IMAGE" >&2
  if [ "$HAVE_PREV" -eq 1 ]; then
    printf '==> Auto-rolling back %s to previous healthy image: %s\n' "$PROJECT_NAME" "$SAVED_APP_IMAGE" >&2
    compose_up \
      "$SAVED_APP_IMAGE" \
      "$SAVED_LOG_AGENT_IMAGE" \
      "$SAVED_HTTP_PORT" \
      "$SAVED_OTLP_ENDPOINT" \
      "$SAVED_BIND_ADDRESS" \
      "$SAVED_APP_REGION" || true
  fi
  exit 1
fi

write_state_file "$LAST_GOOD_FILE"
docker image prune -f --filter "until=168h" >/dev/null 2>&1 || true
printf '==> Deployment succeeded for %s (%s)\n' "$PROJECT_NAME" "$APP_IMAGE"
