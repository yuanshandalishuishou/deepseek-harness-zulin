# Docker 一体化镜像方案评审与增强建议

**评审对象**：集成 DeepSeek Harness (DSH) / OpenClaw / Hermes Agent / Web 管理工具 的 All-in-One Docker 镜像方案
**评审日期**：2026-09-03

---

## 〇、总体评价

方案骨架是合理的：Nginx 统一入口 + Supervisor 多进程管理 + 路径/端口双访问模式 + 不改上游源码的适配策略，方向都对。但存在 **1 个根本性矛盾**（监听 127.0.0.1 与端口直连不可兼得）、**若干代理细节缺失**（redirect/cookie/SSE/尾斜杠），以及安全、可观测性、工程化方面的增强空间。以下按优先级展开。

---

## 一、必须修正的问题（P0）

### P0-1 「仅监听 127.0.0.1」与「-p 端口直连」互相矛盾

这是方案里最大的逻辑漏洞：

- Docker 的 `-p 3080:3080` 发布的是**容器网卡地址**上的端口。
- 如果 DSH 绑定的是容器内 `127.0.0.1:3080`，Docker 端口映射流量到达的是容器 eth0 地址，**转发不到 loopback，直接 connection refused**。

**推荐解法 —— Nginx 端口网关（零额外组件）**：

各业务服务仍然只绑 `127.0.0.1`，但为每个需要直连的服务在**同一个 Nginx 进程**里增加一个 `server` 块，监听 `0.0.0.0:3xxxx` 并反代到 `127.0.0.1:port`。是否生成该 server 块由 `ENABLE_XXX_PORT` 环境变量在 entrypoint 里用模板控制，且默认挂 basic auth / IP 白名单：

```nginx
# 由 entrypoint 按 ENABLE_DSH_PORT=true 渲染生成
server {
    listen 3080;
    auth_basic "DSH Direct";
    auth_basic_user_file /etc/nginx/.htpasswd;
    allow 192.168.0.0/16;   # ALLOWED_IPS 渲染
    deny all;
    location / {
        proxy_pass http://127.0.0.1:3080;
        # 端口直连模式下无需任何路径改写，兼容性 100%
    }
}
```

好处：业务服务永远不暴露、端口模式天然没有子路径适配问题（`proxy_pass` 直通）、默认安全（鉴权 + 白名单 + 默认关闭）。

### P0-2 缺少 `proxy_redirect` 与 `proxy_cookie_path`

子路径代理下，后端发出的 **302 跳转**（如 `Location: /login`）和 **Cookie 作用域**（`Set-Cookie: Path=/`）都会跳出 `/herness` 前缀，导致登录跳转 404、会话丢失。原方案完全没覆盖：

```nginx
location /herness/ {
    proxy_pass http://127.0.0.1:3080/;   # 见 P0-5，用尾斜杠代替 rewrite
    proxy_redirect / /herness/;
    proxy_cookie_path / /herness/;
    # ...
}
```

### P0-3 SSE/流式响应会被 `proxy_buffering on` + `sub_filter` 破坏

Harness/LLM 类应用几乎必然使用 SSE（Server-Sent Events）做流式输出。`sub_filter` 要求开启缓冲，而缓冲会把流式响应**攒成一整块再下发**——用户看到的就不是逐字输出，而是长时间卡顿后一次性返回。同时 `proxy_read_timeout 60s` 对 LLM 长生成也太短。

**必须做 location 分流**：

```nginx
# 静态资源/HTML：启用 sub_filter
location /herness/ {
    proxy_pass http://127.0.0.1:3080/;
    proxy_buffering on;
    # ... sub_filter 规则 ...
}

# API/SSE 端点：关闭缓冲、不做 sub_filter、长超时
location /herness/api/ {
    proxy_pass http://127.0.0.1:3080/api/;
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
    chunked_transfer_encoding on;
    # 注意：API 的 baseURL 需在前端构建期或注入期就带前缀（见 P1-2）
}
```

### P0-4 Hermes 的根路径 `/api` 转发与多服务共存冲突

`location ~ ^/(api|ws|events|plugins)/` 把**整个根域名**的 API 命名空间都划给了 Hermes。后果：

- 根域名下无法再共存第二个有根级 API 硬编码的服务（DSH 若也有类似需求即死锁）；
- 该正则匹配优先级高，容易误伤导航页或其他服务未来的根级接口。

建议按优先级处理：
1. **确认 Hermes 上游版本是否已支持 base path**（社区在完善中，升级到支持版本是最干净的解）；
2. 若暂不支持，把 Hermes 前端 JS 中的 `/api` 通过 sub_filter 改写为 `/hermes/api`，再由 `location /hermes/api/` 剥离前缀转发，避免占用根命名空间；
3. 或在生产环境改用**子域名模式**（见第三章 P1-3），彻底绕开。

### P0-5 尾斜杠重定向缺失 + rewrite 写法可简化

- `location /herness/` 不匹配 `/herness`（无尾斜杠），而导航页链接正好写的是 `/herness` → 404。需补：

```nginx
location = /herness { return 301 /herness/; }
```

- `rewrite ^/herness/(.*) /$1 break;` + `proxy_pass http://backend;` 可以用更不易出错的标准写法替代：

```nginx
location /herness/ {
    proxy_pass http://127.0.0.1:3080/;   # 尾部斜杠自动完成前缀剥离
}
```

---

## 二、重要增强（P1）

### P1-1 WebSocket 的 Connection 头不应硬编码

`proxy_set_header Connection "upgrade";` 对普通 HTTP 请求是错误的。标准做法：

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;      # 无 Upgrade 头时显式关闭，避免后端挂起
}
# location 内：
proxy_set_header Connection $connection_upgrade;
```

### P1-2 sub_filter 的固有局限与兜底手段

必须认识到 sub_filter 是**字面量替换**，存在无法根治的盲区：

| 盲区 | 例子 | 缓解 |
|---|---|---|
| 混淆/压缩后模式变异 | `"/api"` 无尾斜杠、`baseURL:"/"` | 增补规则；探测告警 |
| 动态拼接 | `"/"+"api/"`、`new URL("/api",location.origin)` | 无法替换，需上游支持 |
| 跨 buffer 边界漏替换 | 匹配串恰好在缓冲区分界处 | 调大 `proxy_buffers`（治标） |
| 动态构造的 ws(s):// | `` `wss://${location.host}/ws` `` | 需注入运行时配置 |

**增强手段（按推荐度排序）**：

1. **优先推动/使用上游的 base path 构建参数**（Vite `base`、Webpack `publicPath`），一劳永逸，升级也不怕；
2. **启动自检**：entrypoint 或 CI 中 `curl` 各服务首页及主 JS bundle，`grep -oE '"/(api|static|ws)/'` 检查是否有残留绝对路径，命中即打印醒目告警（把"替换不全"从用户发现变成自动发现）;
3. **运行时配置注入**：若上游支持 `window.__ENV__` / `config.js`，用 Nginx 在 `</head>` 前注入一个 `<script src="/herness/config.js">`，由 entrypoint 渲染 baseURL——比多层 sub_filter 健壮得多;
4. sub_filter 规则抽成独立 `snippets/sub_filter_dsh.conf`，随上游版本升级集中维护。

### P1-3 增加「子域名模式」作为生产首选

建议将访问模式升级为三种：

1. **子域名模式（生产推荐）**：`dsh.example.com`、`openclaw.example.com` —— 零路径改写、零 sub_filter、Cookie 天然隔离、WebSocket 无障碍。Nginx 上每个服务一个 server 块即可，复杂度反而最低；
2. **路径模式（单域名/受限场景）**：当前方案，接受 sub_filter 的维护成本；
3. **端口模式（仅开发调试）**：P0-1 的端口网关 + 鉴权 + 默认关闭。

三种模式共用一套模板，由 `ACCESS_MODE=subdomain|path|port` 环境变量切换渲染。

### P1-4 管理口（34567）必须鉴权

该工具可改配置、脚本、日志，属于高危入口。无论是路径模式还是端口模式：

- Nginx 层 basic auth（`htpasswd` 由 `ADMIN_USER`/`ADMIN_PASSWORD` env 在 entrypoint 生成）；
- 更进一步可接 forward auth（Authelia / oauth2-proxy）对接 SSO；
- 端口模式叠加 IP 白名单。

### P1-5 移除 EXPOSE 22

容器内跑 sshd 是公认的反模式：调试一律 `docker exec -it <cid> bash`。开放 22 只会扩大攻击面。建议从 EXPOSE 和方案中删除。

### P1-6 命名勘误

路由 `/herness` 疑似 `harness` 笔误。对外路径建议语义化且稳定：`/dsh` 或 `/harness`。路径一旦上线再改就是 breaking change，现在定好。

---

## 三、镜像工程与运行时建议（P2）

### 3.1 基础镜像与构建

- **基础镜像**：`debian:bookworm-slim`。不建议 Alpine——musl libc 对部分 Node 原生模块（sharp、bcrypt、sqlite3 等）兼容性差，排障成本高；
- **多阶段构建**：`node:22-bookworm` 阶段构建 OpenClaw/Hermes 前端 → 运行阶段仅复制产物和 production 依赖，镜像可缩小 60%+；
- **版本全部 pin**：基础镜像用 digest（`debian:bookworm-slim@sha256:...`）、npm 用 `npm ci`（lockfile）、pip 用 `--require-hashes`、apt 锁定关键包版本；
- `.dockerignore` + `apt --no-install-recommends` + 层合并，控制体积。

### 3.2 进程管理

Supervisor 可行，但建议评估 **s6-overlay**（容器场景事实标准之一）：原生处理僵尸进程、支持服务依赖顺序与就绪通知、崩溃策略更细。若坚持用 Supervisor：

```ini
[supervisord]
nodaemon=true

[program:dsh]
priority=20
autorestart=true
stopasgroup=true
killasgroup=true
stopwaitsecs=10
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
redirect_stderr=true
```

- 用 `priority` 显式控制启动顺序（业务服务 → Nginx 最后）；
- 前置 `tini`（`ENTRYPOINT ["/usr/bin/tini","--"]`）保证信号正确传递、优雅停机；
- `stopsignal SIGTERM` + 合理的 `stop_grace_period`。

### 3.3 安全加固

- 各服务以**独立非 root 用户**运行；Nginx worker 降权（master 需 root 绑 80/443；若改用 8080/8443 则容器可全非 root）；
- compose 层：`read_only: true` + `tmpfs: /tmp`、`security_opt: no-new-privileges`、`cap_drop: ALL`；
- 支持 `PUID`/`PGID` 环境变量（linuxserver.io 惯例），解决卷挂载文件的属主错位；
- 密钥一律不进镜像层：env 传入 + 支持 `_FILE` 后缀读 Docker secrets（如 `DEEPSEEK_API_KEY_FILE=/run/secrets/ds_key`）。

### 3.4 健康检查与可观测性

- Dockerfile 增加 `HEALTHCHECK CMD curl -fsS http://127.0.0.1/healthz || exit 1`；
- Nginx 提供 `/healthz`（聚合各后端探活，任一失败返回 503）与每服务 `/healthz/<svc>`；
- **导航页升级**：为每个服务加状态灯（前端轮询健康接口），导航页从"链接列表"升级为"服务仪表盘"——成本极低、体验质变；
- 日志全部走 stdout/stderr（supervisor 转发）→ `docker logs` 可见；Nginx access log 用 JSON 格式便于采集；卷内日志配 logrotate。

### 3.5 Entrypoint 设计

固定顺序、全程幂等、fail fast：

```
1. 校验必填环境变量（缺失则打印帮助并退出非 0）
2. envsubst 渲染：nginx conf 模板 + 导航页 index.html（替代手写 {{HOST_IP}} 替换）
3. 初始化卷目录结构与权限（PUID/PGID chown）
4. 证书检查/首次签发（见 3.6）
5. 生成 htpasswd（若启用鉴权）
6. 启动自检（curl 各后端 /healthz，输出就绪报告）
7. exec supervisord
```

`HOST_IP` 建议自动探测兜底（`hostname -I | awk '{print $1}'`），env 显式传入时优先。

### 3.6 证书管理细化

- certbot 由 Supervisor 托管的 cron 定时续期，`--deploy-hook "nginx -s reload"`；
- 同时支持 HTTP-01 与 DNS-01（内网/泛域名场景必需）；
- 提供 `ACME_STAGING=true` 开关，调试期避免触发 Let's Encrypt 速率限制；
- `/etc/letsencrypt` 挂载卷持久化（已在方案中，确认权限 700）。

### 3.7 环境变量设计增强

在原清单基础上补充：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `ACCESS_MODE` | `path` | `subdomain` / `path` / `port` 三模式切换 |
| `DOMAIN` | `localhost` | 证书与 server_name 使用 |
| `ACME_EMAIL` / `ACME_STAGING` | — / `true` | 证书申请 |
| `ADMIN_USER` / `ADMIN_PASSWORD(_FILE)` | — | 管理口 basic auth |
| `ALLOWED_IPS` | 空（放行所有） | 端口网关/管理口白名单，逗号分隔 CIDR |
| `PUID` / `PGID` | `1000` | 卷权限映射 |
| `TZ` | `Asia/Shanghai` | 时区 |
| `HTTP_PORT` / `HTTPS_PORT` | `80` / `443` | 容器内监听端口（配合非 root 运行可调） |
| `PROXY_READ_TIMEOUT` | `600` | LLM 长请求超时可调 |
| `LOG_LEVEL` | `info` | 各服务日志级别 |
| `*_API_KEY(_FILE)` | — | 全部支持 `_FILE` 读 secrets |

配套交付 `.env.example` 和 README 中的「变量 × 默认值 × 生效服务」矩阵表。

### 3.8 Nginx 通用补强清单

- 标准头补齐：`X-Real-IP`、`X-Forwarded-For`、`X-Forwarded-Proto`、`X-Forwarded-Host`；
- `client_max_body_size 100m;`（Harness 类工具常有文件/数据集上传）；
- sub_filter 改写后由 Nginx 自身重新 gzip（`gzip on; gzip_types ...;`），兼顾压缩与改写；
- 安全响应头：`X-Content-Type-Options nosniff`、`Referrer-Policy`、`server_tokens off;`，CSP/frame-ancestors 视各前端兼容性灰度开启；
- `limit_req` 对登录与 API 路径限流；
- 统一 `error_page` 友好页。

### 3.9 CI/CD

- GitHub Actions + `docker buildx`：amd64/arm64 双架构；
- 标签策略：`latest` / `vX.Y.Z` / `<date>-<sha>`；
- Trivy 漏洞扫描 + SBOM 生成；可选 cosign 签名；
- **冒烟测试纳入 CI**：容器起后自动断言——各路径 200、主 JS 无残留 `"/api/`、WebSocket 握手成功（websocat）、SSE 端点逐 chunk 到达（验证缓冲关闭生效）。这条直接守护方案里风险最高的 sub_filter 部分。

### 3.10 保留拆分演进路径

All-in-One 适合快速交付，但建议镜像按「同源双形态」设计：

- 单体容器（当前方案）：一行 `docker run` 跑起来；
- `docker-compose.yml` 多容器形态（nginx + 4 服务）：服务独立伸缩、独立重启、故障隔离，供生产环境升级使用。各服务镜像在 CI 中从同一仓库的 stage 导出，不增加维护成本。

---

## 四、技术栈与语言建议

| 组件 | 建议 | 理由 |
|---|---|---|
| 基础镜像 | `debian:bookworm-slim`（digest pin） | glibc 兼容性最好，排障成本低 |
| 编排/启动脚本 | **Bash**（entrypoint + envsubst 模板渲染） | 零额外依赖；避免引入 Python/Go 只为渲染模板 |
| Node.js | **22 LTS**（corepack 固定 pnpm/yarn） | 跑 OpenClaw / Hermes；以其各自 `engines` 字段为准 |
| Python | **3.12**（venv + `--require-hashes`） | 若 DSH 或管理工具需要；不污染系统 Python |
| Nginx | 1.26/1.27 stable（官方源，自带 sub_filter 模块） | 反向代理核心 |
| 进程管理 | s6-overlay v3（首选）或 Supervisor 4.x | 见 3.2 |
| PID 1 | tini | 信号传递与僵尸回收 |
| 导航页 | 纯静态 HTML + CSS（零 JS 框架依赖）+ envsubst 渲染 | 越简单越不会坏 |
| 证书 | certbot（cron 托管） | 生态成熟，hook 灵活 |
| CI | GitHub Actions + buildx + Trivy | 构建、多架构、安全扫描一体化 |

原则：**能用 Bash 完成的不引入运行时，能用静态页完成的不引入框架**——这个镜像的复杂度上限由四个上游应用决定，自家代码越少越好。

---

## 五、落地 Roadmap

1. **修正 P0**：端口网关方案落地、`proxy_redirect`/`proxy_cookie_path`、SSE location 分流、尾斜杠 301、Hermes `/api` 冲突决策（升级上游 or 改写 or 子域名）；
2. **搭骨架**：多阶段 Dockerfile + supervisord + envsubst 模板化 nginx conf；
3. **加固**：非 root、tini、健康检查、日志标准化、密钥 `_FILE` 支持；
4. **证书与鉴权**：certbot 续期闭环、管理口 basic auth、端口网关白名单；
5. **CI/CD 与冒烟测试**：多架构构建 + sub_filter 残留自动检测；
6. **文档**：README（三种访问模式矩阵）+ `.env.example` + 故障排查手册（重点：子路径适配 FAQ）。

---

## 附：修正后的 DSH location 参考配置

```nginx
map $http_upgrade $connection_upgrade { default upgrade; '' close; }

location = /herness { return 301 /herness/; }

# API/SSE：不缓冲、不改写、长超时
location /herness/api/ {
    proxy_pass http://127.0.0.1:3080/api/;
    proxy_buffering off;
    proxy_read_timeout 600s;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Prefix /herness;
}

# WebSocket
location /herness/ws/ {
    proxy_pass http://127.0.0.1:3080/ws/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_read_timeout 3600s;
}

# 页面与静态资源：sub_filter 改写
location /herness/ {
    proxy_pass http://127.0.0.1:3080/;
    proxy_set_header Accept-Encoding "";
    proxy_redirect / /herness/;
    proxy_cookie_path / /herness/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Prefix /herness;

    sub_filter 'href="/' 'href="/herness/';
    sub_filter 'src="/'  'src="/herness/';
    sub_filter '"/api/'  '"/herness/api/';
    sub_filter "'/api/"  "'/herness/api/";
    sub_filter '`/api/'  '`/herness/api/';
    sub_filter_once off;
    sub_filter_types text/html text/javascript text/css application/json;

    proxy_buffering on;
    proxy_buffers 8 256k;
    proxy_buffer_size 128k;
    client_max_body_size 100m;
}
```
