# ClickHouse 存储配置

`config.d/observability.xml` 管理 ClickHouse 自身的文本日志、诊断表和内部 `9363/metrics` 指标入口。官方镜像的主配置继续生效，业务遥测表由独立模式的 ClickStack Collector 导出器创建；`retention.sql` 是可选的分类型保留策略，不会被 Compose 自动执行。

## 数据和账号

Compose 初始化 `otel` 数据库及 `observability` 用户，密码来自 `.env`。当前起步配置让 UI 和 Collector 共用此用户；供多服务长期使用前，再拆分写入、查询和运维权限。Collector 使用 `CLICKHOUSE_PASSWORD` 连接数据库，业务发送端则使用预先配置的 `OTLP_AUTH_TOKEN` 访问 Collector，两者用途不同。

ClickHouse 端口不发布给业务机器。中心 Collector 使用 Compose 内部的 `clickhouse:9000` 写入，HyperDX 使用 `http://clickhouse:8123` 查询；远端 Go/Python 仅需连接中心的 OTLP 入口。HyperDX 的账号注册和团队采集密钥不再控制本项目的采集管道。

默认采用官方 legacy/Map 表结构，以匹配 Compose 中的数据源定义：

- `otel_logs`：日志明细，包含标准 TraceId、SpanId 和结构化属性。
- `otel_traces`：Span 明细，包含 ParentSpanId、Duration、StatusCode 等。
- `otel_metrics_*`：Gauge、Sum、Histogram 等指标类型对应的表。

不要同时手工创建一套同名但字段不同的表。首次建表的时间取决于官方 Collector 的初始化和数据导出流程。

## 保留期限

Compose 将 `.env` 的 `TABLES_RETENTION`（默认 `720h = 30 天`）传入 `HYPERDX_OTEL_EXPORTER_TABLES_TTL`。当前镜像 standalone 配置原本把导出器 TTL 写死为 `720h`，本项目在 `collector/custom.yaml` 中为 `clickhouse` 和 `clickhouse/rrweb` 两个导出器显式覆盖为上述环境变量，因而可以继续用一个部署参数管理新表的统一默认期限。

新环境接受统一默认期限时，不必执行 `retention.sql`。如果希望日志和 Span 保存 7 天、指标保存 30 天，可在对应表已经创建后，手动执行此文件：

| 表 | 保留规则 |
| --- | --- |
| `otel_logs` | `Timestamp` 起 7 天 |
| `otel_traces` | `Timestamp` 起 7 天 |
| `otel_traces_trace_id_ts` | `Start` 起 7 天，与主 Span 表一致 |
| 五类 `otel_metrics_*` 表 | `TimeUnix` 起 30 天 |

`otel_traces_trace_id_ts_mv` 是不独立存储数据的物化视图，TTL 设置在其目标索引表上。Session 表继续使用统一建表默认期限，本项目尚未接入 Session 数据。

SQL 执行后，TTL 存入数据库表定义，并随 `.data/clickhouse/` 持久化。后续过期清理由 ClickHouse 执行，不需要每天或每次重启重复运行 SQL 文件。仅编辑文件或修改 `.env` 不会迁移已有表；已有表曾设为 7 天时，不再执行该文件也不会自动恢复 30 天。恢复或调整需显式执行相应 `ALTER TABLE ... MODIFY TTL`。

可选 SQL 的执行方式见根 README，执行前应确认所需表已存在及目标保留期限。文件适用于当前固定版本的 legacy/Map 表结构，升级或修改期限时需先检查实际建表语句和关联表。实际生效值以 `SHOW CREATE TABLE otel.otel_logs` 等返回的 TTL 为准；本轮配置改动没有连接数据库读取或修改实际 TTL。

ClickHouse 自身的文本日志设置为 warning 级别并轮转；配置中列出的系统诊断表使用 3 天或 7 天 TTL。它们仍可能在后台清理前占用额外空间，新增诊断表也要纳入检查。

## 容量与持久化

`.data/clickhouse/` 和 `.data/clickhouse-logs/` 是宿主机绑定目录。目录绑定不会自动提供硬配额；需要宿主机文件系统、专用分区或存储系统实施容量限制。

TTL 删除在后台执行，数据合并也会临时占用空间。不能将磁盘接近 100% 才清理作为正常策略。自动水位治理尚未实现，见 [运维说明](../operations/README.md)。

参考：[ClickStack TTL](https://clickhouse.com/docs/clickstack/managing/ttl)、[ClickHouse TTL 执行机制](https://clickhouse.com/docs/concepts/features/operations/delete/ttl)。
