# 运维职责

本目录记录容量治理、备份、恢复和升级约定，并提供手动运行的 MongoDB 数据迁移脚本。当前没有定时任务或自动备份。

## 多机器采集与远程访问

中心 Collector、ClickHouse、HyperDX、MongoDB 仍由同一份 Compose 管理。Collector 使用独立采集配置和预配置凭据，业务机器通过中心可达的 OTLP 地址上传日志、Span；读取日志文件的 Agent 部署在各自业务机器上。

完整地址配置、直接 HTTP 访问和公网 HTTPS 的选择见 [多机器采集与 HyperDX 远程访问](remote-access.md)。HyperDX 原生支持发布 HTTP 端口供其他电脑访问；公网 HTTPS 可由 Nginx、Caddy 或云负载均衡器提供，核心 Compose 不强制增加代理服务。

[宿主机 Nginx 示例](nginx-hyperdx.conf.example) 包含整个 HyperDX 站点的 HTTPS 转发，以及可选 OTLP HTTP HTTPS 入口。示例不自动加载或申请证书；域名、证书、端口和网络入口由部署方按实际环境配置。

## 当前配置已覆盖

- ClickHouse 使用 `.data/` 下的绑定目录，MongoDB 使用挂载到 `/data/db` 的 Docker 命名卷 `mongodb-data`。容器正常替换时复用这些数据。
- 每个容器自身日志轮转，以及 ClickHouse 文本日志和部分系统表保留规则。
- 遥测新建表的统一保留参数，以及可选的分类型保留规则 SQL；已有表以实际表定义为准。
- 容器内存限制和 Collector 内存保护。
- 独立 Collector 的静态采集认证，以及可配置的远程采集、HyperDX 访问入口。

这些措施不等于总磁盘容量上限，也不等于备份。单机磁盘故障仍会影响整个部署。

## 后续容量治理

容量预算应覆盖遥测表、数据库诊断表、合并临时空间、MongoDB、容器日志、客户端原始日志和采集队列；以后还应包括 Profile 和备份。

| 项目 | 待实施方式 |
| --- | --- |
| 硬上限 | 专用分区或文件系统/存储卷配额，隔离系统及业务磁盘 |
| 日常保留 | 按数据类型配置 TTL，定期核验实际表策略 |
| 水位监控 | 监控空间占比、增长速度、剩余可用时间 |
| 自动治理 | 根据明确策略清理最旧数据，清理后复查空间；使用数据库支持的方式，不能删除内部文件 |
| 摄入保护 | 无法及时释放空间时限制摄入，并记录拒收或丢弃量 |

70% 告警、80% 清理、90% 摄入保护可以作为后续讨论的起始水位，当前并未生效。必须预留数据合并和清理本身的空间。

配置硬上限后，持续超量写入时仍需要明确是缩短历史保留期还是停止接收新数据，不能同时承诺无限写入、固定磁盘和永不丢数据。

## 旧版 MongoDB 数据迁移

旧配置将宿主机 `.data/mongodb/` 绑定到 MongoDB 的 `/data/db`。Docker Desktop 在重新打开已有的 WiredTiger 文件时可能返回 `Operation not permitted`。当前配置使用 Docker 管理的 `mongodb-data` 卷，默认实际卷名为 `observability-infra_mongodb-data`。 [MongoDB 镜像的存储说明](https://github.com/docker-library/docs/blob/master/mongo/README.md#where-to-store-data)

已有旧目录且希望保留 HyperDX 账号、看板等平台状态时，在项目根目录先运行迁移脚本，再启动 Compose。迁移沿用写入旧数据时的 `MONGODB_IMAGE` 版本。

```bash
./operations/migrate-mongodb-to-volume.sh
```

脚本停止 `app` 和 `mongodb`，把旧目录的全部文件（包括 journal）复制到空的命名卷，并在卷内调整文件属主。它保留原目录，发现目标卷已有文件时会停止。复制成功后再执行下面的命令，然后登录 HyperDX 确认已有账号和看板。

```bash
docker compose up -d
```

首次部署时，直接运行 `docker compose up -d` 由 Compose 创建卷。普通 `docker compose down` 保留卷，`docker compose down --volumes` 会删除这个卷及其中的 HyperDX 平台数据。

## 备份和恢复

后续备份必须包含 ClickHouse 数据、MongoDB 平台状态以及恢复所需的配置。备份存放在独立位置并有独立保留规则；复制正在写入的数据库目录不能直接当作一致性备份。

备份任务需先约定可接受的数据损失范围和恢复时间，再选择数据库原生备份或经过验证的一致性方案，并完成恢复演练。当前没有自动执行备份。

## 升级流程

1. 阅读 UI/API、Collector、ClickHouse 和 MongoDB 的版本兼容说明。
2. 保存有效配置并完成可恢复备份。
3. 在独立环境检查建表、日志解析、Trace 关联、看板和保留策略。
4. 更新固定镜像版本后部署；如发生数据库格式或表结构迁移，不能假设仅换回旧镜像即可回滚。

参考：[ClickStack 生产部署](https://clickhouse.com/docs/clickstack/managing/production)、[OpenTelemetry Collector 可靠性](https://opentelemetry.io/docs/collector/resiliency/)。
