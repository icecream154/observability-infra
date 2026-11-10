# 统计看板

本目录用于保存经过验证的 ClickStack 看板导出定义及配套查询。当前没有预置看板文件，也没有在启动时自动导入看板；平台 UI 中的实际配置持久化于 MongoDB。

后续每个看板应注明适用平台版本、数据源、查询时间范围、字段依赖、统计口径和导入方式。优先通过官方 UI/API 管理，不直接修改 MongoDB 内部文档结构。

## 计划增加的看板

| 看板 | 数据来源 | 统计口径 |
| --- | --- | --- |
| HTTP 接口概览 | HTTP 入口 Counter、Histogram | 调用次数、结果分布、平均耗时、P95/P99 |
| 外部依赖 | Company / SDK Client 指标和 Span | 调用次数、错误、耗时、失败明细 |
| 服务运行状态 | Go 运行时和进程指标 | CPU、RSS、堆、GC、Goroutine |
| 平台自身运行状态 | Collector、ClickHouse、宿主机指标 | 积压、丢弃、存储增长和剩余容量 |

这些指标尚未在业务项目中接入，当前不能承诺直接显示结果。

## 查询约定

1. HTTP 接口统计使用服务、环境、HTTP 方法和注册路由模板等有限维度。
2. 不把同一次请求的 Controller、Service、Client Span 全部累加成接口调用次数。
3. 常规次数统计使用独立 Counter，处理累计值重置；耗时使用 Histogram。不要依赖采样后的 Span 推算完整请求总量。
4. 如果临时通过 `http_entry` 的 `finished` 日志统计，必须注明这是已采集完成日志的数量，可能受丢失、重复和保留范围影响。
5. TraceId、SpanId、用户 ID 等高基数字段用于明细关联，不直接作为常规指标维度。

参考：[ClickStack SQL 图表](https://clickhouse.com/blog/clickstack-sql-charting-and-alerting)。
