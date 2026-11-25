# 生产 / 测试环境完整部署指南

本文提供从零搭建 **中心可观测平台（`observability-infra`）**、**Nginx HTTPS 接入**、**公共采集镜像（`log-agent`）构建** 到 **业务 ECS 初始化与 CI/CD 接入** 的端到端操作步骤。

## 整体分工一览

| 角色 | 是否需要自建镜像 | 部署方式 | 对应脚本 / 目录 |
| --- | --- | --- | --- |
| **中心可观测服务器**（1 台，有状态） | **否**（直接用官方固定版本镜像，或转存到自有 ACR） | 拉取本仓库，用一键脚本生成 `.env` 并启动 `docker compose` | [deploy-center.sh](deploy-center.sh) |
| **公共采集边车 `log-agent`** | **是**（全团队仅构建一次，推到 ACR） | 本地或 CI 执行 `docker buildx build --push` | [../agent/](../agent/README.md) |
| **业务 ECS 服务器**（多台，无状态） | 否（业务镜像由各自项目流水线构建） | 每台新机器执行一次初始化脚本，日常由流水线调用 `/opt/bin/service-ctl.sh` | [init-ecs.sh](init-ecs.sh)、[service-ctl.sh](service-ctl.sh) |

---

## 第 1 步：中心可观测服务器一键部署

建议中心 ECS 至少 **8 GiB 内存**（默认限额：ClickHouse 4G + HyperDX 2G + MongoDB 1G + Collector 1G，可在脚本中按机器规格调低）。

### 1.1 拉取仓库到中心服务器

```bash
git clone <你的 observability-infra 仓库地址> /opt/observability-infra
cd /opt/observability-infra
```

### 1.2 编辑部署脚本填写配置

编辑 [deploy-center.sh](deploy-center.sh) 顶部的配置变量：

```bash
vi operations/deploy-center.sh
```

至少填写 `HYPERDX_PUBLIC_URL`，其余字段按实际模式选择：

| 变量 | 说明 |
| --- | --- |
| `HYPERDX_PUBLIC_URL` | **必填**。浏览器访问 HyperDX 的完整地址（不带末尾 `/`），如 `https://logs.example.com` 或 `http://10.0.1.5:18080` |
| `HYPERDX_BIND_ADDRESS` | 若本机前置 Nginx 做 HTTPS，填 `127.0.0.1`；直接 HTTP 访问保持 `0.0.0.0` |
| `OTLP_BIND_ADDRESS` | **同 VPC 内网采集（推荐）**：保持 `0.0.0.0`（或填中心 ECS 内网 IP）；**跨网走本机 Nginx HTTPS 采集**：改为 `127.0.0.1` |
| `CLICKHOUSE_PASSWORD`<br>`EXPRESS_SESSION_SECRET`<br>`OTLP_AUTH_TOKEN` | **可留空**。首次执行会自动生成 64 位随机十六进制并写入 `.env`（权限 `600`）；后续修改配置重复执行时，留空会自动保留 `.env` 中原有密钥（并备份旧文件为 `.env.bak`），不会覆盖已有数据库密码 |
| `ACR_REGISTRY` / `ACR_USERNAME` / `ACR_PASSWORD`<br>`CLICKSTACK_APP_IMAGE` 等 4 个镜像变量 | **可选**。若中心 ECS 拉取 Docker Hub 较慢，可先将 4 个官方镜像同步到自有阿里云 ACR，再填此处覆盖 |

### 1.3 执行一键部署

```bash
sudo sh operations/deploy-center.sh
```

脚本会自动完成：
1. 检查并安装 Docker 与 `docker compose` 插件（默认走阿里云镜像源，兼容 Alibaba Cloud Linux 3 / CentOS / Rocky / Ubuntu / Debian）；
2. 若配置了私有 ACR，自动登录；
3. 生成或安全更新项目根目录 `.env`；
4. 拉取中心 4 个镜像并执行 `docker compose up -d`。

### 1.4 获取采集凭据并清理脚本中的明文密码

```bash
# 查看自动生成的 OTLP_AUTH_TOKEN，后续配置到云效流水线 / 业务机
grep '^OTLP_AUTH_TOKEN=' /opt/observability-infra/.env

# 若刚才在脚本中填过明文密码，执行完立即还原脚本，避免磁盘残留或误提交
git -C /opt/observability-infra checkout -- operations/deploy-center.sh
```

---

## 第 2 步：中心服务器配置 Nginx + SSL（HTTPS）

> 如果仅在可信内网直接通过 `http://<中心IP>:18080` 访问，可跳过本步。

### 2.1 选择接入模式

| 模式 | 适用场景 | `deploy-center.sh` / `.env` 对应配置 | Nginx 需保留的 `server` 块 |
| --- | --- | --- | --- |
| **模式 A：仅网页走 HTTPS，OTLP 走同 VPC 内网（推荐）** | 业务 ECS 与中心 ECS 在同一云厂商同地域 VPC 内（更快、免公网流量费） | `HYPERDX_BIND_ADDRESS=127.0.0.1`<br>`HYPERDX_PUBLIC_URL=https://logs.example.com`<br>`OTLP_BIND_ADDRESS=0.0.0.0`（或中心内网 IP） | 仅保留 `logs.example.com` 的 80 + 443 块，**删除**示例末尾的 `otel.example.com` 块 |
| **模式 B：网页与 OTLP 均走 HTTPS** | 业务机跨地域 / 跨云 / 走公网上报 | `HYPERDX_BIND_ADDRESS=127.0.0.1`<br>`HYPERDX_PUBLIC_URL=https://logs.example.com`<br>`OTLP_BIND_ADDRESS=127.0.0.1` | 保留全部 3 个 `server` 块（`logs.example.com` 与 `otel.example.com`） |

> 修改 `.env` 后必须执行 `docker compose up -d`（或重跑 `deploy-center.sh`）才能让新环境变量生效；仅 `docker compose restart` 不会重新注入环境变量。

### 2.2 准备域名解析与 SSL 证书

1. 在 DNS 控制台将 `logs.example.com`（模式 B 还需 `otel.example.com`）的 A 记录解析到中心 ECS 公网 IP。
2. 准备证书文件（`.pem` 公钥链 + `.key` 私钥），二选一：
   - **阿里云 SSL 证书**：在控制台下载 **Nginx 格式**证书，上传解压到如 `/etc/nginx/ssl/logs.example.com/`；
   - **Certbot（Let's Encrypt 自动续期）**：
     ```bash
     # Ubuntu / Debian
     sudo apt-get update -y && sudo apt-get install -y nginx certbot python3-certbot-nginx
     # Alibaba Cloud Linux / CentOS / Rocky（如用 dnf）
     # sudo dnf install -y nginx certbot python3-certbot-nginx

     sudo certbot certonly --nginx -d logs.example.com
     # 证书默认生成在 /etc/letsencrypt/live/logs.example.com/{fullchain.pem,privkey.pem}
     ```

### 2.3 配置并重载 Nginx

```bash
# 1. 确保 Nginx 已启动并开机自启
sudo systemctl enable --now nginx

# 2. 复制仓库自带的配置模板
sudo cp /opt/observability-infra/operations/nginx-hyperdx.conf.example /etc/nginx/conf.d/hyperdx.conf

# 3. 编辑配置：替换域名与证书路径；模式 A 删掉文件末尾的 otel.example.com server 块
sudo vi /etc/nginx/conf.d/hyperdx.conf

# 4. 检查语法并热重载
sudo nginx -t && sudo systemctl reload nginx
```

配置要点说明（已在 [nginx-hyperdx.conf.example](nginx-hyperdx.conf.example) 中预设）：
- **无需代理 `18001` API 端口**：页面请求同源的 `/api/...`，容器内 Next.js 前端会自动转发至同容器 API，Nginx 只需反代 `http://127.0.0.1:18080`。
- **保留流式与超时参数**：`proxy_buffering off` 与 `proxy_read_timeout 300s` 可避免大范围查询超时或缓冲截断；`X-Forwarded-Proto $scheme` 确保 HTTPS 登录会话正常。
- **模式 B 的 OTLP 代理**：业务机 `--otlp-endpoint` 需直接填 `https://otel.example.com`（不要用 `http://` 依赖重定向），且保留 `client_max_body_size 20m` 与 `proxy_set_header Authorization $http_authorization;`。

### 2.4 中心服务器安全组配置

| 端口 | 模式 A（网页 HTTPS + OTLP 内网） | 模式 B（网页与 OTLP 均走 HTTPS） |
| --- | --- | --- |
| **443** | 对办公网 / 管理员放通 | 对办公网与业务出口放通 |
| **80** | 放通（HTTP 跳 HTTPS / Certbot 续期） | 放通（HTTP 跳 HTTPS / Certbot 续期） |
| **4318**（及可选 4317） | **仅对业务 ECS 所在内网网段 / 安全组放通** | 关闭公网放通 |
| **18080** | 关闭公网放通（已绑定 `127.0.0.1`） | 关闭公网放通（已绑定 `127.0.0.1`） |
| **18001 / 8123 / 9000 / 27017** | 无需放通（仅容器内或回环使用） | 无需放通 |

---

## 第 3 步：构建并推送公共 `log-agent` 镜像（仅需一次）

`agent/` 是 `observability-infra` 仓库中**唯一需要自行构建的镜像**，所有 Go / Python 业务服务共享该边车镜像（详见 [../agent/README.md](../agent/README.md)）：

```bash
cd observability-infra/agent
docker login registry.cn-hangzhou.aliyuncs.com

docker buildx build --platform linux/amd64 \
  -t registry.cn-hangzhou.aliyuncs.com/<你的命名空间>/log-agent:v1.0.0 \
  --push .
```

> **版本标签规范**：务必使用不可变版本标签（如 `v1.0.0`、`v1.0.1`），**不要覆盖旧版本或使用 `latest`**。因为 `service-ctl.sh` 每次发布都会 `docker pull`，覆盖同名标签会导致失败自动回滚拉起的仍是新坏镜像，也无法先在测试环境灰度验证。

---

## 第 4 步：业务 ECS 服务器一次性初始化

每台新购业务 ECS（测试 / 生产）只需执行一次：

1. 将初始化脚本与通用发布脚本一并复制到目标业务 ECS：
   ```bash
   scp operations/init-ecs.sh operations/service-ctl.sh root@<业务ECS_IP>:/tmp/
   ```
2. 登录业务 ECS，编辑 `/tmp/init-ecs.sh` 填写顶部留空的 `ACR_REGISTRY`（推荐同地域内网地址，如 `registry-vpc.cn-hangzhou.aliyuncs.com`）、`ACR_USERNAME`、`ACR_PASSWORD`，然后执行：
   ```bash
   sudo sh /tmp/init-ecs.sh
   ```
   脚本会自动安装 Docker 与 `docker compose` 插件、完成 ACR 内网登录（凭证写入 `/root/.docker/config.json`）、将 `service-ctl.sh` 安装到 `/opt/bin/service-ctl.sh` 并初始化 `/var/lib/service-ctl`。
3. 删除临时文件，避免明文密码留存：
   ```bash
   rm -f /tmp/init-ecs.sh /tmp/service-ctl.sh
   ```

---

## 第 5 步：接入 CI/CD 流水线（以云效 Flow 为例）

### 5.1 配置团队 / 项目级公共变量组

| 变量名 | 示例值 |
| --- | --- |
| `LOG_AGENT_IMAGE` | `registry-vpc.cn-hangzhou.aliyuncs.com/<命名空间>/log-agent:v1.0.0` |
| `OTLP_ENDPOINT` | 模式 A：`http://<中心ECS内网IP>:4318`<br>模式 B：`https://otel.example.com` |
| `OTLP_AUTH_TOKEN` | 第 1.4 步从中心 `.env` 取出的加密凭据 |

> 后续升级 `log-agent` 时，推送新标签（如 `v1.0.1`），先在测试环境单独验证通过，再在公共变量组中改一次 `LOG_AGENT_IMAGE` 即可全量升级。

### 5.2 主机部署节点命令

```sh
printf '%s' "${OTLP_AUTH_TOKEN}" | /opt/bin/service-ctl.sh deploy \
  --service order-service \
  --env prod \
  --port 18082 \
  --image "${APP_IMAGE}" \
  --agent-image "${LOG_AGENT_IMAGE}" \
  --otlp-endpoint "${OTLP_ENDPOINT}" \
  --health-url "http://127.0.0.1:18082/healthz"
```

应急运维命令（直接登录业务 ECS 执行）：

```sh
# 查看服务与 log-agent 运行状态
/opt/bin/service-ctl.sh status --service order-service --env prod

# 秒级回滚到上一次健康版本（无需再传镜像版本号）
printf '%s' "${OTLP_AUTH_TOKEN}" | /opt/bin/service-ctl.sh rollback --service order-service --env prod
```

---

## 第 6 步：验收与日常运维速查

1. **访问 HyperDX**：浏览器打开 `HYPERDX_PUBLIC_URL`（如 `https://logs.example.com`），首次访问注册管理员账号。
2. **验证日志与链路**：向已部署的 Go / Python 服务发起一次请求，在 HyperDX 的 **Search** 中切换 **Logs** / **Traces** 数据源，用 `TraceId:"<请求TraceId>"` 检索即可看到完整日志与调用瀑布图。
3. **可选：调整表保留期为日志/Span 7 天、指标 30 天**（默认统一 30 天，待有数据建表后在中心机执行一次）：
   ```bash
   cd /opt/observability-infra
   docker compose exec -T clickhouse sh -c 'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --multiquery' < clickhouse/retention.sql
   ```
4. **中心机日常维护注意事项**：
   - 修改 `.env` 后必须执行 `docker compose up -d` 生效，不要只执行 `docker compose restart`；
   - 停止中心服务请用 `docker compose down`，**切勿随意加 `--volumes`**（会删除 MongoDB 命名卷，导致 HyperDX 账号和看板丢失）；
   - 更多网络细节与容量/备份约定见 [remote-access.md](remote-access.md) 和 [README.md](README.md)。
