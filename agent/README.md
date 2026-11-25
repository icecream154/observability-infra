# 公共业务采集 Sidecar 镜像 (`log-agent`)

`go-service-template` 与 `python-service-template` 输出完全相同的 15 字段 JSONL 日志结构，并通过同一内部地址 `http://log-agent:4318/v1/traces` 导出 Span。

将本目录构建并推送到私有镜像仓库（如阿里云 ACR）一次后，所有 Go / Python 业务服务均可直接复用该镜像，宿主机无需挂载任何本地采集配置文件，也无需在生产机器直接访问公网 Docker Hub。

## 一次性构建与推送（以阿里云 ACR 杭州个人版为例）

```bash
cd agent
docker login registry.cn-hangzhou.aliyuncs.com

docker buildx build --platform linux/amd64 \
  -t registry.cn-hangzhou.aliyuncs.com/<你的命名空间>/log-agent:v1 \
  --push .
```

同地域阿里云 ECS 通过 `/opt/bin/service-ctl.sh` 拉取时，直接传入对应的专有网络 VPC 地址（如 `registry-vpc.cn-hangzhou.aliyuncs.com/<你的命名空间>/log-agent:v1`）即可免公网流量高速拉取。

## 运行时环境变量契约

| 变量名 | 说明 |
| --- | --- |
| `OTLP_ENDPOINT` | 中心 Collector 的 OTLP HTTP 基础地址（如 `http://10.0.1.5:4318`），自动追加 `/v1/logs` 与 `/v1/traces` |
| `OTLP_AUTH_TOKEN` | 与中心 Collector `.env` 一致的静态认证凭据 |
| `GOMEMLIMIT` | Go 运行时软内存上限（`service-ctl.sh` 默认注入 `200MiB`，配合 `mem_limit: 256m`） |
