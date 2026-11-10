# 采集配置

`custom.yaml` 是中心 ClickStack Collector 的合并配置：通过 `CUSTOM_OTELCOL_CONFIG_FILE` 加载，覆盖内置 `memory_limiter` 和 `batch` 的参数。它不能作为普通 OpenTelemetry Collector 的完整配置独立运行。

中心 Collector 使用官方内置流程，并通过 `OPAMP_SERVER_URL=http://app:4320` 获取平台接收配置和认证信息。不要直接替换容器启动命令或丢弃官方认证、导出和表结构配置。

## 当前已配置

- OTLP HTTP/gRPC 接收入口，默认仅供本机访问。
- 向 ClickHouse 的 `otel` 数据库导出。
- 数据库自身指标从容器内部 `clickhouse:9363/metrics` 抓取；这不包含业务服务指标。
- 统一建表默认 TTL 为 `720h`；实际分类型策略由 `clickhouse/retention.sql` 设置。
- 内存保护：768 MiB 限制、128 MiB 瞬时分配预算，与容器 1 GiB 限额配合。
- 批处理：达到 1000 条或等待 5 秒发送，每批最多 2000 条；条数不是字节数。

业务发送端需要使用 UI 生成的采集密钥作为 `authorization` 请求头。该密钥与平台会话密钥、ClickHouse 密码不同。

首次创建账号前尚无 Team/API Key，官方 OpAMP 不会启用 OTLP 接收器；此时容器和 `13133/` 健康检查仍可以正常。创建账号后再验收 4317/4318 的认证接收，不能把无账号状态下的端口未接收误报为进程故障。

## 后续客户端采集

当前未部署节点 Collector，也未挂载 Docker socket 或业务日志目录。后续先明确日志来源，再加入客户端采集配置，不应让中心配置猜测宿主机日志路径。

客户端应读取受轮转管理的单行 JSON 日志，保存读取位置，批量通过 OTLP 转发。需要验证如下映射，不能只把 JSON 整体作为不可解析的正文上传：

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

这张表是接入约定，当前 `custom.yaml` 尚未实现上述客户端转换。Span 通过 SDK 独立导出，不能根据普通日志重建真实父子关系。

## 可靠性边界

当前中心配置没有新增持久化发送队列，不承诺故障期间不丢数据。后续客户端采集需补充读取位置、持久发送队列、有界重试、积压和丢弃监控，并把其磁盘空间纳入总容量预算。

客户端和中心在同一台机器部署时，应避免同时占用宿主机 `4317/4318`；容器内通信可以使用服务名和内部端口，不必全部映射到宿主机。
