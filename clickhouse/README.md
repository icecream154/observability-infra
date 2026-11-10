# ClickHouse 存储配置

`config.d/observability.xml` 管理 ClickHouse 自身的文本日志、诊断表和内部 `9363/metrics` 指标入口。官方镜像的主配置继续生效，业务遥测表由 ClickStack Collector 创建；`retention.sql` 管理实际分类型保留规则。

## 数据和账号

Compose 初始化 `otel` 数据库及 `observability` 用户，密码来自 `.env`。当前本地起步配置让 UI 和 Collector 共用此用户；供多服务长期使用前，再拆分写入、查询和运维权限。

默认采用官方 legacy/Map 表结构，以匹配 Compose 中的数据源定义：

- `otel_logs`：日志明细，包含标准 TraceId、SpanId 和结构化属性。
- `otel_traces`：Span 明细，包含 ParentSpanId、Duration、StatusCode 等。
- `otel_metrics_*`：Gauge、Sum、Histogram 等指标类型对应的表。

不要同时手工创建一套同名但字段不同的表。首次建表的时间取决于官方 Collector 的初始化和数据导出流程。

## 保留期限

2.43.1 的 legacy/OpAMP 路径只读取统一的 `HYPERDX_OTEL_EXPORTER_TABLES_TTL`。Compose 从 `.env` 的 `TABLES_RETENTION=720h` 注入该参数；原先的分信号环境变量在此路径中不生效，已移除。

`retention.sql` 根据本机实际建表结构设置以下策略，已经执行并通过 `system.tables.create_table_query` 核验：

| 表 | 保留规则 |
| --- | --- |
| `otel_logs` | `Timestamp` 起 7 天 |
| `otel_traces` | `Timestamp` 起 7 天 |
| `otel_traces_trace_id_ts` | `Start` 起 7 天，与主 Span 表一致 |
| 五类 `otel_metrics_*` 表 | `TimeUnix` 起 30 天 |

`otel_traces_trace_id_ts_mv` 是不独立存储数据的物化视图，TTL 设置在其目标索引表上。Session 表仍使用统一默认 30 天，本项目尚未接入 Session 数据。

新环境先启动 Collector 完成建表，再按根 README 执行 `retention.sql`。此文件适用于当前固定版本的表结构，未来升级或修改期限时，应先检查实际建表语句和关联表，不要无条件套用。修改 `.env` 不会迁移已有表。

ClickHouse 自身的文本日志设置为 warning 级别并轮转；配置中列出的系统诊断表使用 3 天或 7 天 TTL。它们仍可能在后台清理前占用额外空间，新增诊断表也要纳入检查。

## 容量与持久化

`.data/clickhouse/` 和 `.data/clickhouse-logs/` 是宿主机绑定目录。目录绑定不会自动提供硬配额；需要宿主机文件系统、专用分区或存储系统实施容量限制。

TTL 删除在后台执行，数据合并也会临时占用空间。不能将磁盘接近 100% 才清理作为正常策略。自动水位治理尚未实现，见 [运维说明](../operations/README.md)。

参考：[ClickStack TTL](https://clickhouse.com/docs/clickstack/managing/ttl)、[ClickHouse TTL 执行机制](https://clickhouse.com/docs/concepts/features/operations/delete/ttl)。
