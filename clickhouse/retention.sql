-- 1. 可选策略，适用当前 ClickStack 2.43.1 legacy/Map 表结构。
-- 独立 Collector 在表不存在时负责创建表，统一建表默认 TTL 由 TABLES_RETENTION 管理。
-- 本项目在 collector/custom.yaml 覆盖 standalone 导出器的默认 TTL，使该部署参数继续生效。
-- 如果接受日志、Span 和指标统一使用默认 720h（30 天），新环境可以不执行本文件。
-- 本文件不被 Compose 自动加载；只有在需要以下分类型策略时，才在相关表创建后手动执行。
-- 执行方式见根 README：通过 clickhouse-client --multiquery 将本文件内容发送给数据库。
-- ALTER 保存的规则属于表定义，随 .data/clickhouse/ 持久化，后续清理由数据库自动进行。
-- 仅编辑此文件、修改 .env 或重启 Collector 都不会自动迁移已有表的 TTL。
-- 已改成 7 天的表不会因“不再执行本文件”恢复 30 天，恢复仍需相应 ALTER SQL。
-- TTL 在后台执行，不能当作即时磁盘容量限制；修改规则会影响已有和新增数据的到期处理。
-- 未来版本执行前需重新核对表、时间列和目标期限。本次配置修改没有执行这些 SQL。

-- 2. 日志、Span 及 TraceId 查询索引保留 7 天；物化视图本身不存数据，不单独设置 TTL。
ALTER TABLE otel.otel_logs MODIFY TTL toDateTime(Timestamp) + INTERVAL 7 DAY DELETE;
ALTER TABLE otel.otel_traces MODIFY TTL toDateTime(Timestamp) + INTERVAL 7 DAY DELETE;
ALTER TABLE otel.otel_traces_trace_id_ts MODIFY TTL toDateTime(Start) + INTERVAL 7 DAY DELETE;

-- 3. 各类指标保留 30 天，与累计指标和耗时分布分析的时间范围一致。
ALTER TABLE otel.otel_metrics_gauge MODIFY TTL toDateTime(TimeUnix) + INTERVAL 30 DAY DELETE;
ALTER TABLE otel.otel_metrics_sum MODIFY TTL toDateTime(TimeUnix) + INTERVAL 30 DAY DELETE;
ALTER TABLE otel.otel_metrics_histogram MODIFY TTL toDateTime(TimeUnix) + INTERVAL 30 DAY DELETE;
ALTER TABLE otel.otel_metrics_exponential_histogram MODIFY TTL toDateTime(TimeUnix) + INTERVAL 30 DAY DELETE;
ALTER TABLE otel.otel_metrics_summary MODIFY TTL toDateTime(TimeUnix) + INTERVAL 30 DAY DELETE;
