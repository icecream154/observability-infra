# 1. 替换成你的 ACR 公网域名和命名空间
#    个人版示例: registry.cn-hangzhou.aliyuncs.com
#    企业版示例: <实例名>-registry.cn-hangzhou.cr.aliyuncs.com
ACR_PUBLIC="registry.cn-hangzhou.aliyuncs.com"
NAMESPACE="你的命名空间"
PLATFORM="linux/amd64"

# 2. 登录 ACR（公网地址）
docker login "${ACR_PUBLIC}"

# 3. 按 ECS 架构拉取、打标并推送全部 4 个中心镜像
sync_image() {
  src="$1"
  dst="${ACR_PUBLIC}/${NAMESPACE}/$2"
  echo "==> 同步 ${src} -> ${dst} (${PLATFORM})"
  docker pull --platform "${PLATFORM}" "${src}"
  docker tag "${src}" "${dst}"
  docker push "${dst}"
}

sync_image "hyperdx/hyperdx:2.43.1"                         "hyperdx:2.43.1"
sync_image "hyperdx/hyperdx-otel-collector:2.43.1"          "hyperdx-otel-collector:2.43.1"
sync_image "clickhouse/clickhouse-server:26.8.36.3-alpine"  "clickhouse-server:26.8.36.3-alpine"
sync_image "mongo:5.0.32-focal"                             "mongo:5.0.32-focal"