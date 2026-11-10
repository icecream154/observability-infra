# 中心采集配置

中心继续使用固定版本的官方 ClickStack Collector 镜像，但运行在 **standalone 独立模式**：Compose 将 `OPAMP_SERVER_URL` 显式设为空字符串，Collector 不再等待 HyperDX 下发配置或生成团队采集密钥。它只在启动时等待 ClickHouse 就绪，接收日志、Span 和指标并写入 `otel` 数据库。HyperDX、MongoDB、ClickHouse 和 Collector 仍由中心服务器上的同一份 Compose 管理。

`custom.yaml` 是镜像配置的合并片段，通过 `CUSTOM_OTELCOL_CONFIG_FILE` 加载。镜像入口脚本组合内置基础配置、独立模式管道、静态令牌认证配置和本文件。它保留镜像内置的日志转换、路由和 legacy/Map 导出流程，不能作为普通 OpenTelemetry Collector 的完整配置独立运行。

## 提前配置采集认证

首次部署前在中心 `.env` 中填写随机的 `OTLP_AUTH_TOKEN`。Compose 要求它非空，Collector 通过这个值启用 OTLP HTTP/gRPC 的 bearer-token 认证。该密钥由部署配置管理，不需要先启动 HyperDX、注册用户或从网页复制团队 Ingestion API key。普通重启复用同一值。

发送端为日志和 Span 的 OTLP 请求设置相同认证头，例如 `authorization: Bearer <OTLP_AUTH_TOKEN>`。当前镜像也兼容不带 `Bearer ` 前缀的密钥值。环境变量、SDK YAML 或部署 Secret 只是交付凭据的方式，业务应用或本机 Agent 仍须实际将其配置到导出器请求头。

以下三种凭据用途不同：

| 配置 | 谁使用 | 用途 |
| --- | --- | --- |
| `OTLP_AUTH_TOKEN` | 业务 SDK / Agent 和中心 Collector | 上传日志、Span、指标 |
| `CLICKHOUSE_PASSWORD` | Collector、HyperDX | 连接数据库 |
| `EXPRESS_SESSION_SECRET` | HyperDX | 保护网页登录会话 |

HyperDX 页面仍可管理它自己的团队密钥，但这些密钥不再控制本项目独立 Collector 的接收器。更换中心 `OTLP_AUTH_TOKEN` 时应同步更新发送端并应用相应进程配置。

## 多机器接入与地址

中心 OTLP 发布地址由 `OTLP_BIND_ADDRESS` 控制，默认 `0.0.0.0`，以接收其他业务机器上传；也可指定中心机器实际持有的内网 IP。`OTLP_GRPC_PORT` 和 `OTLP_HTTP_PORT` 控制宿主机发布端口，容器内分别固定为 `4317` 和 `4318`。

| 发送端所在位置 | 使用的地址 |
| --- | --- |
| 与中心 Collector 同一 Compose 网络 | `collector:4317` 或 `http://collector:4318` |
| 中心服务器宿主机 | `127.0.0.1` 加对应发布端口 |
| 其他业务机器 | 中心服务器可达的内网 IP、域名或 OTLP TLS 入口 |

远端业务机器不能使用中心 Docker 网络里的 `collector` 服务名，也不能用自己的 `localhost` 指代中心服务器。OTLP HTTP 基础地址后分别使用 `/v1/logs`、`/v1/traces`、`/v1/metrics`；SDK 若接收的是基础地址，会自行追加信号路径，应按对应 SDK 的参数语义配置。

对外发布采集端口需要配合网络访问规则。默认接收器为 HTTP/gRPC 明文，公网链路应通过 TLS 入口或相应的接收器 TLS 配置保护凭据和数据。业务机器只需访问采集入口，ClickHouse、MongoDB、数据库自身指标和健康检查端口仍可留在中心 Docker 网络内部。

## 当前配置的处理与导出

- OTLP HTTP/gRPC 接收器同时支持日志、Span 和指标；两端口区分协议，不按数据类型划分。
- 向 ClickHouse 的 `otel` 数据库导出，写入地址使用中心内部的 `clickhouse:9000`。
- 通过独立的 Prometheus 接收器抓取 `CLICKHOUSE_METRICS_TARGET` 指向的数据库自身指标，默认是 `clickhouse:9363/metrics`；这不自动抓取远端 Go/Python 指标。
- **不设置** `CLICKHOUSE_PROMETHEUS_METRICS_ENDPOINT`：该镜像独立模式将它解释为可接受 `/write` 的 remote-write 目标，而本项目 `9363` 提供的是指标抓取端点。
- 镜像内置 standalone 导出器将 TTL 写为 `720h`，本项目在 `custom.yaml` 中覆盖 `clickhouse` 和 `clickhouse/rrweb` 两个导出器，使 `.env` 的 `TABLES_RETENTION` 继续控制统一建表默认期限。
- 新表默认保留 30 天；如需要分类型期限，可在表创建后手动执行可选的 `clickhouse/retention.sql`。该文件不会被 Compose 自动执行，详情见 [存储说明](../clickhouse/README.md)。
- 内存保护硬阈值 768 MiB，软阈值 `768 - 128 = 640 MiB`，与容器默认 1 GiB 限额配合；测量对象为 Collector 的 Go 堆，不是整个容器总内存。
- 批处理达到 1000 个记录/数据点触发发送，未满时定时发送，单批最多 2000 个；条数不是字节数，5 秒也不是端到端落库时限。

镜像继承的 `13133` 健康检查反映 Collector 进程状态，不等同于业务认证、写入、页面展示或跨机网络已经确认可用。本轮仅更新配置与说明，没有执行测试、发送验收数据或核验运行中的链路。

## 业务机器上的客户端采集

当前中心项目没有部署业务机器上的节点 Collector，也未挂载业务日志目录或 Docker socket。每台业务机器应按自己的运行方式配置本机 Agent，读取本机日志并发送到中心。一台机器上的 Agent 可以服务多个业务进程；中心服务器的目录挂载不能读取另一台机器上的日志文件。

客户端应读取受轮转管理的单行 JSON 日志，保存读取位置，批量通过带认证的 OTLP 转发。接入时应配置如下映射，使正文和关联字段进入标准位置：

| 项目日志字段 | OpenTelemetry 目标 | 含义 |
| --- | --- | --- |
| `timestamp` | 日志 Timestamp | 事件时间，保留原始时区和精度 |
| `level` | SeverityText / SeverityNumber | 日志级别 |
| `message` | Body | 人类可读的消息 |
| `trace_id` | TraceId | 请求链路标识；需转换为标准字段 |
| `span_id` | SpanId | 所属调用节点；允许没有 Span 的日志省略 |
| `service_name` | Resource `service.name` | 服务标识 |
| `environment` | Resource `deployment.environment.name` | 运行环境 |
| `instance_id` | Resource `service.instance.id` | 进程实例 |
| `component`、`operation`、`event`、`caller` 等 | Log Attributes | 结构化查询字段 |

这张表是接入约定，中心 `custom.yaml` 不负责读取各台业务机器的文件并完成该客户端映射。Span 由各语言 SDK 导出，可先发本机 Agent 后统一转发，也可直接发中心；普通日志本身不能重建真实父子关系。`service.name`、环境和 `service.instance.id` 应能区分不同服务及实例，多来源汇聚不自动提供租户隔离。

## 可靠性边界

内存保护、批处理和重试分别解决流量压力、传输效率和暂时失败，不等于持久存储。磁盘队列是否存在，以最终导出器的 `sending_queue.storage` 和对应 `file_storage` 实际配置为准；客户端还需保存日志读取位置、配置有界缓冲/重试，并把队列空间纳入本机容量预算。进程退出、队列耗尽、源文件先被轮转清理或长期下游不可用都可能影响交付。

客户端和中心在同一台机器部署时，应避免同时占用宿主机 `4317/4318`；容器内通信可以使用服务名和内部端口，不必全部映射到宿主机。

参考：[对应版本入口脚本](https://github.com/hyperdxio/hyperdx/blob/821c2f93357b47d5ff932ea99d2adf93289815a5/docker/otel-collector/entrypoint.sh)、[独立模式认证](https://github.com/hyperdxio/hyperdx/blob/821c2f93357b47d5ff932ea99d2adf93289815a5/docker/otel-collector/config.standalone.auth.yaml)、[OpenTelemetry 网关部署模式](https://opentelemetry.io/docs/collector/deploy/gateway/)。
