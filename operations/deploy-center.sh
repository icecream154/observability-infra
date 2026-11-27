#!/bin/sh
# 中心可观测服务器（observability-infra）一键初始化与部署脚本：
#   1. 检查并安装 Docker 与 docker compose 插件（优先自动探测阿里云内网源，回退清华源）
#   2. 可选登录私有镜像仓库（如阿里云 ACR，用于国内加速拉取 4 个基础镜像）
#   3. 生成或安全更新项目根目录 .env（首次留空密钥会自动随机生成，重复执行默认保留已有密钥）
#   4. 启动中心四组件（ClickHouse + MongoDB + 独立 Collector + HyperDX）
#
# 使用方法：
#   1. 将 observability-infra 仓库拉取到中心服务器（例如 /opt/observability-infra）
#   2. 原地编辑本脚本，至少填写下方 HYPERDX_PUBLIC_URL（其余按需修改或留空）
#   3. 使用 root 权限执行：
#        sudo sh operations/deploy-center.sh
#   4. 执行完成后，如在本脚本中填写过明文密码，建议立即还原避免留存或误提交：
#        git checkout -- operations/deploy-center.sh

set -eu

# ==============================================================================
# 1. 必填项（请务必填写实际访问地址）
# ==============================================================================
# 浏览器实际访问 HyperDX 的完整地址（不要带末尾斜杠 /）
# 示例：http://10.0.1.5:18080  或  https://logs.example.com
HYPERDX_PUBLIC_URL="${HYPERDX_PUBLIC_URL:-}"

# ==============================================================================
# 2. 安全密钥（留空即可：首次部署自动生成 64 位随机十六进制；重复执行保留 .env 旧值）
#    如需指定固定值，请仅使用字母/数字/十六进制字符，避免空格与引号
# ==============================================================================
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-}"
EXPRESS_SESSION_SECRET="${EXPRESS_SESSION_SECRET:-}"
OTLP_AUTH_TOKEN="${OTLP_AUTH_TOKEN:-}"

# ==============================================================================
# 3. 可选：私有镜像仓库（若中心 ECS 拉 Docker Hub 慢，可先把 4 个镜像同步到 ACR 后填此处）
#    不使用私有仓库时全部留空，将默认使用官方固定版本镜像
# ==============================================================================
ACR_REGISTRY="${ACR_REGISTRY:-}"          # 例如: registry-vpc.cn-hangzhou.aliyuncs.com
ACR_USERNAME="${ACR_USERNAME:-}"          # ACR 登录用户名
ACR_PASSWORD="${ACR_PASSWORD:-}"          # ACR 登录密码

CLICKSTACK_APP_IMAGE="${CLICKSTACK_APP_IMAGE:-}"              # 留空默认: hyperdx/hyperdx:2.43.1
CLICKSTACK_COLLECTOR_IMAGE="${CLICKSTACK_COLLECTOR_IMAGE:-}"  # 留空默认: hyperdx/hyperdx-otel-collector:2.43.1
CLICKHOUSE_IMAGE="${CLICKHOUSE_IMAGE:-}"                      # 留空默认: clickhouse/clickhouse-server:26.8.36.3-alpine
MONGODB_IMAGE="${MONGODB_IMAGE:-}"                            # 留空默认: mongo:5.0.32-focal

# ==============================================================================
# 4. 网络绑定、端口、保留时长与内存限额（通常保持默认，按需调整）
# ==============================================================================
# 若本机前置了 Nginx/Caddy 做 HTTPS，可将对应 BIND_ADDRESS 改为 127.0.0.1
HYPERDX_BIND_ADDRESS="${HYPERDX_BIND_ADDRESS:-0.0.0.0}"
HYPERDX_APP_PORT="${HYPERDX_APP_PORT:-18080}"
HYPERDX_API_PORT="${HYPERDX_API_PORT:-18001}"

OTLP_BIND_ADDRESS="${OTLP_BIND_ADDRESS:-0.0.0.0}"
OTLP_GRPC_PORT="${OTLP_GRPC_PORT:-4317}"
OTLP_HTTP_PORT="${OTLP_HTTP_PORT:-4318}"

TABLES_RETENTION="${TABLES_RETENTION:-720h}"

CLICKHOUSE_MEMORY_LIMIT="${CLICKHOUSE_MEMORY_LIMIT:-4g}"
CLICKSTACK_APP_MEMORY_LIMIT="${CLICKSTACK_APP_MEMORY_LIMIT:-2g}"
MONGODB_MEMORY_LIMIT="${MONGODB_MEMORY_LIMIT:-1g}"
COLLECTOR_MEMORY_LIMIT="${COLLECTOR_MEMORY_LIMIT:-1g}"

# Docker CE 软件源（留空时自动探测：阿里云 VPC 内网源 -> 清华源 -> 阿里云公网源）
DOCKER_MIRROR_BASE="${DOCKER_MIRROR_BASE:-}"

# 默认官方镜像版本（与 .env.example 保持一致）
DEFAULT_CLICKSTACK_APP_IMAGE="hyperdx/hyperdx:2.43.1"
DEFAULT_CLICKSTACK_COLLECTOR_IMAGE="hyperdx/hyperdx-otel-collector:2.43.1"
DEFAULT_CLICKHOUSE_IMAGE="clickhouse/clickhouse-server:26.8.36.3-alpine"
DEFAULT_MONGODB_IMAGE="mongo:5.0.32-focal"

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)
ENV_FILE="${PROJECT_ROOT}/.env"

log() {
  printf '==> %s\n' "$*"
}

err() {
  printf '[ERROR] %s\n' "$*" >&2
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 权限执行本脚本，例如: sudo sh $0"
    exit 1
  fi
}

check_safe_secret() {
  name="$1"
  val="$2"
  case "$val" in
    *[[:space:]]*|*\"*|*\'*|*\\*)
      err "${name} 不能包含空白字符、引号或反斜杠（建议使用纯十六进制随机串）"
      exit 2
      ;;
  esac
}

validate_inputs() {
  if [ ! -f "${PROJECT_ROOT}/compose.yaml" ]; then
    err "未在 ${PROJECT_ROOT} 找到 compose.yaml，请在 observability-infra 仓库内执行本脚本"
    exit 1
  fi

  if [ -z "$HYPERDX_PUBLIC_URL" ]; then
    err "HYPERDX_PUBLIC_URL 不能为空，请在脚本顶部填写浏览器实际访问地址（例如 http://10.0.1.5:18080 或 https://logs.example.com）"
    exit 2
  fi

  HYPERDX_PUBLIC_URL=$(printf '%s' "$HYPERDX_PUBLIC_URL" | sed -e 's#/*$##')
  case "$HYPERDX_PUBLIC_URL" in
    http://*|https://*) ;;
    *)
      err "HYPERDX_PUBLIC_URL 必须以 http:// 或 https:// 开头，当前值: ${HYPERDX_PUBLIC_URL}"
      exit 2
      ;;
  esac

  if [ -n "$ACR_REGISTRY" ]; then
    ACR_REGISTRY=$(printf '%s' "$ACR_REGISTRY" | sed -e 's#^https://##' -e 's#^http://##' -e 's#/*$##')
    if [ -n "$ACR_USERNAME" ] && [ -z "$ACR_PASSWORD" ]; then
      err "填写了 ACR_USERNAME 时必须同时填写 ACR_PASSWORD"
      exit 2
    fi
    if [ -z "$ACR_USERNAME" ] && [ -n "$ACR_PASSWORD" ]; then
      err "填写了 ACR_PASSWORD 时必须同时填写 ACR_USERNAME"
      exit 2
    fi
  fi

  [ -n "$CLICKHOUSE_PASSWORD" ] && check_safe_secret "CLICKHOUSE_PASSWORD" "$CLICKHOUSE_PASSWORD"
  [ -n "$EXPRESS_SESSION_SECRET" ] && check_safe_secret "EXPRESS_SESSION_SECRET" "$EXPRESS_SESSION_SECRET"
  [ -n "$OTLP_AUTH_TOKEN" ] && check_safe_secret "OTLP_AUTH_TOKEN" "$OTLP_AUTH_TOKEN"
  return 0
}

read_existing_env_value() {
  key="$1"
  if [ ! -f "$ENV_FILE" ]; then
    return 0
  fi
  # 读取已有 .env 中最后一个非注释的 KEY=VALUE
  awk -F= -v k="$key" '
    /^[[:space:]]*#/ { next }
    $1 == k {
      val = substr($0, length(k) + 2)
    }
    END {
      if (val != "") print val
    }
  ' "$ENV_FILE"
}

gen_hex_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  elif [ -r /dev/urandom ]; then
    od -An -tx1 -N32 /dev/urandom | tr -d ' \n'
    printf '\n'
  else
    err "无法自动生成随机密钥（缺少 openssl 且不可读 /dev/urandom），请手动填写 3 个密钥变量"
    exit 1
  fi
}

resolve_secret() {
  key="$1"
  current_val="$2"
  if [ -n "$current_val" ]; then
    printf '%s' "$current_val"
    return 0
  fi
  existing_val=$(read_existing_env_value "$key")
  if [ -n "$existing_val" ]; then
    printf '%s' "$existing_val"
    return 0
  fi
  gen_hex_secret
}

resolve_docker_mirror_base() {
  probe_subpath="$1"

  if [ -n "$DOCKER_MIRROR_BASE" ]; then
    DOCKER_MIRROR_BASE=$(printf '%s' "$DOCKER_MIRROR_BASE" | sed -e 's#/*$##')
    log "使用指定的 Docker 软件源: ${DOCKER_MIRROR_BASE}"
    return 0
  fi

  for candidate in \
    "http://mirrors.cloud.aliyuncs.com/docker-ce" \
    "https://mirrors.tuna.tsinghua.edu.cn/docker-ce" \
    "https://mirrors.aliyun.com/docker-ce"
  do
    if curl -fsSL --connect-timeout 2 --max-time 5 "${candidate}/${probe_subpath}" >/dev/null 2>&1; then
      DOCKER_MIRROR_BASE="$candidate"
      log "已自动探测并选用 Docker 软件源: ${DOCKER_MIRROR_BASE}"
      return 0
    fi
  done

  DOCKER_MIRROR_BASE="https://mirrors.tuna.tsinghua.edu.cn/docker-ce"
  log "软件源探测超时，回退默认 Docker 软件源: ${DOCKER_MIRROR_BASE}"
}

install_docker_debian() {
  os_id="$1"
  codename="$2"

  export DEBIAN_FRONTEND=noninteractive
  rm -f /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg

  resolve_docker_mirror_base "linux/${os_id}/gpg"

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "${DOCKER_MIRROR_BASE}/linux/${os_id}/gpg" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  arch=$(dpkg --print-architecture)
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] %s/linux/%s %s stable\n' \
    "$arch" "$DOCKER_MIRROR_BASE" "$os_id" "$codename" >/etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

install_docker_rhel() {
  os_id="$1"
  version_id="$2"

  if command -v dnf >/dev/null 2>&1; then
    pkg_mgr="dnf"
  elif command -v yum >/dev/null 2>&1; then
    pkg_mgr="yum"
  else
    err "未找到 dnf 或 yum，无法自动安装 Docker"
    exit 1
  fi

  rm -f /etc/yum.repos.d/docker-ce.repo
  "$pkg_mgr" -y install curl ca-certificates yum-utils || "$pkg_mgr" -y install curl ca-certificates dnf-utils

  resolve_docker_mirror_base "linux/centos/docker-ce.repo"

  if [ "$pkg_mgr" = "dnf" ]; then
    dnf config-manager --add-repo "${DOCKER_MIRROR_BASE}/linux/centos/docker-ce.repo"
  else
    yum-config-manager --add-repo "${DOCKER_MIRROR_BASE}/linux/centos/docker-ce.repo"
  fi

  if [ -f /etc/yum.repos.d/docker-ce.repo ]; then
    sed -i \
      -e "s#https://download.docker.com#${DOCKER_MIRROR_BASE}#g" \
      -e "s#https://mirrors.aliyun.com/docker-ce#${DOCKER_MIRROR_BASE}#g" \
      /etc/yum.repos.d/docker-ce.repo
  fi

  if [ "$os_id" = "alinux" ] && [ "${version_id%%.*}" = "3" ]; then
    if ! "$pkg_mgr" -y install dnf-plugin-releasever-adapter --repo alinux3-plus >/dev/null 2>&1; then
      sed -i 's/\$releasever/8/g' /etc/yum.repos.d/docker-ce.repo
    fi
  fi

  "$pkg_mgr" -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

ensure_docker() {
  has_docker=0
  has_compose=0

  if command -v docker >/dev/null 2>&1; then
    has_docker=1
  fi
  if [ "$has_docker" -eq 1 ] && docker compose version >/dev/null 2>&1; then
    has_compose=1
  fi

  if [ "$has_docker" -eq 1 ] && [ "$has_compose" -eq 1 ]; then
    log "已检测到 Docker 与 docker compose 插件，跳过安装"
  else
    if [ ! -r /etc/os-release ]; then
      err "无法识别操作系统（缺少 /etc/os-release），请手动安装 Docker 与 docker compose 插件后重试"
      exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    version_id="${VERSION_ID:-}"
    codename="${VERSION_CODENAME:-}"

    log "开始安装 Docker 与 docker compose 插件（OS: ${os_id} ${version_id}）..."
    case "$os_id" in
      ubuntu|debian)
        if [ -z "$codename" ]; then
          err "无法获取系统代号 VERSION_CODENAME，请手动安装 Docker 后重试"
          exit 1
        fi
        install_docker_debian "$os_id" "$codename"
        ;;
      alinux|centos|rhel|rocky|almalinux|anolis|opencloudos)
        install_docker_rhel "$os_id" "$version_id"
        ;;
      *)
        err "暂不支持自动安装 Docker 的发行版: ${os_id:-unknown}，请先手动安装 Docker 与 docker compose 插件后再执行本脚本"
        exit 1
        ;;
    esac
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || systemctl start docker
  elif command -v service >/dev/null 2>&1; then
    service docker start
  fi

  docker info >/dev/null 2>&1 || {
    err "Docker 守护进程未正常运行，请检查 systemctl status docker"
    exit 1
  }
  docker compose version >/dev/null 2>&1 || {
    err "docker compose 插件不可用，请检查安装状态"
    exit 1
  }

  log "Docker 就绪: $(docker --version) | $(docker compose version)"
}

login_acr_if_configured() {
  if [ -n "$ACR_REGISTRY" ] && [ -n "$ACR_USERNAME" ] && [ -n "$ACR_PASSWORD" ]; then
    log "正在登录私有镜像仓库: ${ACR_REGISTRY} ..."
    printf '%s' "$ACR_PASSWORD" | docker login --username "$ACR_USERNAME" --password-stdin "$ACR_REGISTRY"
    log "私有镜像仓库登录成功"
  fi
}

write_env_file() {
  final_ch_pass=$(resolve_secret "CLICKHOUSE_PASSWORD" "$CLICKHOUSE_PASSWORD")
  final_session=$(resolve_secret "EXPRESS_SESSION_SECRET" "$EXPRESS_SESSION_SECRET")
  final_otlp_token=$(resolve_secret "OTLP_AUTH_TOKEN" "$OTLP_AUTH_TOKEN")

  final_app_image="${CLICKSTACK_APP_IMAGE:-$DEFAULT_CLICKSTACK_APP_IMAGE}"
  final_collector_image="${CLICKSTACK_COLLECTOR_IMAGE:-$DEFAULT_CLICKSTACK_COLLECTOR_IMAGE}"
  final_ch_image="${CLICKHOUSE_IMAGE:-$DEFAULT_CLICKHOUSE_IMAGE}"
  final_mongo_image="${MONGODB_IMAGE:-$DEFAULT_MONGODB_IMAGE}"

  umask 077
  if [ -f "$ENV_FILE" ]; then
    cp "$ENV_FILE" "${ENV_FILE}.bak"
    chmod 600 "${ENV_FILE}.bak"
    log "已备份原有 .env 至 ${ENV_FILE}.bak"
  fi

  tmp_env="${ENV_FILE}.tmp.$$"
  cat >"$tmp_env" <<EOF
# 由 operations/deploy-center.sh 生成，权限 600，请勿提交到版本库
CLICKSTACK_APP_IMAGE=${final_app_image}
CLICKSTACK_COLLECTOR_IMAGE=${final_collector_image}
CLICKHOUSE_IMAGE=${final_ch_image}
MONGODB_IMAGE=${final_mongo_image}

HYPERDX_BIND_ADDRESS=${HYPERDX_BIND_ADDRESS}
HYPERDX_PUBLIC_URL=${HYPERDX_PUBLIC_URL}
HYPERDX_APP_PORT=${HYPERDX_APP_PORT}
HYPERDX_API_PORT=${HYPERDX_API_PORT}

OTLP_BIND_ADDRESS=${OTLP_BIND_ADDRESS}
OTLP_GRPC_PORT=${OTLP_GRPC_PORT}
OTLP_HTTP_PORT=${OTLP_HTTP_PORT}

CLICKHOUSE_PASSWORD=${final_ch_pass}
EXPRESS_SESSION_SECRET=${final_session}
OTLP_AUTH_TOKEN=${final_otlp_token}

TABLES_RETENTION=${TABLES_RETENTION}

CLICKHOUSE_MEMORY_LIMIT=${CLICKHOUSE_MEMORY_LIMIT}
CLICKSTACK_APP_MEMORY_LIMIT=${CLICKSTACK_APP_MEMORY_LIMIT}
MONGODB_MEMORY_LIMIT=${MONGODB_MEMORY_LIMIT}
COLLECTOR_MEMORY_LIMIT=${COLLECTOR_MEMORY_LIMIT}
EOF

  chmod 600 "$tmp_env"
  mv "$tmp_env" "$ENV_FILE"
  log "已写入中心配置文件: ${ENV_FILE}"
}

start_stack() {
  cd "$PROJECT_ROOT"
  log "开始拉取中心镜像并启动服务（目录: ${PROJECT_ROOT}）..."
  docker compose pull
  docker compose up -d

  log "当前容器状态："
  docker compose ps
}

main() {
  require_root
  validate_inputs
  ensure_docker
  login_acr_if_configured
  write_env_file
  start_stack

  cat <<EOF

====================================================================
observability-infra 中心平台部署完成！
  - HyperDX 页面地址 : ${HYPERDX_PUBLIC_URL}
  - OTLP HTTP 监听   : ${OTLP_BIND_ADDRESS}:${OTLP_HTTP_PORT}
  - OTLP gRPC 监听   : ${OTLP_BIND_ADDRESS}:${OTLP_GRPC_PORT}
  - 配置文件位置     : ${ENV_FILE}

下一步建议：
  1. 查看分配给业务机/云效流水线的采集凭据：
       grep '^OTLP_AUTH_TOKEN=' ${ENV_FILE}
  2. 检查云服务器安全组：
       - 仅对业务 ECS 内网放通 ${OTLP_HTTP_PORT}（及可选 ${OTLP_GRPC_PORT}）
       - 对管理终端放通 ${HYPERDX_APP_PORT}（若走 Nginx HTTPS 则放通 443）
  3. 浏览器打开 ${HYPERDX_PUBLIC_URL}，首次访问注册管理员账号。
  4. （可选）如需将日志/Span 保留期调整为 7 天，待有数据建表后执行：
       docker compose exec -T clickhouse sh -c 'exec clickhouse-client --user "\$CLICKHOUSE_USER" --password "\$CLICKHOUSE_PASSWORD" --multiquery' < clickhouse/retention.sql
  5. 安全提醒：如在本脚本中填写过明文密码，请执行下方命令还原脚本：
       git -C ${PROJECT_ROOT} checkout -- operations/deploy-center.sh
====================================================================
EOF
}

main "$@"
