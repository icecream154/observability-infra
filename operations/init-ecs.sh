#!/bin/sh
# 业务 ECS 服务器一次性初始化脚本：
#   1. 检查并安装 Docker 与 docker compose 插件（优先自动探测阿里云内网源，回退清华源）
#   2. 登录阿里云 ACR（推荐使用同地域 VPC 内网域名，凭证保存在 /root/.docker/config.json）
#   3. 安装通用发布脚本 service-ctl.sh 到 /opt/bin/service-ctl.sh 并赋权
#
# 使用方法：
#   1. 将本目录的 init-ecs.sh 与 service-ctl.sh 一同复制到目标 ECS（例如 /tmp/）
#   2. 编辑 init-ecs.sh，填写下方 ACR_REGISTRY / ACR_USERNAME / ACR_PASSWORD
#   3. 使用 root 权限执行：
#        sudo sh /tmp/init-ecs.sh
#   4. 初始化完成后，建议删除服务器上的 /tmp/init-ecs.sh（避免明文密码留存）

set -eu

# ==============================================================================
# 请在执行前填写以下必填信息（也可通过同名环境变量传入）
# ==============================================================================
ACR_REGISTRY="${ACR_REGISTRY:-}"          # ACR 镜像仓库地址，例如: registry-vpc.cn-hangzhou.aliyuncs.com
ACR_USERNAME="${ACR_USERNAME:-}"          # ACR 登录用户名
ACR_PASSWORD="${ACR_PASSWORD:-}"          # ACR 登录密码（固定密码）

# ==============================================================================
# 可选配置（通常保持默认即可）
# ==============================================================================
SERVICE_CTL_TARGET="${SERVICE_CTL_TARGET:-/opt/bin/service-ctl.sh}"
SERVICE_CTL_SOURCE="${SERVICE_CTL_SOURCE:-}"   # 留空时默认读取与本脚本同目录的 service-ctl.sh
SERVICE_CTL_URL="${SERVICE_CTL_URL:-}"         # 若未一同上传 service-ctl.sh，可填写其下载地址
STATE_ROOT="${STATE_ROOT:-/var/lib/service-ctl}"
# Docker CE 软件源（留空时自动探测：阿里云 VPC 内网源 -> 清华源 -> 阿里云公网源）
DOCKER_MIRROR_BASE="${DOCKER_MIRROR_BASE:-}"

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

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

validate_inputs() {
  missing=0
  if [ -z "$ACR_REGISTRY" ]; then
    err "ACR_REGISTRY 不能为空，请在脚本顶部填写（例如 registry-vpc.cn-hangzhou.aliyuncs.com）"
    missing=1
  fi
  if [ -z "$ACR_USERNAME" ]; then
    err "ACR_USERNAME 不能为空，请在脚本顶部填写 ACR 登录用户名"
    missing=1
  fi
  if [ -z "$ACR_PASSWORD" ]; then
    err "ACR_PASSWORD 不能为空，请在脚本顶部填写 ACR 登录密码"
    missing=1
  fi
  if [ "$missing" -ne 0 ]; then
    exit 2
  fi

  # 去除误粘贴的协议前缀与尾部斜杠
  ACR_REGISTRY=$(printf '%s' "$ACR_REGISTRY" | sed -e 's#^https://##' -e 's#^http://##' -e 's#/*$##')
}

resolve_service_ctl_source() {
  if [ -n "$SERVICE_CTL_SOURCE" ]; then
    if [ ! -f "$SERVICE_CTL_SOURCE" ]; then
      err "指定的 SERVICE_CTL_SOURCE 不存在: $SERVICE_CTL_SOURCE"
      exit 1
    fi
    return 0
  fi

  if [ -f "${SCRIPT_DIR}/service-ctl.sh" ]; then
    SERVICE_CTL_SOURCE="${SCRIPT_DIR}/service-ctl.sh"
    return 0
  fi

  if [ -n "$SERVICE_CTL_URL" ]; then
    return 0
  fi

  if [ -f "$SERVICE_CTL_TARGET" ]; then
    log "未找到同目录 service-ctl.sh，将保留已存在的 $SERVICE_CTL_TARGET"
    return 0
  fi

  err "未找到 service-ctl.sh。请将 operations/service-ctl.sh 与本脚本放到同一目录（$SCRIPT_DIR），或设置 SERVICE_CTL_SOURCE / SERVICE_CTL_URL。"
  exit 1
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

  # Alibaba Cloud Linux 3 需要将 releasever 映射为兼容的 CentOS 版本
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

  if ! command -v curl >/dev/null 2>&1; then
    log "检测到缺少 curl（健康检查需要），正在安装..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y && apt-get install -y curl
    elif command -v dnf >/dev/null 2>&1; then
      dnf -y install curl
    elif command -v yum >/dev/null 2>&1; then
      yum -y install curl
    fi
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

login_acr() {
  log "正在登录 ACR 镜像仓库: ${ACR_REGISTRY} ..."
  printf '%s' "$ACR_PASSWORD" | docker login --username "$ACR_USERNAME" --password-stdin "$ACR_REGISTRY"
  log "ACR 登录成功（凭证已写入 ${HOME:-/root}/.docker/config.json）"
}

install_service_ctl() {
  target_dir=$(dirname "$SERVICE_CTL_TARGET")
  mkdir -p "$target_dir"

  if [ -n "$SERVICE_CTL_SOURCE" ]; then
    src_real=$(CDPATH='' cd -- "$(dirname -- "$SERVICE_CTL_SOURCE")" && printf '%s/%s' "$(pwd)" "$(basename -- "$SERVICE_CTL_SOURCE")")
    dst_real=$(CDPATH='' cd -- "$target_dir" && printf '%s/%s' "$(pwd)" "$(basename -- "$SERVICE_CTL_TARGET")")
    if [ "$src_real" != "$dst_real" ]; then
      cp "$SERVICE_CTL_SOURCE" "$SERVICE_CTL_TARGET"
    fi
  elif [ -n "$SERVICE_CTL_URL" ]; then
    log "正在从 $SERVICE_CTL_URL 下载 service-ctl.sh ..."
    tmp_file="${SERVICE_CTL_TARGET}.tmp.$$"
    curl -fsSL "$SERVICE_CTL_URL" -o "$tmp_file"
    mv "$tmp_file" "$SERVICE_CTL_TARGET"
  fi

  chmod 755 "$SERVICE_CTL_TARGET"
  sh -n "$SERVICE_CTL_TARGET"

  umask 077
  mkdir -p "$STATE_ROOT"

  log "通用部署脚本已安装就绪: ${SERVICE_CTL_TARGET}"
}

main() {
  require_root
  validate_inputs
  resolve_service_ctl_source
  ensure_docker
  login_acr
  install_service_ctl

  cat <<EOF

====================================================================
ECS 初始化完成！
  - Docker & Compose : 已就绪
  - ACR 仓库已登录   : ${ACR_REGISTRY}
  - 通用发布脚本     : ${SERVICE_CTL_TARGET}
  - 发布状态目录     : ${STATE_ROOT}

安全提醒：
  请及时删除服务器上的本初始化脚本，或清空其中的 ACR_PASSWORD，
  避免明文密码残留在磁盘上（Docker 登录凭证已独立保存）。
====================================================================
EOF
}

main "$@"
