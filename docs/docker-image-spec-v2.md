# 一体化 AI 服务平台 Docker 镜像
# 需求方案与实现方案（v2.0）

| 项目 | 内容 |
|---|---|
| 文档版本 | v2.0 |
| 修订日期 | 2026-09-03 |
| 修订说明 | 在 v1.0 基础上全面采纳架构评审意见：新增子域名模式、Nginx 端口网关、SSE 分流、安全加固、健康检查与 CI 冒烟测试；按用户要求保留 SSH（22 端口，默认关闭） |
| 目标读者 | 架构设计、开发、运维人员 |

---

# 第一部分 需求方案

## 1.1 项目背景与核心目标

构建一个 All-in-One Docker 镜像，集成以下四个服务并提供统一 Web 入口：

| 服务 | 说明 | 内部监听地址 |
|---|---|---|
| DeepSeek Harness (DSH) | LLM 评测/调试工作台 | 127.0.0.1:3080 |
| OpenClaw | 智能体网关（含 Control UI） | 127.0.0.1:18789 |
| Hermes Agent | 智能体运行与仪表盘 | 127.0.0.1:6060 |
| Web 管理工具 | 配置、脚本、日志管理 | 127.0.0.1:34567 |

核心目标：

1. **一个容器跑全套服务**，一条 `docker run` 命令即可启动；
2. **三种访问模式**覆盖生产、受限网络、开发调试全部场景；
3. **不修改任何上游服务源码**，所有适配在 Nginx 层与配置层完成；
4. **安全默认（Secure by Default）**：业务服务永不直接暴露，高危入口默认关闭并带鉴权。

## 1.2 三种访问模式

| 模式 | 访问形式 | 适用场景 | 兼容性 | 安全性 |
|---|---|---|---|---|
| 子域名模式（推荐生产使用） | `https://dsh.example.com` | 生产环境，可申请泛域名证书 | ★★★★★ 零改写 | 高 |
| 路径模式（单域名场景） | `https://example.com/dsh/` | 只有一个域名/IP 的环境 | ★★★★☆ 需路径适配 | 高 |
| 端口模式（仅开发调试） | `http://<host>:3080` | 本地开发、联调 | ★★★★★ 零改写 | 中（默认关闭 + 鉴权 + 白名单） |

- 通过环境变量 `ACCESS_MODE=subdomain|path` 切换主模式（默认为 `path`）；
- 端口模式与主模式**可叠加**，由 `ENABLE_*_PORT` 系列开关独立控制，默认全部关闭；
- 端口模式通过「Nginx 端口网关」实现（见 2.5.4），业务服务始终只监听 127.0.0.1。

## 1.3 功能需求

| 编号 | 需求 | 说明 |
|---|---|---|
| FR-01 | 统一导航页 | 根路径 `/` 提供服务导航页，含每个服务的模式入口链接与**实时健康状态灯** |
| FR-02 | 子路径代理 | Nginx 按路由规划表（1.5）将子路径代理到对应后端 |
| FR-03 | 子域名代理 | Nginx 按子域名规划表（1.7）代理，零路径改写 |
| FR-04 | 端口直连网关 | 每个业务服务可有独立直连端口，经 Nginx 端口网关转发，支持 basic auth 与 IP 白名单 |
| FR-05 | SSH 访问（保留项） | 容器内置 OpenSSH Server，`ENABLE_SSH=true` 时启动，默认关闭；仅允许密钥登录 |
| FR-06 | HTTPS 自动化 | Let's Encrypt 证书自动申请、自动续期、续期后自动 reload Nginx |
| FR-07 | 服务开关 | 每个服务可通过环境变量独立启用/禁用，Nginx 配置随之自动裁剪 |
| FR-08 | 配置模板化 | 所有 Nginx 配置与导航页由 entrypoint 通过 envsubst 按环境变量渲染生成 |
| FR-09 | 健康检查 | 提供 `/healthz`（聚合）与 `/healthz/<svc>`（单服务）接口；Docker HEALTHCHECK 内置 |
| FR-10 | 启动自检 | 启动时自动探测各服务可达性，并对 DSH 做 sub_filter 残留扫描，结果输出到日志与导航页 |

## 1.4 非功能需求

| 类别 | 需求 |
|---|---|
| 配置灵活性 | 全部行为由环境变量驱动（12-Factor），密钥支持 `_FILE` 后缀读取 Docker secrets |
| 数据持久化 | 配置、证书、数据、日志均通过卷持久化（见 1.9），容器删建不丢数据 |
| 进程管理 | tini 作为 PID 1 + Supervisor 统一管理全部进程，支持依赖顺序、自动拉起、优雅停机 |
| 安全 | 业务服务仅绑 127.0.0.1；服务以非 root 用户运行；管理口与端口网关强制鉴权；安全响应头；支持 read-only rootfs |
| 可观测性 | 全量日志输出至 stdout/stderr（`docker logs` 可见）；Nginx access log 采用 JSON 格式 |
| 可维护性 | 上游版本全部 pin（镜像 digest / lockfile）；sub_filter 规则集中管理；CI 自动冒烟测试 |
| 性能 | LLM 流式响应（SSE）逐 chunk 下发；静态资源 gzip；文件上传支持 100MB |
| 架构 | linux/amd64 与 linux/arm64 双架构镜像 |

## 1.5 路由规划表（路径模式）

| 用户访问路径 | 后端服务 | 内部地址 | 适配手段 |
|---|---|---|---|
| `/` | 导航页（静态） | /var/www/html/index.html | envsubst 渲染 + 状态灯轮询 |
| `/healthz` | 健康聚合接口 | Nginx + status.json | 见 2.12 |
| `/admin/` | Web 管理工具 | 127.0.0.1:34567 | 标准反代 + basic auth |
| `/dsh/` | DeepSeek Harness | 127.0.0.1:3080 | 四层 sub_filter + SSE 分流 + WS 升级 |
| `/openclaw/` | OpenClaw | 127.0.0.1:18789 | 官方 basepath 配置 |
| `/hermes/` | Hermes Agent | 127.0.0.1:6060 | X-Forwarded-Prefix + 前端路径改写 |

> 命名说明：v1.0 中的 `/herness` 为 harness 笔误，v2.0 统一改为语义化的 `/dsh`。每个路径均配置无尾斜杠 301 跳转（`/dsh` → `/dsh/`）。

## 1.6 端口规划表

| 端口 | 绑定地址 | 用途 | 暴露条件 |
|---|---|---|---|
| 80 | 0.0.0.0 | HTTP（跳转 HTTPS / ACME 挑战） | 始终 |
| 443 | 0.0.0.0 | HTTPS 主入口（路径/子域名模式） | 始终 |
| 22 | 0.0.0.0 | SSH（保留项，加固配置） | `ENABLE_SSH=true` |
| 3080 | 127.0.0.1（DSH）+ 0.0.0.0（Nginx 端口网关） | DSH 直连 | `ENABLE_DSH_PORT=true` |
| 18789 | 同上结构 | OpenClaw 直连 | `ENABLE_OPENCLAW_PORT=true` |
| 6060 | 同上结构 | Hermes 直连 | `ENABLE_HERMES_PORT=true` |
| 34567 | 同上结构 | 管理工具直连 | `ENABLE_ADMIN_PORT=true` |

> 关键设计：业务进程与端口网关**同号不同址**（127.0.0.1 vs 0.0.0.0），Linux 下可共存，用户感知的端口号保持一致。

## 1.7 子域名规划表（子域名模式）

| 子域名 | 后端服务 |
|---|---|
| `admin.<DOMAIN>` | Web 管理工具（强制 basic auth） |
| `dsh.<DOMAIN>` | DeepSeek Harness |
| `openclaw.<DOMAIN>` | OpenClaw |
| `hermes.<DOMAIN>` | Hermes Agent |
| `<DOMAIN>`（裸域） | 导航页 |

> 子域名模式下每个服务一个独立 server 块，`proxy_pass` 直通，无任何路径改写；建议配合 DNS-01 申请泛域名证书 `*.<DOMAIN>`。

## 1.8 环境变量需求（摘要）

完整定义见 2.14 总表。分类如下：

- **模式控制**：`ACCESS_MODE`、`DOMAIN`、`HOST_IP`
- **服务开关**：`ENABLE_DSH`、`ENABLE_OPENCLAW`、`ENABLE_HERMES`、`ENABLE_ADMIN`
- **端口模式**：`ENABLE_DSH_PORT`、`ENABLE_OPENCLAW_PORT`、`ENABLE_HERMES_PORT`、`ENABLE_ADMIN_PORT`
- **SSH**：`ENABLE_SSH`、`SSH_AUTHORIZED_KEYS(_FILE)`、`SSH_PORT`
- **证书**：`ACME_EMAIL`、`ACME_STAGING`、`ACME_DNS_PROVIDER`
- **鉴权**：`ADMIN_USER`、`ADMIN_PASSWORD(_FILE)`、`ALLOWED_IPS`
- **密钥**：`DEEPSEEK_API_KEY(_FILE)` 等，全部支持 `_FILE`
- **系统**：`PUID`、`PGID`、`TZ`、`PROXY_READ_TIMEOUT`、`LOG_LEVEL`

## 1.9 数据持久化需求

| 挂载路径 | 内容 |
|---|---|
| /data/dsh | DSH 数据与配置 |
| /data/openclaw | OpenClaw 数据与配置 |
| /data/hermes | Hermes 数据与配置 |
| /data/admin | 管理工具数据 |
| /etc/letsencrypt | 证书与 ACME 账户 |
| /var/log | 各服务日志（受 logrotate 管理） |
| /etc/ssh/keys | SSH host key（避免容器重建后指纹变化） |

所有挂载目录由 entrypoint 自动初始化属主（PUID/PGID）。

## 1.10 安全需求

1. 业务服务仅监听 127.0.0.1，任何情况下不直接绑定 0.0.0.0；
2. 管理工具与端口网关：basic auth 强制开启，`ALLOWED_IPS` 可选叠加白名单；
3. SSH：默认关闭；仅密钥登录；禁止 root 直登与密码登录；
4. 密钥不入镜像层，环境变量或 secrets 注入；
5. 各服务以独立非 root 用户运行；容器支持 `read_only` + `cap_drop ALL` + `no-new-privileges` 运行；
6. Nginx 输出安全响应头，隐藏版本号，API 与登录路径支持限流。

## 1.11 约束与边界

- 不修改上游服务源码，适配全部位于 Nginx 层 / 环境变量层；
- DSH 在路径模式下的 sub_filter 适配存在理论盲区（动态拼接 URL），故生产环境推荐子域名模式；
- 单机单容器定位，不内置服务发现与水平伸缩；需要更高可用性时可演进为 docker-compose 多容器形态（镜像同源，见 2.17）。

---

# 第二部分 实现方案

## 2.1 总体架构

```
                        用户流量
                            │
        ┌───────────────────┼────────────────────┐
        │ 443 (HTTPS 主入口) │ 22 (SSH, 默认关)    │ 3080/18789/6060/34567 (端口网关, 默认关)
        ▼                    ▼                    ▼
┌─────────────────────────────────────────────────────────┐
│                      Nginx (唯一流量入口)                 │
│  路径模式 server │ 子域名模式 server │ 端口网关 server     │
│  sub_filter / SSE 分流 / WS 升级 / basic auth / 白名单    │
└───────┬──────────┬──────────┬──────────┬────────────────┘
        │          │          │          │
        ▼          ▼          ▼          ▼
     DSH      OpenClaw    Hermes     Web管理工具
   :3080      :18789      :6060      :34567
  （全部仅监听 127.0.0.1）
─────────────────────────────────────────────────────────
  进程管理: tini (PID 1) → supervisord → {nginx, sshd, cron,
           dsh, openclaw, hermes, admin, status-aggregator}
  配置渲染: entrypoint.sh + envsubst（模板 → 运行时配置）
```

镜像内目录结构（构建上下文）：

```
├── Dockerfile
├── .dockerignore
├── entrypoint.sh
├── conf/
│   ├── supervisord.conf
│   └── nginx/
│       ├── nginx.conf.template
│       ├── snippets/           # headers / ws / auth / sub_filter 片段
│       ├── modes/
│       │   ├── path.conf.template
│       │   ├── subdomain.conf.template
│       │   └── port-gateways.conf.template
│       └── .htpasswd           # entrypoint 生成
├── www/
│   └── index.html.template     # 导航页（含状态灯）
├── scripts/
│   ├── render-config.sh        # envsubst 渲染
│   ├── init-volumes.sh         # 目录初始化与权限
│   ├── healthcheck.sh          # Docker HEALTHCHECK
│   ├── selfcheck.sh            # 启动自检 + sub_filter 残留扫描
│   └── status-aggregator.sh    # 状态聚合（cron 每 15s）
└── services/                   # 各上游服务的安装产物（多阶段构建生成）
```

## 2.2 技术栈选型

| 组件 | 选型 | 说明 |
|---|---|---|
| 基础镜像 | `debian:bookworm-slim`（digest pin） | glibc 兼容性好，避免 Alpine/musl 对 Node 原生模块的坑 |
| 构建方式 | 多阶段构建 | node:22-bookworm 构建各服务前端 → 运行阶段仅拷贝产物 |
| Node.js | 22 LTS（corepack 固定 pnpm） | OpenClaw / Hermes 运行时，以其 engines 字段为准 |
| Python | 3.12（venv + --require-hashes） | DSH / 管理工具如需 |
| 反向代理 | Nginx 1.27 stable（官方源，自带 sub_filter） | 唯一流量入口 |
| 进程管理 | tini + Supervisor 4.x | tini 收信号/回收僵尸；Supervisor 管服务生命周期（s6-overlay 为备选演进项） |
| 配置渲染 | Bash + envsubst（gettext） | 零额外运行时 |
| SSH | OpenSSH Server（加固配置，默认关） | 用户保留项 |
| 证书 | certbot + cron（支持 DNS-01 插件） | deploy-hook 触发 nginx reload |
| 导航页 | 纯静态 HTML/CSS/JS（零框架） | 状态灯轮询 status.json |
| CI | GitHub Actions + buildx + Trivy | 双架构构建、漏洞扫描、冒烟测试 |

选型原则：能用 Bash 完成的不引入运行时，能用静态页完成的不引入框架——镜像复杂度上限由四个上游应用决定，自有代码越少越好。

## 2.3 镜像构建设计

Dockerfile 关键设计（多阶段）：

```dockerfile
# ---------- 阶段 1：构建各服务 ----------
FROM node:22-bookworm AS build-openclaw
WORKDIR /src
COPY upstream/openclaw/package.json upstream/openclaw/pnpm-lock.yaml ./
RUN corepack enable && pnpm install --frozen-lockfile
COPY upstream/openclaw/ ./
RUN pnpm build && pnpm prune --prod

# （build-dsh / build-hermes / build-admin 结构相同，略）

# ---------- 阶段 2：运行时 ----------
FROM debian:bookworm-slim@sha256:<pin>
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      nginx supervisor openssh-server certbot cron gettext-base \
      curl ca-certificates tini logrotate \
      nodejs python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

# 创建各服务非 root 用户
RUN useradd -r -u 1001 dsh && useradd -r -u 1002 openclaw \
    && useradd -r -u 1003 hermes && useradd -r -u 1004 admin

COPY --from=build-openclaw /src/dist /opt/openclaw
# ... 其余服务拷贝 ...
COPY conf/ /etc/aio/conf/
COPY www/ /etc/aio/www/
COPY scripts/ /etc/aio/scripts/
COPY entrypoint.sh /entrypoint.sh

EXPOSE 80 443 22 3080 18789 6060 34567
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
  CMD /etc/aio/scripts/healthcheck.sh
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
```

要点：

- 基础镜像、apt 包、npm（lockfile）、pip（hashes）**全部版本 pin**；
- `.dockerignore` 排除 .git、node_modules、临时文件；
- 合并 RUN 层 + `--no-install-recommends` + 清理缓存控制体积；
- 镜像内不含任何密钥与证书。

## 2.4 进程管理

supervisord.conf（节选）：

```ini
[supervisord]
nodaemon=true
logfile=/dev/null

[program:status-aggregator]
command=/etc/aio/scripts/status-aggregator.sh
priority=5
autorestart=true
user=root

[program:dsh]
command=/opt/dsh/run.sh
priority=20
user=dsh
autorestart=true
stopasgroup=true
killasgroup=true
stopwaitsecs=10
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
redirect_stderr=true

# openclaw / hermes / admin 结构相同（priority=20，各自 user）

[program:cron]
command=/usr/sbin/cron -f
priority=30

[program:sshd]
command=/usr/sbin/sshd -D -e
priority=30
autorestart=true
; 由 entrypoint 根据 ENABLE_SSH 决定是否写入此段

[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
priority=40
autorestart=true
stopsignal=QUIT
```

要点：

- tini 作为 PID 1，保证 SIGTERM 正确传递、回收僵尸进程；
- `priority` 显式排序：状态聚合 → 业务服务 → cron/sshd → Nginx 最后（确保后端就绪后再放流量）;
- 所有服务 stdout/stderr 直通 `docker logs`；
- sshd 段落由 entrypoint 按 `ENABLE_SSH` 动态写入，默认不存在（进程级关闭，而非仅防火墙级）。

## 2.5 Nginx 配置体系

### 2.5.1 公共片段

snippets/proxy-headers.conf：

```nginx
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $host;
```

snippets/ws.conf：

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;  # 来自 map，见下
proxy_read_timeout 3600s;
```

nginx.conf.template 全局要点：

```nginx
map $http_upgrade $connection_upgrade { default upgrade; '' close; }

server_tokens off;
client_max_body_size 100m;
gzip on;
gzip_types text/css application/javascript application/json image/svg+xml;

add_header X-Content-Type-Options nosniff always;
add_header Referrer-Policy strict-origin-when-cross-origin always;

log_format json_combined escape=json
  '{"time":"$time_iso8601","remote":"$remote_addr","host":"$host",'
  '"uri":"$request_uri","status":$status,"rt":$request_time,'
  '"upstream":"$upstream_addr","urt":"$upstream_response_time"}';
access_log /dev/stdout json_combined;
```

> 关键修正（相对 v1.0）：Connection 头由 map 动态生成，不再硬编码 "upgrade"；日志 JSON 化；上传体积放开到 100MB。

### 2.5.2 路径模式 server（核心）

```nginx
server {
    listen 443 ssl;
    server_name ${DOMAIN};
    # ssl_certificate 指向 /etc/letsencrypt/live/${DOMAIN}/...

    root /var/www/html;

    # ---- 健康检查 ----
    location = /healthz { default_type application/json; try_files /status.json =503; }
    location ~ ^/healthz/(dsh|openclaw|hermes|admin)$ {
        proxy_pass http://127.0.0.1:$1_health;   # 实际由渲染展开为各端口
    }

    # ---- 尾斜杠 301（v1.0 缺失，v2.0 补齐） ----
    location = /dsh      { return 301 /dsh/; }
    location = /openclaw { return 301 /openclaw/; }
    location = /hermes   { return 301 /hermes/; }
    location = /admin    { return 301 /admin/; }

    # ---- DSH：三层 location 分流 ----
    # (a) API/SSE：不缓冲、不改写、长超时
    location /dsh/api/ {
        proxy_pass http://127.0.0.1:3080/api/;
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
        proxy_read_timeout ${PROXY_READ_TIMEOUT}s;
        include snippets/proxy-headers.conf;
        proxy_set_header X-Forwarded-Prefix /dsh;
    }
    # (b) WebSocket
    location /dsh/ws/ {
        proxy_pass http://127.0.0.1:3080/ws/;
        include snippets/ws.conf;
        include snippets/proxy-headers.conf;
    }
    # (c) 页面与静态资源：sub_filter 改写
    location /dsh/ {
        proxy_pass http://127.0.0.1:3080/;
        include snippets/proxy-headers.conf;
        proxy_set_header Accept-Encoding "";      # 禁用上游压缩，sub_filter 才能生效
        proxy_set_header X-Forwarded-Prefix /dsh;
        proxy_redirect / /dsh/;                   # 修正后端 302 跳转（v1.0 缺失）
        proxy_cookie_path / /dsh/;                # 修正 Cookie 作用域（v1.0 缺失）
        include snippets/sub-filter-dsh.conf;
        proxy_buffering on;
        proxy_buffer_size 128k;
        proxy_buffers 8 256k;                     # 加大缓冲，降低跨边界漏替换概率
    }

    # ---- OpenClaw：官方 basepath ----
    location /openclaw/ {
        proxy_pass http://127.0.0.1:18789/;
        include snippets/proxy-headers.conf;
        include snippets/ws.conf;
    }

    # ---- Hermes：前缀感知 + 路径改写（不占用根命名空间） ----
    location /hermes/ {
        proxy_pass http://127.0.0.1:6060/;
        include snippets/proxy-headers.conf;
        proxy_set_header X-Forwarded-Prefix /hermes;
        proxy_redirect / /hermes/;
        proxy_cookie_path / /hermes/;
        proxy_set_header Accept-Encoding "";
        sub_filter '"/api/' '"/hermes/api/';
        sub_filter "'/api/" "'/hermes/api/";
        sub_filter '`/api/'  '`/hermes/api/';
        sub_filter_once off;
        sub_filter_types text/html text/javascript;
    }
    location /hermes/api/ {
        proxy_pass http://127.0.0.1:6060/api/;
        include snippets/proxy-headers.conf;
        proxy_buffering off;                       # Hermes events 走 SSE
        proxy_read_timeout ${PROXY_READ_TIMEOUT}s;
    }

    # ---- 管理工具：强制鉴权 ----
    location /admin/ {
        auth_basic "Admin";
        auth_basic_user_file /etc/nginx/.htpasswd;
        include snippets/allowed-ips.conf;         # ALLOWED_IPS 渲染
        proxy_pass http://127.0.0.1:34567/;
        include snippets/proxy-headers.conf;
    }
}
```

### 2.5.3 DSH 四层 sub_filter（snippets/sub-filter-dsh.conf）

```nginx
# 第一层：基础资源
sub_filter 'href="/'   'href="/dsh/';
sub_filter 'src="/'    'src="/dsh/';
sub_filter 'action="/' 'action="/dsh/';
# 第二层：API 路径（双引号/单引号/模板字符串）
sub_filter '"/api/'    '"/dsh/api/';
sub_filter "'/api/"    "'/dsh/api/";
sub_filter '`/api/'    '`/dsh/api/';
# 第三层：JS 动态跳转
sub_filter 'window.location.origin + "/' 'window.location.origin + "/dsh/';
sub_filter 'location.href = "/'          'location.href = "/dsh/';
sub_filter 'location.pathname = "/'      'location.pathname = "/dsh/';
# 第四层：WebSocket
sub_filter '"/ws/'     '"/dsh/ws/';
sub_filter "'/ws/"     "'/dsh/ws/";

sub_filter_once off;
sub_filter_types text/html text/javascript text/css application/json;
```

**已知盲区与兜底**（必须写入运维文档）：

| 盲区 | 例子 | 兜底 |
|---|---|---|
| 压缩后模式变异 | `"/api"`（无尾斜杠）、`baseURL:"/"` | 增补规则 + 启动自检告警 |
| 动态拼接 | `"/"+"api/"`、`new URL(...)` | 升级上游 base path 构建参数，或切子域名模式 |
| 跨 buffer 边界漏替换 | 匹配串横跨缓冲区分界 | 已调大 proxy_buffers 缓解 |
| 动态构造 wss:// | `` `wss://${location.host}/ws` `` | 子域名模式彻底规避 |

### 2.5.4 端口网关 server（端口模式核心）

每个服务一段，由 entrypoint 按 `ENABLE_*_PORT` 渲染决定是否生成：

```nginx
server {
    listen 3080;                                # 0.0.0.0:3080
    auth_basic "DSH Direct";
    auth_basic_user_file /etc/nginx/.htpasswd;
    include snippets/allowed-ips.conf;
    location / {
        proxy_pass http://127.0.0.1:3080;       # 直通，零路径改写
        include snippets/proxy-headers.conf;
        include snippets/ws.conf;
        proxy_buffering off;                    # 直连模式全量透传流式响应
        proxy_read_timeout ${PROXY_READ_TIMEOUT}s;
    }
}
```

> 业务进程绑 127.0.0.1:3080、网关绑 0.0.0.0:3080，同号不同址，Linux 下合法共存。此设计同时解决了 v1.0 的根本矛盾：原方案中服务绑 127.0.0.1 时 `-p 3080:3080` 端口映射根本到不了 loopback，端口直连必然失败。

### 2.5.5 子域名模式 server

```nginx
server {
    listen 443 ssl;
    server_name dsh.${DOMAIN};
    location / {
        proxy_pass http://127.0.0.1:3080;       # 零改写
        include snippets/proxy-headers.conf;
        include snippets/ws.conf;
        proxy_buffering off;
        proxy_read_timeout ${PROXY_READ_TIMEOUT}s;
    }
}
# openclaw/hermes/admin 结构相同；裸域 server 提供导航页
```

## 2.6 各服务子路径适配小结

| 服务 | 首选机制 | 辅助机制 |
|---|---|---|
| DSH | 四层 sub_filter（页面）+ 三层 location 分流 | 启动自检残留扫描；长期推动上游支持 base path 构建 |
| OpenClaw | 官方 `gateway.controlui.basepath=/openclaw`（env 注入） | Nginx 剥离前缀直通 |
| Hermes | X-Forwarded-Prefix 头 + sub_filter 改写前端 API 路径 | 跟踪上游 base path 支持，升级后移除改写 |
| 管理工具 | 标准反代 | basic auth + IP 白名单 |

## 2.7 导航页（服务仪表盘）

- 纯静态 HTML/CSS/JS，零框架、零构建；
- 每个服务卡片展示：名称、状态灯（绿/红/灰=启用/异常/未启用）、当前可用入口链接（按模式与端口开关动态渲染）；
- 状态数据来源：`/healthz` 返回的 status.json，前端每 10s 轮询；
- status.json 由 `status-aggregator.sh`（cron，每 15s）生成：逐个 `curl -fsS http://127.0.0.1:<port><health-path>`，汇总写入 `/var/www/html/status.json`，附自检结果与时间戳；
- `HOST_IP` 由 entrypoint 渲染（未设置时 `hostname -I` 自动探测兜底）。

## 2.8 SSH 服务（保留项，加固实现）

按用户要求保留 22 端口，实施以下加固：

| 项 | 配置 |
|---|---|
| 默认状态 | `ENABLE_SSH=false`，sshd 进程不启动、配置不生成 |
| 认证 | `PasswordAuthentication no`、`PubkeyAuthentication yes`，公钥由 `SSH_AUTHORIZED_KEYS(_FILE)` 注入 |
| root | `PermitRootLogin no`，提供 `SSH_USER`（默认 aioadm，sudo 可选） |
| 端口 | `SSH_PORT` 可改（默认 22），改后 EXPOSE/文档同步 |
| host key | 持久化到 `/etc/ssh/keys` 卷，容器重建指纹不变 |
| 防爆破 | 可选 `ENABLE_FAIL2BAN=true` 启用 fail2ban |

> 定位说明：SSH 用于不便 `docker exec` 的场景（如容器编排平台的受限环境）；能 exec 时仍优先 `docker exec`。

## 2.9 证书管理

- certbot 首次签发由 entrypoint 完成（证书缺失且 `ACME_EMAIL` 已配置时）；
- cron 每日两次 `certbot renew --deploy-hook "nginx -s reload"`；
- 支持 HTTP-01（默认）与 DNS-01（`ACME_DNS_PROVIDER`，用于内网与泛域名 `*.<DOMAIN>`）；
- `ACME_STAGING=true`（默认）走 staging 环境，确认无误后改 false 防限流；
- 证书未就绪时 Nginx 先以自签证书启动，保证容器可用，签发成功后自动切换；
- 也支持完全外部证书：`TLS_CERT_FILE`/`TLS_KEY_FILE` 挂入即跳过 ACME。

## 2.10 安全加固清单

1. 各服务独立非 root 用户（uid 1001-1004）；Nginx worker 降权；
2. 管理口与端口网关：htpasswd 由 `ADMIN_USER`/`ADMIN_PASSWORD(_FILE)` 在 entrypoint 生成，缺密码则该入口拒绝渲染并告警；
3. `ALLOWED_IPS` 渲染为 allow/deny 列表，空值默认放行并在日志提示；
4. 密钥全部支持 `_FILE`（如 `DEEPSEEK_API_KEY_FILE=/run/secrets/ds_key`），entrypoint 统一展开；
5. compose 推荐运行参数：`read_only: true`、`tmpfs: [/tmp, /run]`、`cap_drop: [ALL]`、`security_opt: [no-new-privileges:true]`；
6. Nginx：`server_tokens off`、安全响应头、登录与 API 路径 `limit_req` 限流。

## 2.11 Entrypoint 启动流程

```
entrypoint.sh（幂等，可重复执行）
 ├─ 1. 加载并校验环境变量：必填缺失 → 打印帮助并 exit 1（fail fast）
 ├─ 2. 展开 *_FILE secrets
 ├─ 3. init-volumes.sh：创建 /data/*、/var/log/*，按 PUID/PGID chown
 ├─ 4. 生成 .htpasswd（若启用鉴权）
 ├─ 5. SSH：ENABLE_SSH=true → 写入 sshd 配置、注入公钥、生成/复用 host key，
 │      并向 supervisord 配置写入 sshd 段；否则确保无 sshd 段
 ├─ 6. 证书：已挂载外部证书 → 用之；否则无证书 → 自签兜底 + 触发 ACME 首次签发
 ├─ 7. render-config.sh：envsubst 渲染 nginx.conf、模式 conf、端口网关 conf、
 │      导航页 index.html（HOST_IP、启用的服务与入口）
 ├─ 8. nginx -t 校验渲染结果，失败则 exit 1（不让坏配置上线）
 ├─ 9. selfcheck.sh（后台）：待各服务就绪后 curl 探活 + DSH 首页/JS 残留扫描
 │      （grep -oE '["'"'"'`]/(api|static|ws)/'），结果写入 status.json 并打日志
 └─10. exec supervisord（信号经 tini 传递）
```

## 2.12 健康检查与自检

- **Docker HEALTHCHECK**：`healthcheck.sh` → `curl -fsS http://127.0.0.1/healthz`；
- **/healthz**：返回 status.json（含各服务 up/down、最近自检结论、时间戳）；任何已启用服务 down → HTTP 503；
- **/healthz/\<svc\>**：单服务探活，供导航页与外部监控使用；
- **自检（selfcheck.sh）**：除探活外，对 DSH 抓取首页与主 JS bundle 扫描残留绝对路径，命中即在 status.json 标记 `sub_filter_residue: true` 并输出 WARN 日志——把「替换不全」从用户发现变为自动发现。

## 2.13 日志方案

- 全部进程 stdout/stderr → `docker logs`（Supervisor 转发）；
- Nginx access log：JSON 格式输出到 /dev/stdout；
- 卷内日志（如 certbot、SSH）由 logrotate 按天切割、保留 14 份；
- `LOG_LEVEL` 统一控制各服务日志级别（通过 env 透传）。

## 2.14 环境变量总表

| 变量 | 默认值 | 说明 |
|---|---|---|
| ACCESS_MODE | path | 主模式：path / subdomain |
| DOMAIN | localhost | 主域名（证书与 server_name） |
| HOST_IP | 自动探测 | 导航页端口链接用的 IP/域名 |
| ENABLE_DSH / ENABLE_OPENCLAW / ENABLE_HERMES / ENABLE_ADMIN | true | 服务开关 |
| ENABLE_DSH_PORT / ENABLE_OPENCLAW_PORT / ENABLE_HERMES_PORT / ENABLE_ADMIN_PORT | false | 端口网关开关 |
| ENABLE_SSH | false | SSH 开关（保留项） |
| SSH_PORT | 22 | SSH 监听端口 |
| SSH_USER | aioadm | SSH 登录用户 |
| SSH_AUTHORIZED_KEYS(_FILE) | — | SSH 公钥（ENABLE_SSH=true 时必填） |
| ENABLE_FAIL2BAN | false | SSH 防爆破 |
| ACME_EMAIL | — | 证书申请邮箱（缺失则跳过 ACME） |
| ACME_STAGING | true | staging 开关 |
| ACME_DNS_PROVIDER | — | DNS-01 提供商（cloudflare/aliyun/...） |
| TLS_CERT_FILE / TLS_KEY_FILE | — | 外部证书挂载（设置后跳过 ACME） |
| ADMIN_USER | admin | 管理口/端口网关 basic auth 用户 |
| ADMIN_PASSWORD(_FILE) | — | 同上密码（启用鉴权时必填） |
| ALLOWED_IPS | 空（放行） | 管理口/端口网关白名单，逗号分隔 CIDR |
| DEEPSEEK_API_KEY(_FILE) 等业务密钥 | — | 按各服务要求注入 |
| PROXY_READ_TIMEOUT | 600 | LLM 长请求超时（秒） |
| PUID / PGID | 1000 / 1000 | 卷属主映射 |
| TZ | Asia/Shanghai | 时区 |
| LOG_LEVEL | info | 日志级别 |

交付物同步提供 `.env.example` 与 README 变量矩阵表。

## 2.15 部署示例

仅路径模式（最小暴露面）：

```bash
docker run -d --name aio \
  -p 80:80 -p 443:443 \
  -e DOMAIN=example.com -e ACME_EMAIL=ops@example.com \
  -e ADMIN_PASSWORD_FILE=/run/secrets/admin_pw \
  -v aio-data:/data -v aio-le:/etc/letsencrypt \
  example/aio-platform:2.0.0
```

路径模式 + DSH 端口直连调试 + SSH：

```bash
docker run -d --name aio \
  -p 80:80 -p 443:443 -p 3080:3080 -p 22:22 \
  -e DOMAIN=example.com -e ACME_EMAIL=ops@example.com \
  -e ENABLE_DSH_PORT=true \
  -e ENABLE_SSH=true -e SSH_AUTHORIZED_KEYS_FILE=/run/secrets/id_pub \
  -e ADMIN_PASSWORD_FILE=/run/secrets/admin_pw \
  -v aio-data:/data -v aio-le:/etc/letsencrypt -v aio-ssh:/etc/ssh/keys \
  example/aio-platform:2.0.0
```

子域名模式（生产推荐，泛域名证书）：

```bash
docker run -d --name aio \
  -p 80:80 -p 443:443 \
  -e ACCESS_MODE=subdomain -e DOMAIN=example.com \
  -e ACME_EMAIL=ops@example.com -e ACME_STAGING=false \
  -e ACME_DNS_PROVIDER=cloudflare -e CF_TOKEN_FILE=/run/secrets/cf_token \
  -e ADMIN_PASSWORD_FILE=/run/secrets/admin_pw \
  -v aio-data:/data -v aio-le:/etc/letsencrypt \
  example/aio-platform:2.0.0
```

加固运行参数（建议叠加）：

```yaml
# docker-compose.yml 节选
services:
  aio:
    read_only: true
    tmpfs: [/tmp, /run]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
```

## 2.16 CI/CD 与冒烟测试

流水线（GitHub Actions + buildx）：

1. 构建 linux/amd64 + linux/arm64，推送标签 `latest / vX.Y.Z / <date>-<sha>`；
2. Trivy 漏洞扫描（HIGH/CRITICAL 阻断）+ SBOM 生成；
3. **冒烟测试**（每次构建自动执行，守护方案最高风险点）：
   - 容器以 path 模式 + 全部端口网关 + 自签证书启动；
   - 断言 `/`、`/dsh/`、`/openclaw/`、`/hermes/`、`/admin/` 返回 200/401（admin 预期 401）；
   - 抓取 DSH 主 JS，断言无残留 `["'`]/api/`、`["'`]/static/` 绝对路径；
   - websocat 验证 `/dsh/ws/` WebSocket 握手成功；
   - curl 验证 SSE 端点逐 chunk 到达（确认缓冲关闭生效）；
   - 断言端口网关 3080 直连可用且要求鉴权；
   - 断言 `ENABLE_SSH=true` 时 ssh 密钥登录成功、密码登录被拒绝。

## 2.17 升级、回滚与演进

- **升级**：镜像 tag 全部语义化；升级前备份 /data 与 /etc/letsencrypt 卷；数据迁移脚本（若上游需要）在 entrypoint 幂等执行；
- **回滚**：数据无破坏性迁移时直接换回旧 tag；
- **演进**：CI 同步导出单服务镜像（构建 stage 复用），需要时可无缝切换为 docker-compose 多容器形态（nginx + 4 服务独立容器），获得故障隔离与独立伸缩能力。

## 2.18 故障排查 FAQ（摘要）

| 症状 | 排查路径 |
|---|---|
| 路径模式某页面 404 静态资源 | 看自检告警 → 查 sub_filter 残留 → 增补规则或切子域名模式 |
| DSH 流式输出卡顿 | 确认请求走了 /dsh/api/ location（缓冲关）；查代理层是否二次缓冲 |
| 登录后跳回根域 404 | 查 proxy_redirect 是否覆盖该响应；看后端 Location 头格式 |
| 端口直连 refused | 确认 ENABLE_*_PORT=true 且 -p 已映射；查白名单是否拦截 |
| 证书签发失败 | ACME_STAGING 下调试；查 80 端口可达性 / DNS-01 凭据 |
| SSH 连不上 | ENABLE_SSH、公钥注入、-p 22 映射、host key 卷权限（600） |

---

# 附录：v1.0 → v2.0 修订对照

| v1.0 问题 | v2.0 处置 |
|---|---|
| 服务绑 127.0.0.1 导致 -p 端口直连不可用（根本矛盾） | Nginx 端口网关（同号不同址），业务服务保持 127.0.0.1 |
| 缺 proxy_redirect / proxy_cookie_path | 全部子路径 location 补齐 |
| SSE 流式被 proxy_buffering + sub_filter 破坏；超时 60s 过短 | API/WS/页面三层 location 分流；超时默认 600s 可调 |
| Hermes 占用根路径 /api 命名空间 | 改为 /hermes/api 改写，不占用根命名空间 |
| 无尾斜杠访问 404 | 每条路径补 301 |
| WebSocket Connection 头硬编码 | map 动态生成 |
| 无鉴权的管理口 | basic auth + IP 白名单强制开启 |
| 无健康检查/自检/日志规范 | /healthz 聚合、启动自检（含 sub_filter 残留扫描）、JSON 日志 |
| 两种访问模式 | 三种访问模式（新增生产推荐的子域名模式） |
| /herness 笔误 | 统一更名 /dsh |
| EXPOSE 22（容器内 sshd 反模式） | **按用户决定保留**，默认关闭 + 密钥登录 + 全面加固 |
| 无非 root / secrets / 版本 pin / CI | 全部补齐 |
