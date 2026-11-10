# 多机器采集与 HyperDX 远程访问

中心服务器用同一份 Compose 运行独立 Collector、ClickHouse、HyperDX 和 MongoDB。业务服务器通过 OTLP 将日志和 Span 上传到中心 Collector，HyperDX 从 ClickHouse 查询数据。采集认证使用部署前配置的 `OTLP_AUTH_TOKEN`，不依赖 HyperDX 注册账号或平台生成的团队采集密钥。

## 中心和业务机器的职责

```text
业务机器 A：Go / Python -> 本机日志采集 Agent ─┐
业务机器 B：Go / Python -> 本机日志采集 Agent ─┼-> 中心 Collector -> ClickHouse
业务 SDK 的 Span 也可先发本机 Agent ──────────┘                         ↑
                                                           HyperDX 查询展示
```

中心的 Compose 只管理中心服务器上的容器。读取日志文件的 Agent 应部署在文件所在的业务机器上，可随业务自己的 Compose 或进程管理器启动；中心服务器的目录挂载无法读取另一台机器上的本地文件。

同一机器上的一个 Agent 可以采集多个业务服务。每个服务保持正确的 `service.name`、`service.instance.id` 和环境资源属性，以便中心区分服务、实例和环境。文件采集需要解析 JSON，并把 `trace_id`、`span_id` 映射为标准 TraceId、SpanId；业务 SDK 负责生成和导出实际 Span。

## 地址和凭据配置

| 配置 | 用途 |
| --- | --- |
| `OTLP_BIND_ADDRESS` | 中心 Collector 发布采集端口的宿主机监听地址；默认 `0.0.0.0`，也可填写中心内网网卡地址或 `127.0.0.1` |
| `OTLP_HTTP_PORT` | 宿主机 OTLP HTTP 端口，默认 `4318`，可承载日志、Trace 和指标 |
| `OTLP_GRPC_PORT` | 宿主机 OTLP gRPC 端口，默认 `4317`，与 HTTP 是不同传输协议 |
| `OTLP_AUTH_TOKEN` | 提前配置的采集凭据；中心接收端和发送端使用同一值，与 HyperDX 登录会话密钥、ClickHouse 密码分别管理 |
| `HYPERDX_BIND_ADDRESS` | HyperDX 前端发布到宿主机的监听地址，默认 `0.0.0.0` |
| `HYPERDX_APP_PORT` | 前端端口，默认 `18080` |
| `HYPERDX_PUBLIC_URL` | 浏览器实际访问的完整前端地址，包含 `http://` 或 `https://`，需要非默认端口时也包含端口 |

`0.0.0.0` 是监听地址，不能填写到浏览器 URL 或远端发送目标中。远端发送端应使用中心服务器可达的 IP 或域名；它们不能依赖中心 Compose 内部的 `collector`、`clickhouse`、`mongodb` 服务名。

中心容器之间继续使用 Docker 服务名：Collector 写 `clickhouse:9000`，HyperDX 查询 `clickhouse:8123` 并连接 `mongodb:27017`。ClickHouse、MongoDB、Collector 健康端口及 HyperDX OpAMP 无需发布给业务机器。

## 直接通过 HTTP 访问

HyperDX 原生提供 HTTP 服务，不需要先安装 Nginx 才能从其他电脑访问。假设中心服务器在可信内网中的可达地址为 `10.0.0.10`，可以在中心 `.env` 中设置：

```dotenv
HYPERDX_BIND_ADDRESS=0.0.0.0
HYPERDX_APP_PORT=18080
HYPERDX_PUBLIC_URL=http://10.0.0.10:18080

OTLP_BIND_ADDRESS=0.0.0.0
OTLP_HTTP_PORT=4318
OTLP_GRPC_PORT=4317
```

浏览器访问 `http://10.0.0.10:18080`。业务侧的 OTLP HTTP 基础地址使用 `http://10.0.0.10:4318`，日志路径为 `/v1/logs`，Trace 路径为 `/v1/traces`；发送端携带 `Authorization: Bearer <OTLP_AUTH_TOKEN>`。使用具体 SDK 时，按照它对基础地址或完整信号路径的要求配置。

也可以将 `0.0.0.0` 换成中心服务器实际存在的内网网卡地址，以限制监听范围。服务器网络规则应允许指定业务机器访问选用的采集端口，以及管理电脑访问前端入口。

直接公网 IP 加端口在网络可达时同样可以提供 HTTP 页面，但登录和采集凭据会经明文 HTTP 传输。公网部署使用下一节的 HTTPS 入口；HTTP 直连适用于可信内网或受保护网络中的联调。

`HYPERDX_PUBLIC_URL` 必须与浏览器实际入口一致。它在容器中映射为 `FRONTEND_URL`，影响登录跳转、Cookie 域名及 secure 属性、跨域和邀请链接。默认的 `http://localhost:18080` 仅用于本机；在远端浏览器中 `localhost` 指浏览器所在电脑。

## 使用公网 HTTPS 域名

当前 HyperDX 镜像以 HTTP 运行，Compose 中没有为它配置原生 TLS 证书入口。公网 HTTPS 可由宿主机 Nginx、Caddy 或云负载均衡器终止 TLS，再转发到前端 HTTP 端口；Nginx 并非唯一选择。

一种完整的入口划分是：

```text
浏览器 -> https://logs.example.com -> HTTPS 入口 -> 127.0.0.1:18080 -> HyperDX
业务端 -> https://otel.example.com -> HTTPS 入口 -> 127.0.0.1:4318  -> Collector
```

这里的域名是占位示例，需替换为实际解析到中心服务器或负载均衡器的域名，并为 HTTPS 入口准备匹配的证书。

如果 HTTPS 入口运行在同一台宿主机，可以使用以下绑定，使原始 HTTP 端口只在中心本机可达：

```dotenv
HYPERDX_BIND_ADDRESS=127.0.0.1
HYPERDX_PUBLIC_URL=https://logs.example.com

OTLP_BIND_ADDRESS=127.0.0.1
```

此时外部业务端统一发送到 `https://otel.example.com` 的 OTLP HTTP 入口；它们不能再直连中心的 `4317/4318`。日志与 Span 均可通过 OTLP HTTP 上传，因此不必同时开放 gRPC。如果必须采用 OTLP gRPC，另行配置支持 HTTP/2 与 gRPC 的 TLS 入口。

宿主机 Nginx 的参考配置见 [nginx-hyperdx.conf.example](nginx-hyperdx.conf.example)。复制前填写真实域名、证书路径及上游端口；该示例不会自动被 Compose 或 Nginx 加载，也不会申请证书。若使用的 HTTPS 入口运行在其他机器或容器中，应把上游地址改为它实际可达的地址；其 `127.0.0.1` 指该入口自身。

## 前端端口和内部 API 的区别

普通浏览器只需要访问 HyperDX 前端入口。页面请求同源的 `/api/...`，Next.js 前端再向同容器中的 API 转发，所以 `18001` 不必对其他电脑开放。

`SERVER_URL` 继续使用容器内部的 `http://127.0.0.1:<HYPERDX_API_PORT>`；它不是浏览器入口，不能机械地替换成公网域名。HTTPS 入口将整个站点代理到前端端口，并保留 Host 及转发协议等请求头。

独立 Collector 不再使用 HyperDX 的团队采集密钥。HyperDX UI 内的 Add Data 安装示例可能仍展示其平台生成的密钥或默认地址；业务发送端以本项目实际配置的中心 OTLP 地址和 `OTLP_AUTH_TOKEN` 为准。

## 部署时应用配置

修改中心 `.env` 或 Compose 的监听地址、外部 URL、凭据后，由部署方执行 `docker compose up -d` 应用容器配置变化。单纯 `docker compose restart` 不会把新的容器环境变量写入已有容器。

`HYPERDX_PUBLIC_URL`、DNS、证书和网络入口需要描述同一个访问方式。改变展示入口不需要改变 Collector 写入 ClickHouse 的内部地址；改变中心采集凭据时，需要同步更新所有发送端使用的凭据。

参考：[HyperDX 地址配置](https://clickhouse.com/docs/clickstack/managing/config#network-and-storage)、[独立 UI 部署](https://clickhouse.com/docs/clickstack/deployment/hyperdx-only)、[Docker 端口发布](https://docs.docker.com/engine/network/port-publishing/)、[OpenTelemetry 网关部署](https://opentelemetry.io/docs/collector/deploy/gateway/)。
