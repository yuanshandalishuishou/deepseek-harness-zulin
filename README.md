# AIO Platform — 一体化 AI 服务平台镜像

> 单容器集成 **DeepSeek Harness (DSH)**、**OpenClaw**、**Hermes Agent** 与 **Web 管理工具**，
> Nginx 统一入口，支持子域名 / 路径 / 端口三种访问模式，开箱即用。

![Version](https://img.shields.io/badge/version-2.0.0-blue)
![Base](https://img.shields.io/badge/base-debian%3Abookworm--slim-green)
![Process](https://img.shields.io/badge/process-tini%20%2B%20supervisord-orange)
![CI](https://img.shields.io/badge/CI-GitHub%20Actions%20%E2%86%92%20GHCR-black)

---

## 目录

- [特性一览](#特性一览)
- [总体架构](#总体架构)
- [三种访问模式](#三种访问模式)
- [快速开始](#快速开始)
- [环境变量](#环境变量)
- [目录结构](#目录结构)
- [冒烟测试](#冒烟测试)
- [CI/CD 自动构建](#cicd-自动构建)
- [接入真实上游服务](#接入真实上游服务)
- [安全说明](#安全说明)
- [文档](#文档)
- [Roadmap](#roadmap)

---

## 特性一览

- **一个容器，四个服务**：DSH / OpenClaw / Hermes / Web 管理工具，由 supervisord 统一托管，tini 作为 PID 1 回收僵尸进程
- **三种访问模式**：子域名（生产推荐，零改写）、路径（单域名场景）、端口网关（开发调试，默认关闭 + Basic Auth + IP 白名单）
- **不改上游源码**：所有子路径适配通过 Nginx `sub_filter` / `proxy_redirect` / `proxy_cookie_path` / 请求头重写完成
- **SSE / WebSocket 原生友好**：DSH 三层 location 分流——API 流式接口关缓冲长超时、WS 独立升级、页面走四层 sub_filter
- **安全默认**：业务服务仅绑 `127.0.0.1`；SSH 保留但默认关闭、仅密钥登录、禁 root；管理口强制鉴权；`_FILE` secrets 注入
- **证书自动化**：certbot HTTP-01 + DNS-01（Cloudflare / Route53 / Google / DigitalOcean / DNSPod / 阿里云 / 自定义 hook），自签证书兜底，cron 自动续期
- **可观测**：`/healthz` 健康聚合端点、启动自检（含 sub_filter 残留扫描）、导航页实时状态灯仪表盘
- **全配置模板化**：envsubst 显式白名单渲染，30+ 环境变量控制一切，配置变更无需重建镜像
- **STUB_MODE 桩模式**：无需真实上游即可构建出首版镜像，跑通全链路冒烟测试

## 总体架构

```
                        ┌──────────────────────────────────────────────┐
  用户 ──HTTPS/HTTP──▶  │  Nginx (唯一流量入口, 监听 0.0.0.0)          │
                        │                                              │
                        │   主入口 server(80/443)      端口网关 server │
                        │   ├─ /          导航页        ├─ :3080 ─┐    │
                        │   ├─ /dsh ──┐                 ├─ :18789 ┤    │
                        │   ├─ /openclaw ─┐   反代      ├─ :6060 ─┤    │
                        │   └─ /hermes ──┐│             └─ :34567 ┘    │
                        │     (location 块)│                  │        │
                        └──────────────────┼──────────────────┼────────┘
                                           ▼                  ▼
                              ┌────────────────────────────────────┐
                              │  业务服务 (仅监听 127.0.0.1)        │
                              │  dsh:3080  openclaw:18789          │
                              │  hermes:6060  admin:34567          │
                              └────────────────────────────────────┘
                                           ▲
                              supervisord 统一拉起 / 守护 / 日志
                              tini (PID 1) ─ cron(证书续期) ─ sshd(可选)
```

**关键设计决策**：

1. **端口网关「同号不同址」**——业务服务绑 loopback 与 `-p` 端口直连的矛盾，由 Nginx 网关 server 块（监听 `0.0.0.0:3080` → 反代 `127.0.0.1:3080`）解决。端口直通模式下零路径改写，兼容性 100%。
2. **Hermes 不占用根路径 `/api`**——改为 `/hermes/api` 改写 + `X-Forwarded-Prefix`，根命名空间不被独占。
3. **path 与 subdomain 模式的 include 层级不同**——path 服务模板是 `location` 块（include 在 server 内），subdomain 是 `server` 块（include 在 http 层），由主入口模板各自在正确层级 include。

## 三种访问模式

| 模式 | 访问方式 | 适用场景 | 路径改写 |
|---|---|---|---|
| **子域名** `ACCESS_MODE=subdomain` | `https://dsh.example.com` | 生产环境（推荐） | 无 |
| **路径** `ACCESS_MODE=path`（默认） | `https://example.com/dsh/` | 单域名 / 内网 | sub_filter + 头重写 |
| **端口** `ENABLE_*_PORT=true` | `http://host:3080` | 开发调试 | 无（网关直通） |

三种模式可叠加使用。端口网关默认全部关闭，开启后强制 Basic Auth（`ADMIN_USER`/`ADMIN_PASSWORD`）+ 可选 `ALLOWED_IPS` 白名单。

## 快速开始

### 构建

```bash
git clone https://github.com/yuanshandalishuishou/deepseek-harness-zulin.git
cd deepseek-harness-zulin

# 桩模式构建（默认，无需真实上游即可出可测镜像）
docker build -t aio-platform:2.0.0 .
```

### 运行

```bash
# 最小启动（路径模式 + 自签证书）
docker run -d --name aio \
  -p 80:80 -p 443:443 \
  -e DOMAIN=localhost \
  -e ADMIN_PASSWORD='change-me' \
  -v aio-data:/data \
  aio-platform:2.0.0

# 开放 DSH 端口网关用于调试
docker run -d --name aio \
  -p 80:80 -p 443:443 -p 3080:3080 \
  -e DOMAIN=localhost \
  -e ADMIN_PASSWORD='change-me' \
  -e ENABLE_DSH_PORT=true \
  -v aio-data:/data \
  aio-platform:2.0.0
```

### docker compose

```bash
cp .env.example .env   # 按需修改
docker compose up -d --build
```

启动后访问 `http://localhost/` 查看导航页仪表盘（服务卡片 + 实时状态灯）。

## 环境变量

完整清单见 [.env.example](.env.example)（30+ 项，全部带注释）。核心变量速查：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DOMAIN` | `localhost` | 主域名，子域名模式为其派生 `dsh/openclaw/hermes/admin.<DOMAIN>` |
| `ACCESS_MODE` | `path` | 主入口模式：`path` / `subdomain` |
| `HOST_IP` | 自动探测 | 导航页端口链接使用的主机地址 |
| `ENABLE_DSH/OPENCLAW/HERMES/ADMIN` | `true` | 服务总开关 |
| `ENABLE_*_PORT` | `false` | 端口网关开关（开启需设置 `ADMIN_PASSWORD`） |
| `ADMIN_USER` / `ADMIN_PASSWORD` | `admin` / 空 | 端口网关与管理口 Basic Auth |
| `ALLOWED_IPS` | 空 | 端口网关 IP 白名单，逗号分隔 CIDR |
| `DSH_COMMAND` 等 `*_COMMAND` | 桩/上游默认 | 服务启动命令（supervisord 托管） |
| `ACME_EMAIL` | 空 | 留空跳过 ACME 使用自签证书 |
| `ACME_DNS_PROVIDER` | 空 | DNS-01 提供商（见下表） |
| `ENABLE_SSH` | `false` | SSH 开关（仅密钥、禁 root） |
| `SSH_AUTHORIZED_KEYS` / `_FILE` | 空 | 公钥（启用 SSH 必填） |
| `PUID` / `PGID` | `1000` | 业务运行用户 |
| `PROXY_READ_TIMEOUT` | `600` | SSE/长请求读超时（秒） |

所有敏感变量支持 `_FILE` 后缀从文件注入（Docker secrets 友好），如 `ADMIN_PASSWORD_FILE=/run/secrets/admin_pw`。

**DNS-01 提供商**（`ACME_DNS_PROVIDER`）：

| 值 | 所需凭据 |
|---|---|
| `cloudflare` | `CF_DNS_API_TOKEN` |
| `route53` | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` |
| `google` | `GOOGLE_CREDENTIALS_FILE`（SA JSON 路径） |
| `digitalocean` | `DO_AUTH_TOKEN` |
| `dnspod` | `DNSPOD_TOKEN`（`ID,Token` 格式） |
| `aliyun` | `ALIYUN_ACCESS_KEY_ID` / `ALIYUN_ACCESS_KEY_SECRET` |
| `custom` | `CUSTOM_AUTH_HOOK` / `CUSTOM_CLEANUP_HOOK`（挂载自研脚本，模板见 [examples/dns-hooks/](examples/dns-hooks/)） |

## 目录结构

```
├── Dockerfile                  # 多阶段构建（4 服务 stage + 运行时），STUB_MODE 默认开
├── entrypoint.sh               # 十步启动流程（校验→secrets→卷→证书→渲染→nginx -t→自检）
├── docker-compose.yml
├── .env.example                # 全量环境变量注释清单
├── conf/
│   ├── nginx/
│   │   ├── nginx.conf.template         # http 层（map/缓冲/日志/安全头）
│   │   ├── servers/http-80.conf.template  # 80 端口（ACME 挑战 + 跳转/导航）
│   │   ├── modes/                      # 主入口：path / subdomain 两套 server
│   │   ├── services/path/              # 4 服务 location 块（path 模式）
│   │   ├── services/subdomain/         # 4 服务 server 块（subdomain 模式）
│   │   ├── gateways/                   # 4 端口网关 server（同号不同址）
│   │   └── snippets/                   # proxy 头 / WS / DSH 四层 sub_filter
│   └── supervisor/                     # supervisord 主配置 + 4 服务模板
├── scripts/
│   ├── render-config.sh        # envsubst 白名单渲染（按 ENABLE_* 动态裁剪）
│   ├── init-volumes.sh         # 数据卷目录与权限初始化
│   ├── healthcheck.sh          # Docker HEALTHCHECK 入口
│   ├── selfcheck.sh            # 启动自检（含 sub_filter 残留扫描）
│   ├── status-aggregator.sh    # 15s 轮询生成 status.json（导航页状态灯）
│   ├── cert-issue.sh           # ACME 签发/续期（HTTP-01 + DNS-01 多提供商）
│   ├── smoke-test.sh           # 冒烟测试（方案文档 2.16 节全项）
│   └── dns-hooks/              # 自研 DNS-01 hook（dnspod / aliyun）
├── stubs/stub_server.py        # 桩服务（SSE/WS/绝对路径埋点，专供冒烟测试）
├── examples/dns-hooks/         # custom DNS hook 模板
└── docs/                       # 需求与实现方案（md + docx）、v1 评审报告
```

## 冒烟测试

镜像内置 [scripts/smoke-test.sh](scripts/smoke-test.sh)，覆盖方案文档 2.16 节全部检查项：

```bash
docker run -d --name aio-test \
  -p 80:80 -p 443:443 -p 3080:3080 \
  -e DOMAIN=localhost -e ADMIN_PASSWORD=admin -e ENABLE_DSH_PORT=true \
  aio-platform:2.0.0

# 在容器外执行（或在容器内执行均可）
docker exec aio-test bash /usr/local/bin/smoke-test.sh aio-test admin
```

检查项包括：路径可达性、尾斜杠 301、sub_filter 残留扫描、SSE 首字节时延（<2s）、WebSocket 握手（101）、端口网关鉴权（401/200）、`/healthz` 聚合、SSH 开关行为。

## CI/CD 自动构建

仓库内置 GitHub Actions 工作流（[.github/workflows/docker-build.yml](.github/workflows/docker-build.yml)）：

- **触发**：`main` 分支任何 push（含 API 提交）或手动 `workflow_dispatch`
- **流水线**：构建镜像（桩模式）→ 启动容器 → 跑全套冒烟测试 → 通过后推送 **GHCR**
- **产物**：`ghcr.io/yuanshandalishuishou/deepseek-harness-zulin:latest` + 短 SHA 标签
- **缓存**：GHA layer cache，增量构建秒级完成

```bash
# 拉取 CI 构建的镜像
docker pull ghcr.io/yuanshandalishuishou/deepseek-harness-zulin:latest
```

> 首次运行后，GHCR 包默认为私有。如需公开：GitHub → Packages → 对应包 → Settings → Change visibility。

## 接入真实上游服务

当前 Dockerfile 中 4 个上游为占位构建阶段（`STUB_MODE=true` 时跳过）。接入步骤：

1. 替换 Dockerfile 中 `DSH_REPO` / `DSH_REF`（OpenClaw / Hermes / Admin 同理）为真实仓库与版本 tag
2. 完善对应构建 stage 的编译命令（包管理器、产物目录）
3. 构建时切换 artifacts 来源：

```bash
docker build \
  --build-arg DSH_ARTIFACTS=build-dsh \
  --build-arg DSH_REPO=https://github.com/your/deepseek-harness.git \
  --build-arg DSH_REF=v1.2.3 \
  -t aio-platform:2.0.0 .
```

4. 若上游启动命令与默认值不同，用 `DSH_COMMAND` 等环境变量覆盖（无需改镜像）

## 安全说明

- 业务服务**仅监听 127.0.0.1**，外部流量必须经 Nginx；端口网关是唯一例外且默认关闭
- 端口网关 / 管理口：Basic Auth + 可选 IP 白名单；`ADMIN_PASSWORD` 为空时 fail-fast 拒绝启动
- SSH：默认关闭；启用时强制仅密钥、禁 root 密码登录、host key 持久化到数据卷
- Secrets：一律支持 `_FILE` 注入，杜绝环境变量明文落盘
- 镜像以非 root 用户（`PUID/PGID`，默认 1000）运行业务进程
- 建议生产运行参数（compose 中已注释备好）：`read_only`、`no-new-privileges`、`cap_drop: ALL`

## 文档

| 文档 | 说明 |
|---|---|
| [docs/docker-image-spec-v2.md](docs/docker-image-spec-v2.md) | **v2.0 需求方案 + 实现方案**（Markdown） |
| [docs/docker-image-spec-v2.docx](docs/docker-image-spec-v2.docx) | 同上（Word 版） |
| [docs/docker-image-plan-review.md](docs/docker-image-plan-review.md) | v1.0 方案评审报告（含修订对照） |

## Roadmap

- [x] 三模式 Nginx 架构 + 端口网关
- [x] 全模板化配置渲染 + 桩模式首版
- [x] DNS-01 多提供商证书自动化
- [x] GitHub Actions → GHCR 自动构建
- [ ] 接入真实上游（DSH / OpenClaw / Hermes / Admin 仓库与版本）
- [ ] 多架构构建（linux/arm64）
- [ ] 镜像签名（cosign）与 SBOM
- [ ] fail2ban 可选集成（SSH 暴露场景）
- [ ] 多容器拆分形态（docker-compose 微服务版）

---

**License**: MIT · **Maintainer**: yuanshandalishuishou
