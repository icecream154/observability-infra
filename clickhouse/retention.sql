-- 1. 适用 ClickStack 2.43.1 legacy/Map 表结构。先完成平台启动及建表，再手动执行一次。
-- 该版本 OpAMP 使用统一建表 TTL；这里显式设置分类型保留规则。
-- TTL 在后台执行，不能当作即时磁盘容量限制。未来版本执行前需重新核对表和时间列。

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
