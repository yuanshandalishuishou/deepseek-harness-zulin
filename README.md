# DeepSeek Harness 租赁版（deepseek-harness-zulin）

> 基于 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 的**央企融资租赁场景「八位专家」数字化参谋团队**容器化部署方案。

本项目把 DeepSeek 官方 Harness 与一套为大型央企融资租赁公司量身定制的多智能体角色（"八位专家"）打包进一个开箱即用的 Debian 13 容器，并通过 **GitHub Actions 实现「推送即构建 Docker 镜像」**，镜像自动发布到 GitHub Container Registry（GHCR）。

容器内置三大能力：

1. **DeepSeek Harness Web UI（13000）** + **八位专家角色**，通过 `MODEL_CHOICE` 一键切换底层模型；
2. **OpenClaw（18789）/ Hermes（18000/18080）** 两个独立 Agent 网关，可在「管理端口 16688」在线改配并热重启；
3. **🔌 Token-Free Gateway（13456，默认关闭）** —— 内置 [andeya/token-free-gateway](https://github.com/andeya/token-free-gateway)，用**网页会话免 API Key** 调用 Claude / ChatGPT / DeepSeek / Qwen / Gemini / Kimi / Grok / Doubao / GLM / Perplexity 等 13 家模型，对外暴露为 OpenAI 兼容接口。

---

## 目录

- [特性](#特性)
- [架构与端口](#架构与端口)
- [目录结构](#目录结构)
- [前置依赖](#前置依赖)
- [安装方式](#安装方式)
  - [方式一：直接拉取 GHCR 镜像（推荐）](#方式一直接拉取-ghcr-镜像推荐)
  - [方式二：一键部署脚本 deploy.sh](#方式二一键部署脚本-deploysh)
  - [方式三：本地从源码构建](#方式三本地从源码构建)
- [配置：环境变量与模型选择](#配置环境变量与模型选择)
- [Token-Free Gateway（免 Token 网关）](#token-free-gateway免-token-网关)
  - [它是什么 / 原理](#它是什么--原理)
  - [如何启用（Docker 开关）](#如何启用docker-开关)
  - [登录方式：通过 xRDP 远程桌面可视化登录（推荐）](#登录方式通过-xrdp-远程桌面可视化登录推荐)
  - [备选：在本机（有显示器的电脑）授权后拷贝凭证](#备选在本机有显示器的电脑授权后拷贝凭证)
  - [授权完成后验证](#授权完成后验证)
  - [端点与模型 ID](#端点与模型-id)
  - [调用示例（OpenAI SDK / cURL）](#调用示例openai-sdk--curl)
  - [在 OpenClaw / Hermes 中一键启用](#在-openclaw--hermes-中一键启用)
  - [日常维护：重新授权 / 会话过期](#日常维护重新授权--会话过期)
  - [安全注意事项](#安全注意事项)
- [管理端口 16688（在线配置）](#管理端口-16688在线配置)
- [访问与使用](#访问与使用)
- [内置角色（souls/）](#内置角色souls)
- [数据持久化](#数据持久化)
- [自定义与二次开发](#自定义与二次开发)
- [CI/CD：推送即构建](#cicd推送即构建)
- [安全须知](#安全须知)
- [常见问题（FAQ）](#常见问题faq)
- [许可证与上游](#许可证与上游)

---

## 特性

- **八位专家协同**：以「纪总」为总协调人，统筹金融业务、合规、党工纪、财税、架构、开发、测试七路专家，面向央企融资租赁决策场景。
- **多模型可切换**：DeepSeek 官方 / 硅基流动 / 阿里百炼 / 自定义 DeepSeek / 自定义 OpenAI 兼容，启动时通过 `MODEL_CHOICE` 一键切换。
- **完整桌面与远程接入**：内置 Xfce4 桌面（xRDP）+ OpenSSH，既可用 Web UI，也可远程桌面/SSH 进入调试。
- **配置不含密钥**：API Key 等敏感信息**仅在容器首次启动时由环境变量注入**生成 `settings.yaml`，镜像本身零密钥，可直接公开分发。
- **推送即构建**：每次 push 到 `main` 或打 `v*` 标签，GitHub Actions 自动构建并推送 `:latest` / 版本标签镜像到 GHCR。
- **镜像源自适应**：Dockerfile 默认使用官方/全球源（Node.js、npm/pnpm、apt），保证在 GitHub Actions 境外 runner 上稳定构建；国内本地构建可用 `--build-arg` 一键切回清华 / npmmirror 加速。
- **🔌 Token-Free Gateway（免 Token 网关）**：内置 [andeya/token-free-gateway](https://github.com/andeya/token-free-gateway)，通过网页会话**免 API Key** 调用 13 家主流模型，对外暴露为 OpenAI 兼容接口。可通过 `-e ENABLE_TOKEN_FREE_GATEWAY=1` 一键开关。详见[下文](#token-free-gateway免-token-网关)。
- **🛠 管理端口 16688**：浏览器即可在线修改 OpenClaw / Hermes 的令牌、模型、API Key 并热重启；首启随机凭据、强制改密。详见[下文](#管理端口-16688在线配置)。

---

## 架构与端口

```
                  ┌──────────────────────────────────────────────────────┐
  浏览器 13000 ──▶│  DeepSeek Harness Web (pnpm dsh web :3080)            │
  xRDP  13389 ──▶│  Xfce4 桌面 (xrdp)  —— 仅用于调试，非运行必需         │
  SSH   10022 ──▶│  OpenSSH (root)                                       │
                  │                                                        │
  宿主机 13456 ──▶│  Token-Free Gateway  (:3456, OpenAI 兼容 /v1)         │
                  │      │   （默认关闭，需 ENABLE_TOKEN_FREE_GATEWAY=1） │
                  │      ▼ 通过 CDP 驱动                                                  │
                  │  Chromium 有头调试实例 (:9222，xRDP 桌面内)  ← 登录态由客户在远程桌面登录 / webauth 注入 │
                  │                                                        │
                  │  容器内：/opt/dsh (deepseek-harness)                  │
                  │          /opt/token-free-gateway (网关源码+二进制)     │
                  │          /root/.token-free-gateway (配置+授权凭证)     │
                  │          /root/.chrome-tfg-debug (网关 Chromium 用户目录)│
                  └──────────────────────────────────────────────────────┘
```

| 容器内端口 | 宿主机映射 | 服务 |
|-----------|-----------|------|
| `3080` | `13000` | Harness Web UI（官方默认端口 3080） |
| `22` | `10022` | SSH（root / deepseek） |
| `3389` | `13389` | xRDP 远程桌面（root / deepseek） |
| `18789` | `18789` | **OpenClaw** 网关（八位专家多角色；绑定 0.0.0.0） |
| `3000` | `18000` | **Hermes Web UI**（hermes-web-ui 对话界面；绑定 0.0.0.0，需登录令牌） |
| `8080` | `18080` | **Hermes** 管理面板（默认 DeepSeek；绑定 0.0.0.0，首次网页访问需配置认证 provider） |
| `3456` | `13456` | **Token-Free Gateway** 免 Token 网关（OpenAI 兼容 `/v1`；**默认关闭**，见下文） |
| `16688` | `16688` | **管理端口**（在线修改配置、热重启；首启随机凭据） |

> 默认 root 密码为 `deepseek`，仅用于本地/内网调试，生产环境请通过 `entrypoint.sh` 或挂载 `sshd_config` 自行加固。
> Token-Free Gateway 默认端口为 `3456`，**需显式开启**（`ENABLE_TOKEN_FREE_GATEWAY=1`）并自行映射宿主机端口（如 `-p 13456:3456`）后才对外可用。

---

## 目录结构

```
deepseek-harness-zulin/
├── Dockerfile                      # 容器镜像定义（debian:trixie-slim + Node v24.1.0）
├── entrypoint.sh                   # 容器入口：生成 settings.yaml、启动服务、可选启动 Token-Free Gateway
├── patch-web-bind.sh              # 构建期补丁：移除 startup.ts 对 --host 0.0.0.0 的拒绝
├── deploy.sh                      # 一键部署：优先拉 GHCR 镜像，回退本地构建
├── install_token_free_gateway.sh   # （参考）在已运行容器内安装 Token-Free Gateway 的脚本
├── .github/
│   └── workflows/
│       └── docker-image.yml        # GitHub Actions：推送即构建并推送 GHCR
├── souls/                          # 八位专家角色定义（markdown + frontmatter）
│   ├── enterprise-boss.md          #   纪总（总协调人）
│   ├── financial-expert.md         #   纪融（金融）
│   ├── compliance-expert.md        #   纪正（合规）
│   ├── party-labor-discipline.md   #   纪棠（党工纪/文书）
│   ├── tax-expert.md               #   纪衡（财税）
│   ├── architect-expert.md         #   纪枢（架构）
│   ├── dev-expert.md               #   纪码（开发）
│   └── qa-expert.md                #   纪测（测试）
├── mgmt/
│   └── mgmt.py                     # 管理端口 16688 后端（含 Token-Free Gateway 配置卡片）
├── .gitattributes                  # 强制 LF，保证 shell 脚本在容器内可执行
├── .dockerignore
├── .gitignore
└── README.md
```

> 注意：`entrypoint.sh` 是容器入口，**必须保持 LF 换行**，`.gitattributes` 已全局强制，请勿在 Windows 编辑器中改成 CRLF。
> `mgmt/mgmt.py` 中的「Token-Free Gateway」卡片依赖容器已安装 Chromium / Bun / 网关二进制（由 `ENABLE_TOKEN_FREE_GATEWAY=1` 构建/部署时一并就绪）。

---

## 前置依赖

- 一台能运行 Docker 的 Linux 主机（推荐 Debian 12+/Ubuntu 22.04+，Windows/macOS 亦可，但本文以 Linux 为例）。
- Docker Engine 24+（脚本会自动安装缺失的 Docker）。
- 一个可用的 LLM API Key（DeepSeek 或硅基流动 / 阿里百炼等）；**若仅使用 Token-Free Gateway 则连 API Key 都不需要**。
- 约 **8 GB 磁盘空间**（镜像本身约 3~4 GB，含 Node/pnpm 全量构建产物与桌面环境；启用 Token-Free Gateway 会额外安装 Chromium）。
- 若计划使用 Token-Free Gateway：需一台**有图形界面（显示器/X 服务器）的电脑**用于首次网页授权 `webauth`（详见[下文](#️-必须先做网页授权-webauth含无头陷阱说明)）。

---

## 安装方式

### 方式一：直接拉取 GHCR 镜像（推荐）

镜像由 GitHub Actions 自动构建并发布，无需本地编译：

```bash
docker pull ghcr.io/yuanshandalishuishou/deepseek-harness-zulin:latest

docker run -d --name dsh-debian13 --restart unless-stopped \
    -p 10022:22 -p 13000:3080 -p 13389:3389 \
    -e DEEPSEEK_API_KEY=sk-your-key-here \
    -v dsh-data:/root/.dsh \
    ghcr.io/yuanshandalishuishou/deepseek-harness-zulin:latest
```

> 若仓库为私有，需先 `docker login ghcr.io`，用户名填 GitHub 用户名，密码用勾选了 `read:packages` 的 PAT。本仓库当前为**公开**，可直接 pull。

### 方式二：一键部署脚本 deploy.sh

脚本会优先拉取 GHCR 镜像；若拉取失败（例如私有仓库或首次构建未完成），自动回退为克隆仓库 + 本地构建。

```bash
# 下载脚本
curl -fsSL https://raw.githubusercontent.com/yuanshandalishuishou/deepseek-harness-zulin/main/deploy.sh -o deploy.sh
chmod +x deploy.sh

# 配置模型（默认 DeepSeek 官方）
export DEEPSEEK_API_KEY=sk-your-key-here
# 例如改用硅基流动：export MODEL_CHOICE=2 OPENAI_API_KEY=sk-sf-xxx
bash deploy.sh
```

脚本完成后会打印 Web UI、SSH、xRDP 的访问信息与凭据。

### 方式三：本地从源码构建

```bash
git clone https://github.com/yuanshandalishuishou/deepseek-harness-zulin.git
cd deepseek-harness-zulin

# 可选：固定 deepseek-harness 上游版本
docker build --build-arg DSH_REF=<commit-sha-or-tag> -t dsh-zulin:local .

# 国内加速（默认走官方/全球源，GitHub Actions 构建无需此参数）：
docker build \
  --build-arg DEBIAN_MIRROR=https://mirrors.tuna.tsinghua.edu.cn \
  --build-arg NODE_DIST=https://mirrors.tuna.tsinghua.edu.cn/nodejs-release \
  --build-arg NPM_REGISTRY=https://registry.npmmirror.com \
  -t dsh-zulin:local .

docker run -d --name dsh-debian13 --restart unless-stopped \
    -p 10022:22 -p 13000:3080 -p 13389:3389 \
    -e DEEPSEEK_API_KEY=sk-your-key-here \
    -v dsh-data:/root/.dsh \
    dsh-zulin:local
```

---

## 配置：环境变量与模型选择

所有配置通过环境变量传入容器，**首次启动时 `entrypoint.sh` 据此生成 `/root/.dsh/settings.yaml`**。修改 Key 或模型后，删除容器并重新运行即可（数据卷 `dsh-data` 中的旧 `settings.yaml` 会阻止重新生成——见[数据持久化](#数据持久化)）。

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `DEEPSEEK_API_KEY` | DeepSeek 官方 API Key | 空 |
| `OPENAI_API_KEY` | OpenAI 兼容 API Key（硅基流动 / 百炼 / 自建） | 空 |
| `MODEL_CHOICE` | 模型选择，见下表 | `1` |
| `CUSTOM_MODEL_NAME` | `MODEL_CHOICE=4` 时使用的 DeepSeek 模型名 | `deepseek-v4-pro` |
| `CUSTOM_OPENAI_BASE_URL` | `MODEL_CHOICE=2/3/5` 时的 base-url | `2`→硅基流动、`3`→百炼 内置 |
| `CUSTOM_OPENAI_MODEL` | `MODEL_CHOICE=5` 时的模型名 | 空 |
| `ROOT_USER` | SSH / xRDP 登录用户名（两者共用同一系统账户） | `root` |
| `ROOT_PASSWORD` | SSH / xRDP 登录密码 | `deepseek` |
| `WEB_PORT` | dsh web 容器内监听端口（官方默认 3080） | `3080` |
| `WEB_HOST` | dsh web 绑定地址（`0.0.0.0` 对容器外开放；如需仅本机可改 `127.0.0.1`） | `0.0.0.0` |
| `WEB_TRUSTED_HOSTS` | dsh web `/api` 信任的浏览器来源（host:port，逗号分隔） | `127.0.0.1:13000,192.168.31.100:13000` |
| `OPENCLAW_PORT` | OpenClaw 网关容器内监听端口 | `18789` |
| `HERMES_WEB_PORT` | Hermes Web UI 容器内监听端口 | `3000` |
| `HERMES_DASH_PORT` | Hermes 管理面板容器内监听端口 | `8080` |
| `MGMT_PORT` | 管理端口 16688 监听端口 | `16688` |
| `ENABLE_TOKEN_FREE_GATEWAY` | **是否启用 Token-Free Gateway 免 Token 网关** | `0`（关闭） |
| `TFG_PORT` | Token-Free Gateway 容器内监听端口（OpenAI 兼容 `/v1`） | `3456` |
| `TFG_API_KEY` | 客户端调用网关的 Bearer Token（**默认空=不鉴权**） | 空 |
| `TFG_CDP_URL` | Chromium CDP 调试端点（xrdp 模式下由桌面内「有头」Chromium 提供，默认 `http://127.0.0.1:9222`） | `http://127.0.0.1:9222` |
| `TFG_LOGIN_MODE` | Chromium 启动方式：`xrdp`（默认，桌面内「有头」浏览器，可可视化登录）/ `headless`（容器启动即无头 Chromium） | `xrdp` |

**`MODEL_CHOICE` 取值：**

| 值 | 提供商 | 所需变量 | 默认模型 |
|----|--------|---------|---------|
| `1` | DeepSeek 官方 | `DEEPSEEK_API_KEY` | `deepseek-v4-flash`（快/通用） |
| `2` | 硅基流动（SiliconFlow） | `OPENAI_API_KEY` | `sf-qwen2.5-72b`（Qwen/Qwen2.5-72B-Instruct） |
| `3` | 阿里百炼（DashScope） | `OPENAI_API_KEY` | `dash-qwen-plus`（qwen-plus） |
| `4` | DeepSeek + 自定义模型名 | `DEEPSEEK_API_KEY` + `CUSTOM_MODEL_NAME` | `deepseek-v4-flash` |
| `5` | 自定义 OpenAI 兼容 | `OPENAI_API_KEY` + `CUSTOM_OPENAI_BASE_URL` + `CUSTOM_OPENAI_MODEL` | 由 `CUSTOM_OPENAI_MODEL` 决定 |

> **⚠️ DeepSeek 模型名已更新（2026-07-24 起）**：旧名 `deepseek-chat` / `deepseek-reasoner` 已正式弃用失效。当前官方 **API** 模型为 **`deepseek-v4-flash`**（通用/高速）、**`deepseek-v4-pro`**（强推理/编码）。本仓库已统一切换为 `deepseek-v4-flash` + `deepseek-v4-pro`；OpenClaw 与 Hermes 的默认模型名也已对齐为 `deepseek-v4-pro`。
> **⚠️ 但 Token-Free Gateway 走的是各 AI 网站的「网页模型」**，其模型名≠API 模型名（例如 DeepSeek 网页模型为 `deepseek-chat` / `deepseek-reasoner`，而非 API 的 `deepseek-v4-pro`）。在网关中请使用**网页模型名**，详见[下文](#端点与模型-id)。

示例——使用硅基流动 Qwen：

```bash
docker run -d --name dsh-debian13 \
    -p 13000:3080 -e MODEL_CHOICE=2 -e OPENAI_API_KEY=sk-sf-xxx \
    -v dsh-data:/root/.dsh \
    ghcr.io/yuanshandalishuishou/deepseek-harness-zulin:latest
```

示例——自定义 OpenAI 兼容（如本地 vLLM / 自建网关）：

```bash
docker run -d --name dsh-debian13 \
    -p 13000:3080 \
    -e MODEL_CHOICE=5 \
    -e OPENAI_API_KEY=sk-any \
    -e CUSTOM_OPENAI_BASE_URL=https://my-gateway.example.com/v1 \
    -e CUSTOM_OPENAI_MODEL=my-model \
    -v dsh-data:/root/.dsh \
    ghcr.io/yuanshandalishuishou/deepseek-harness-zulin:latest
```

**自定义 SSH / xRDP 登录凭据**（默认 `root` / `deepseek`，建议公网/不可信网络务必修改）：

```bash
docker run -d --name dsh-debian13 \
    -p 10022:22 -p 13000:3080 -p 13389:3389 \
    -e DEEPSEEK_API_KEY=sk-xxx \
    -e ROOT_PASSWORD='Str0ng!Pass#w0rd' \
    -v dsh-data:/root/.dsh \
    ghcr.io/yuanshandalishuishou/deepseek-harness-zulin:latest
# 也可改用非 root 账户：
#   -e ROOT_USER=alice -e ROOT_PASSWORD='...'   （会自动建用户并授权 sudo，xRDP 桌面照常可用）
```

> 注：`ROOT_USER` / `ROOT_PASSWORD` 同时作用于 **SSH(22)** 与 **xRDP(3389)**，二者共用同一个 Linux 系统账户。

---

## Token-Free Gateway（免 Token 网关）

### 它是什么 / 原理

[andeya/token-free-gateway](https://github.com/andeya/token-free-gateway) 是一个**轻量级、OpenAI 兼容的 API 网关**，对外暴露标准的 `/v1/chat/completions` 等接口，支持完整的 Tools / Function Calling。核心特点：

- 通过**浏览器网页会话**（而非 API Token）调用各 AI 网站，**完全免费、无需任何 API Key**；
- 支持 **13 家提供商**：Claude、ChatGPT、DeepSeek、Doubao、Gemini、GLM、GLM Intl、Grok、Kimi、Perplexity、Qwen、Qwen CN、Xiaomi MiMo；
- 原理：在容器内驱动一个 **Chromium**（通过 Chrome DevTools Protocol，CDP `:9222`），登录各 AI 网站后用网页会话转发请求，**绕过 Cloudflare 等机器人防护**。

> 本镜像已内置该网关（源码位于 `/opt/token-free-gateway`，独立二进制位于 `/usr/local/bin/token-free-gateway`，运行需 `bun`），并预装了 Chromium。**默认关闭**，通过环境变量开关。

```
客户端 (OpenAI SDK / 任意 /v1 客户端)
        │  POST /v1/chat/completions
        ▼
Token-Free Gateway  (:3456)
        │  注入 cookies/token，经 CDP 驱动
        ▼
Chromium  (:9222, 已登录某 AI 网站)
        │  page.evaluate / 浏览器内 fetch（带登录态）
        ▼
AI 网站（Claude / ChatGPT / DeepSeek ...）
```

### 如何启用（Docker 开关）

运行容器时加 `-e ENABLE_TOKEN_FREE_GATEWAY=1` 与端口映射即可：

```bash
docker run -d --name dsh-debian13 --restart unless-stopped \
    -p 10022:22 -p 13000:3080 -p 13389:3389 \
    -p 13456:3456 \
    -e ENABLE_TOKEN_FREE_GATEWAY=1 \
    -v dsh-data:/root/.dsh \
    ghcr.io/yuanshandalishuishou/deepseek-harness-zulin:latest
```

- `-e ENABLE_TOKEN_FREE_GATEWAY=1`：开启网关。xrdp 模式（默认）下容器启动时不预拉 Chromium，登录 xRDP 桌面后由桌面自动拉起「有头」Chromium 于 CDP `9222`；`headless` 模式则启动即拉起无头 Chromium。
- `-p 13456:3456`：把容器内网关端口映射到宿主机 `13456`（端口号随意，保持 `宿主:3456` 即可）。
- 可选：`-e TFG_PORT=3456`（改容器内端口）、`-e TFG_API_KEY=你的令牌`（如需对客户端鉴权）、`-e TFG_CDP_URL=...`（自定义 CDP 端点，例如指向你自己在别的机器上运行的 Chrome）。

> 启用后可用 `http://<宿主机IP>:13456/health` 查看状态；网关未授权任何 provider 时 `/v1/models` 为空、聊天会返回 "No authorized provider"。

### 登录方式：通过 xRDP 远程桌面可视化登录（推荐）

网关依赖**已登录的网页会话**（凭证存于 `/root/.token-free-gateway/auth-profiles.json`）。推荐做法：让客户直接通过 xRDP 远程桌面，在**看得见的浏览器**里完成登录 —— 这彻底规避了旧版的「无头陷阱」（`webauth` 把登录页开在不可见的无头窗口里，无法输入账号）。

本镜像默认 `TFG_LOGIN_MODE=xrdp`：容器启动时**不再**预拉无头 Chromium，而是当你登录 xRDP 桌面后，由桌面自启动脚本 `/usr/local/bin/tfg-chrome-xrdp.sh` 拉起一个**有头（可见）Chromium**（CDP `9222`，用户目录位于卷 `dsh-chrome-tfg`，登录态持久化）。之后 `webauth` 直接复用这个已登录会话即可。

**步骤：**

1. **用 RDP 客户端连接远程桌面**：地址 `<宿主机IP>:13389`，账户 `root` / 密码 `deepseek`（SSH 与 xRDP 共用）。
2. **桌面自动打开 Chromium**（标题栏可见，监听 `9222`）。在浏览器里逐一登录你要用的 AI 网站（DeepSeek / Claude / ChatGPT 等）。登录态会写入卷 `dsh-chrome-tfg`，容器重启后仍在。
3. **在容器内捕获会话**（任选其一）：
   - **复用已登录会话（最简单）**：在能执行 `docker` 的机器上运行
     ```bash
     docker exec -it dsh-prod token-free-gateway webauth
     ```
     向导会连上 9222 那个**可见** Chromium，检测到已有会话后直接写入 `auth-profiles.json`（无需重新登录），按回车确认即可。
   - **当场登录**：若你还没在桌面浏览器里登录，就在 `webauth` 向导弹出的标签页里登录，回车确认后凭证自动保存。
4. **无需重启网关**，刷新 `http://<宿主机IP>:13456/v1/models` 即可看到对应模型。

> 💡 xRDP 会话在断开后默认保留（`sesman KillDisconnected=false`），所以即使你关掉 RDP 客户端，那个 Chromium 与登录态仍存活，网关可持续工作；直到你主动注销 xRDP 会话。因此只要客户登录过一次桌面并完成授权，网关长期可用。

### 备选：在本机（有显示器的电脑）授权后拷贝凭证

若你不想用 xRDP，也可在**自己的电脑**（Windows / macOS / Linux，已装 Chrome/Chromium、有显示器）上完成授权，再把凭证文件拷进容器。容器内网关每次请求都会重新读取 `auth-profiles.json`，**无需在容器内做登录**。

1. **本机安装网关**（任选其一，需要 Node.js ≥ 18）：
   ```bash
   # 方式 1：npm 全局安装（最简单）
   npm install -g token-free-gateway

   # 方式 2：下载预编译二进制
   #   https://github.com/andeya/token-free-gateway/releases 下载对应平台，
   #   解压后 chmod +x token-free-gateway 并放到 PATH。
   ```
2. **本机执行授权向导**（会自动拉起一个可见的 Chrome，并打开 13 家 provider 的登录页）：
   ```bash
   token-free-gateway webauth
   ```
   - 用数字/逗号选择你要授权的 provider（如 `3`=DeepSeek，`a`=全部）；
   - 在弹出的浏览器标签页中**逐一登录**你的账号；
   - 回车确认后，凭证保存到本机：
     - **Linux / macOS**：`~/.token-free-gateway/auth-profiles.json`
     - **Windows**：`%USERPROFILE%\.token-free-gateway\auth-profiles.json`
   - 若向导结束没自动退出，按 **Ctrl+C** 即可（凭证已经保存）。
3. **把凭证拷进容器**（在能执行 `docker` 的那台机器上，把上一步的文件传过去后执行）：
   ```bash
   # 假设本机文件在 ./auth-profiles.json
   docker cp ./auth-profiles.json dsh-prod:/root/.token-free-gateway/auth-profiles.json
   ```
   - 若 docker 守护进程在远程主机，请先把文件 `scp` 到该主机，再 `docker cp`。
   - 容器内的目标路径固定为 `/root/.token-free-gateway/auth-profiles.json`（网关以 root 运行）。
4. **无需重启网关**，刷新 `http://<宿主机IP>:13456/v1/models` 即可看到对应模型（见[验证](#授权完成后验证)）。

> ✅ 此方法彻底绕开容器无图形界面的问题，且可把同一份 `auth-profiles.json` 复用到任意容器实例。

### 授权完成后验证

```bash
# 健康状态：browser 应为 connected，providers/models 数量>0
curl -s http://<宿主机IP>:13456/health

# 已授权模型列表（网页模型名）
curl -s http://<宿主机IP>:13456/v1/models

# 一次真实对话（以 DeepSeek 网页模型为例）
curl -s http://<宿主机IP>:13456/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-chat","messages":[{"role":"user","content":"用一句话介绍融资租赁"}]}'
```

### 端点与模型 ID

- **OpenAI 兼容端点**：
  - 容器内：`http://localhost:3456/v1`
  - 宿主机（已映射）：`http://<宿主机IP>:13456/v1`
  - API Key：默认**留空**即可（未设置 `TFG_API_KEY` 时不鉴权）。
- **模型 ID（Model ID）**：使用**提供商前缀**形式（即各家「网页模型名」）：

| Provider | 模型 ID 前缀 / 示例 | 备注 |
|----------|---------------------|------|
| Claude | `claude-sonnet-4-20250514`、`claude-opus-4-20250514` | 会话 cookie |
| ChatGPT | `chatgpt-4o`、`chatgpt-4o-mini` | access token + cookie |
| **DeepSeek** | **`deepseek-chat`、`deepseek-reasoner`** | 注意：≠ API 的 `deepseek-v4-pro` |
| Doubao | `doubao-pro` 等 `doubao-*` | 会话 cookie |
| Gemini | `gemini-2.5-pro` 等 `gemini-*` | Google SID cookie |
| GLM（智谱） | `glm-4.5` 等 `glm-*` | refresh token cookie |
| GLM Intl | `glm-intl-*` | 会话 cookie |
| Grok | `grok-4` 等 `grok-*` | SSO cookie |
| Kimi | `kimi-k2` 等 `kimi-*` | access token |
| Perplexity | `perplexity-sonar` 等 `perplexity-*` | next-auth cookie |
| Qwen | `qwen-max` 等 `qwen-*` | 会话 cookie |
| Qwen CN | `qwen-cn-*` | XSRF + cookie |
| Xiaomi MiMo | `xiaomimo-*` | bearer token |

- 授权后可通过 `GET /v1/models` 列出**当前可用模型**（仅列出已成功授权的 provider）。
- ⚠️ **区分模型名来源**：网关用的是各网站的**网页模型名**（如 `deepseek-chat`），而直连 DeepSeek API / OpenClaw / Hermes 用的是 `deepseek-v4-pro`。两者不同，请勿混用。

### 调用示例（OpenAI SDK / cURL）

任意支持 OpenAI 兼容接口的客户端，把 base_url 指向网关即可：

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://<宿主机IP>:13456/v1",   # 或容器内 http://localhost:3456/v1
    api_key="any-string",                     # 未设 TFG_API_KEY 时随意填
)

resp = client.chat.completions.create(
    model="deepseek-chat",                    # 网页模型名，见上表
    messages=[{"role": "user", "content": "你好"}],
)
print(resp.choices[0].message.content)
```

```bash
# 列出模型
curl http://<宿主机IP>:13456/v1/models

# 聊天（流式/非流式均支持）
curl http://<宿主机IP>:13456/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-20250514","messages":[{"role":"user","content":"Hello!"}]}'
```

> 若设置了 `TFG_API_KEY`，所有 `/v1/*` 请求需带 `Authorization: Bearer <你的key>`（仅 `/health` 免鉴权）。

### 在 OpenClaw / Hermes 中一键启用

最方便的方式是打开**管理端口 16688** 的「Token-Free Gateway」卡片：

1. 在卡片中填入要使用的**网页模型 ID**（如 `deepseek-chat`）；
2. 点击「应用到 OpenClaw」或「应用到 Hermes」，管理后端会自动：
   - 为对应工具写入一个 `tokenfree` provider，`base_url` 指向 `http://localhost:3456/v1`；
   - 将默认模型设为所选的网关模型（OpenClaw：`model.primary=tokenfree/<模型>`；Hermes：`provider=tokenfree` + `default=<模型>`）；
   - 热重载该服务使配置生效。
3. 此后 OpenClaw / Hermes 的对话即走 Token-Free Gateway，**免 API Key**。

> 💡 **一键捕获登录态**：在 xRDP 桌面里登录各 AI 网站后，直接点卡片上的「一键捕获登录态 (webauth)」按钮，即可在容器内自动遍历已登录的 provider 并把凭证写入 `auth-profiles.json`——无需手动执行 `webauth` 命令。按钮会先检查 RDP 桌面中的 Chrome（CDP `9222`）是否在线；若你还没登录 xRDP 桌面（宿主机 IP:`13389`，账户 `root`），会提示你先去桌面完成登录。

你也可以在任何**支持 OpenAI 兼容接口的客户端**（OpenWebUI、自建应用等）中直接填：
- Base URL：`http://<宿主机IP>:13456/v1`（或容器内 `http://localhost:3456/v1`）
- API Key：留空
- Model：上述任一网页模型名

### 日常维护：重新授权 / 会话过期

- **某家 provider 返回 `session_expired` 或突然不可用**：其网页登录态过期了，重新跑一次 `webauth`（方法 A 或 B）更新 `auth-profiles.json` 即可，无需重建容器。
- **容器重启**：网关每次启动都会重新读 `auth-profiles.json`。**但**无头 Chromium 的用户目录 `/root/.chrome-tfg-debug` 若未挂卷，重启会重建（登录态在 `auth-profiles.json` 里仍保留，一般不影响使用；个别 provider 若强依赖浏览器 profile 则需重新 webauth）。
- **DeepSeek 特别提示**：`webauth` 会捕获 DeepSeek 聊天页的 bearer token；授权时**保持 DeepSeek 聊天页打开**，让向导自动捕获登录态。

### 安全注意事项

- 网关通过**你的浏览器会话**调用各 AI 网站，**等同于用你的账号在使用这些服务**，请遵守各平台服务条款；
- `webauth` 登录态（存于 `auth-profiles.json` + Chrome profile）等同于账号凭证，务必妥善保管容器与对应卷；
- **未设 `TFG_API_KEY` 时网关不鉴权**：公网暴露 13456 端口将导致任何人可免 Key 借用你的会话——**公网环境务必设置 `TFG_API_KEY` 并仅对内网开放**。

---

## 管理端口 16688（在线配置）

管理端口提供一个轻量 Web 界面，用于**免重建容器**地修改运行期配置：

- **首启随机凭据**：容器首次启动时生成随机 `admin-xxxx` 用户名 + 随机密码，写入 `/root/.dsh/MGMT_CREDENTIALS.txt` 并打印到容器日志；登录后**强制要求修改密码**。
- **可在线修改**：
  - **OpenClaw**：网关令牌、默认模型、备用模型、DeepSeek API Key；
  - **Hermes**：默认模型（`model.default`，默认 `deepseek-v4-pro`，与 OpenClaw 对齐）、provider、DeepSeek API Key；
  - **Token-Free Gateway**：所选模型 ID、一键「应用到 OpenClaw / Hermes」、实时状态、使用说明。
- **热重启**：保存配置后点击对应「重启」按钮，即写配置文件并重启对应服务，无需重建容器。

访问：`http://<宿主机IP>:16688`。凭据见 `/root/.dsh/MGMT_CREDENTIALS.txt` 或 `docker logs dsh-debian13`（每次重建容器会刷新）。

---

## 访问与使用

| 服务 | 地址 / 命令 | 凭据 |
|------|------------|------|
| **Web UI（局域网浏览器直连）** | 浏览器访问 `http://<宿主机IP>:13000` | — |
| **Web UI（容器内/xRDP 桌面）** | xRDP 桌面里打开浏览器访问 http://localhost:3080 | — |
| **SSH** | `ssh -p 10022 root@<宿主机IP>` | `root` / `deepseek` |
| **xRDP** | Windows 远程桌面连接 `<宿主机IP>:13389` | `root` / `deepseek` |
| **OpenClaw 网关** | 浏览器访问 `http://<宿主机IP>:18789` | 默认 DeepSeek（`DEEPSEEK_API_KEY` 注入） |
| **Hermes Web UI** | 浏览器访问 `http://<宿主机IP>:18000` | 默认 DeepSeek；登录令牌见容器日志或 `HERMES_WEBUI_TOKEN` |
| **Hermes 管理面板** | 浏览器访问 `http://<宿主机IP>:18080` | 默认 DeepSeek；首次网页需配置认证 provider |
| **Token-Free Gateway** | `http://<宿主机IP>:13456/v1`（需启用并映射） | 默认不鉴权（留空即可） |
| **管理端口** | 浏览器访问 `http://<宿主机IP>:16688` | 首启随机凭据（见 `/root/.dsh/MGMT_CREDENTIALS.txt`） |

> **OpenClaw / Hermes 说明**
> - OpenClaw：多角色 AI 助手网关。其工作区 `~/.openclaw/workspace/souls/` 内的八位专家人设与 DeepSeek Harness 的 `souls/` **完全一致**（构建期从同一来源复制）。网关默认 `deepseek/deepseek-v4-pro`，API Key 通过 `DEEPSEEK_API_KEY` 环境变量注入（镜像零密钥）。
> - Hermes：NousResearch 出品的成长型 Agent，默认 provider 为 DeepSeek（`providers.deepseek[].source: env:DEEPSEEK_API_KEY`，默认模型 `deepseek-v4-pro`）。本镜像暴露两个 Web 面：① **Web UI（hermes-web-ui 对话界面）**绑定 `0.0.0.0:3000`（映射宿主 18000），访问需登录令牌（默认 `hermes-webui-default`，可由 `HERMES_WEBUI_TOKEN` 覆盖）；② **管理面板 Dashboard** 绑定 `0.0.0.0:8080`（映射宿主 18080），因公网绑定，**首次网页访问须先配置认证 provider**（Nous Portal OAuth 或密码）。

> ℹ️ **关于 Web UI 的绑定地址（2026-08 修补）**
> 上游 deepseek-harness 的 `startup.ts` 曾硬编码拒绝 `--host 0.0.0.0`（安全原因，避免把无鉴法的
> 开发服务器暴露到全网导致远程代码执行）。本镜像在构建阶段用 **`patch-web-bind.sh`** 精确删除该限制块——webserver 配置 schema 本身允许 `"127.0.0.1" | "0.0.0.0"`，
> 因此放开后 `--host 0.0.0.0 --port 3080` 即可正常对外提供 Web UI，**`http://<宿主机IP>:13000`
> 可直接访问**，无需再走 SSH 隧道。
>
> **`/api` 浏览器信任围栏（browser-trust fence）**：为防止跨站请求伪造，`/api` 仅放行本机
> 来源与 `--trusted-host` 白名单。**局域网内用浏览器直连时，请通过环境变量放行你的访问地址**，
> 例如本机地址是 192.168.31.100（映射端口 13000）：
> ```bash
> -e WEB_TRUSTED_HOSTS=192.168.31.100:13000,127.0.0.1:13000
> ```
> 默认值已含 `127.0.0.1:13000,192.168.31.100:13000`（覆盖 SSH 隧道与局域网直连）；如换用其他
> 宿主 IP，请追加对应的 `宿主IP:13000`，否则页面能开但部分 `/api` 请求可能被信任围栏拒绝。

首次启动后查看日志确认就绪：

```bash
docker logs -f dsh-debian13
# 看到 "启动 DeepSeek Harness on 0.0.0.0:3080..." 且无报错，说明已正常监听
```

浏览器打开 Web UI 后，默认以「纪总（enterprise-boss）」人格接待。可直接下达如「请评估一笔售后回租业务的交易结构风险」之类的总协调任务，纪总会自动分派给对应专家并汇总。

---

## 内置角色（souls/）

每个角色一个 Markdown 文件，含 YAML frontmatter（`name`/`id`/`emoji`/`description`）与正文设定。

| 专家 | ID | 角色定位 | 核心职责 |
|------|-----|---------|---------|
| 纪总 | `enterprise-boss` | 总协调人（**默认 persona**） | 解析需求→分派专家→整合结论；遵循「政治优先→风险底线→业务最优」裁决原则；正式公文交纪棠润色；末尾附【需人工核验项】 |
| 纪融 | `financial-expert` | 金融业务专家 | ABS、融资租赁（直租/回租/杠杆租赁）、商业保理、外汇与境外投资、股权投资、信托与银行；精通 IRR/XIRR 测算 |
| 纪正 | `compliance-expert` | 合规专家 | 合规审查、制度建设、案件协查；出具含「红/黄/绿」风险灯的标准合规意见书；覆盖反洗钱、数据安全、制裁合规 |
| 纪棠 | `party-labor-discipline` | 党工纪与文书专家 | 党务、工会、纪检；纪委公文撰写；五维审核（法条/账本/税表/纪律/政治影响）；恪守 24 字办案方针 |
| 纪衡 | `tax-expert` | 财税专家 | CAS/IFRS 核算、NPV/IRR 复核、跨境税务架构、转让定价、国资委「一利五率」影响分析 |
| 纪枢 | `architect-expert` | 软件架构专家 | 金融级高可用架构、信创适配（达梦/金仓/TiDB/麒麟/统信）、等保三级、国密改造 |
| 纪码 | `dev-expert` | 软件开发专家 | 资金交易核心编码、零信任审查、国密 SM2/SM3/SM4、DDD 与 SOLID、SonarQube A 级 |
| 纪测 | `qa-expert` | 软件测试专家 | 功能/性能/安全/灾备测试、资金准确性端到端核对、致命缺陷一票否决 |

---

## 数据持久化

容器使用命名卷 `dsh-data` 挂载到 `/root/.dsh`：

- `settings.yaml`：运行时生成的配置
- `souls/`：八位专家角色文件副本
- `.plugins_installed`：插件安装标记（避免每次重启重复装插件）

**重要**：`entrypoint.sh` 仅在「`settings.yaml` 或 `souls/` 不存在」时才重新生成。因此——

- 想**切换模型/Key**：不要直接改卷内文件，而是 `docker rm -f dsh-debian13 && docker run ...`（带新环境变量）重新创建容器；卷内旧 `settings.yaml` 会阻止重新生成。如需强制重置配置，先 `docker volume rm dsh-data`（会清空角色与对话数据）再用新变量启动。
- 想**保留对话/角色但改 Key**：进入容器 `docker exec -it dsh-debian13 bash`，编辑 `/root/.dsh/settings.yaml` 后重启服务。

> **Token-Free Gateway 持久化提示**
> - 授权凭证：`/root/.token-free-gateway/auth-profiles.json`，**默认不在 `dsh-data` 卷内**，但体积小、可随时用方法 A 重新生成/拷贝，无需挂卷。
> - 浏览器用户目录：`/root/.chrome-tfg-debug`，**默认不在 `dsh-data` 卷内**。若希望重启容器后免重复 `webauth`，可额外挂载卷：`-v dsh-tfg-chrome:/root/.chrome-tfg-debug`。

---

## 自定义与二次开发

1. **新增 / 修改角色**：编辑 `souls/*.md`（保留 frontmatter 格式），重新构建镜像（或把文件挂载进 `/opt/dsh-initial/souls` 后重置 `dsh-data` 卷）。
2. **更换默认 persona**：修改 `entrypoint.sh` 中 `persona: enterprise-boss` 与 `deploy.sh`/README 中的默认角色说明。
3. **固定上游版本**：`docker build --build-arg DSH_REF=<tag-or-sha>`。不指定时默认拉上游 `master` 分支（上游默认分支为 `master`，非 `main`）。
4. **调整桌面/工具**：编辑 `Dockerfile` 的 `apt-get install` 列表。
5. **切换基础镜像源**：默认使用官方/全球源（适配 GitHub Actions 境外构建）。国内加速请传构建参数：`--build-arg DEBIAN_MIRROR=https://mirrors.tuna.tsinghua.edu.cn --build-arg NODE_DIST=https://mirrors.tuna.tsinghua.edu.cn/nodejs-release --build-arg NPM_REGISTRY=https://registry.npmmirror.com`（`deploy.sh` 的本地回退构建已默认带上这些国内镜像）。
6. **启用 / 调整 Token-Free Gateway**：见[上文](#token-free-gateway免-token-网关)；相关逻辑在 `entrypoint.sh` 的「⑥.③」段与 `mgmt/mgmt.py` 的「Token-Free Gateway」卡片。
7. **把 TFG 开关写进 deploy.sh**：若希望默认部署即带网关，可在 `deploy.sh` 中给 `docker run` 增加 `-p 13456:3456 -e ENABLE_TOKEN_FREE_GATEWAY=1`。

---

## CI/CD：推送即构建

`.github/workflows/docker-image.yml` 在以下事件触发：

- `push` 到 `main` 分支
- `push` 标签 `v*`（如 `v1.0.0`）
- 在 Actions 页面手动 `workflow_dispatch`

工作流使用内置 `GITHUB_TOKEN` 登录 GHCR，**无需配置任何 Secret**（`packages: write` 权限已声明）。发布规则：

| 触发 | 镜像标签 |
|------|---------|
| push 到 main | `:latest` |
| 标签 `v1.2.0` | `:1.2.0`、`latest`（当为默认分支时） |
| 每次构建 | `:sha-<commit>`（便于回滚） |

> 构建平台固定为 `linux/amd64`（因 Node.js 二进制为 x64）。如需多架构，请在 Dockerfile 中将 Node 下载改为架构感知，并工作流加 `platforms: linux/amd64,linux/arm64`。

查看构建进度：[仓库 Actions 页面](https://github.com/yuanshandalishuishou/deepseek-harness-zulin/actions)。

---

## 安全须知

- **不要将 API Key 写进仓库或 Dockerfile**。本项目刻意把配置延迟到运行时注入，请继续保持这一约定。
- **更换泄露的 Token / Key**：若 GitHub PAT 或任何 API Key 曾暴露，立即在 GitHub 撤销并重发；本仓库推送时仅临时使用 token，未写入任何文件。
- **root 密码**：容器默认 `root:deepseek`，仅适合本地/内网。生产环境请在 `entrypoint.sh` 中改为强密码或禁用密码登录、改用密钥。
- **暴露面**：SSH(10022)/xRDP(13389)/Web(13000)/管理端口(16688) 均对宿主机开放，公网部署务必加防火墙或反向代理 + 鉴权。
- **Token-Free Gateway 风险**：网关通过你的浏览器会话调用各 AI 网站，**等同于用你的账号在使用这些服务**，请遵守各平台服务条款；`webauth` 登录态等同于账号凭证，务必妥善保管容器与对应卷。未设 `TFG_API_KEY` 时网关不鉴权，公网暴露端口（如 13456）将导致任何人可免 Key 借用你的会话——**公网环境务必设置 `TFG_API_KEY` 并仅对内网开放**。
- **GHCR 可见性**：仓库为公开时镜像也公开，任何人可 `docker pull`；若含敏感角色设定，建议将仓库与镜像设为私有（私有镜像需 `docker login ghcr.io`）。

---

## 常见问题（FAQ）

**Q1：Web UI 打不开 / 一直转圈？**
A：先 `docker logs -f dsh-debian13`，确认出现「启动 DeepSeek Harness on 0.0.0.0:3080」且无报错。新版镜像已放开绑定限制（构建阶段由 `patch-web-bind.sh` 移除 startup.ts 的 0.0.0.0 拒绝），**直接开 `http://<宿主机IP>:13000`** 即可；页面能开但部分 `/api` 请求被拒时，请给容器加 `-e WEB_TRUSTED_HOSTS=192.168.31.100:13000,127.0.0.1:13000` 后重建。若日志里出现 `error: --host` 或 `unknown option`，说明还在用旧镜像，请 `docker pull` 最新镜像后重建容器。

**Q2：改了 MODEL_CHOICE 但模型没变？**
A：卷内已有 `settings.yaml`，entrypoint 不会重新生成。删除容器并重跑（见[数据持久化](#数据持久化)），或 `docker exec` 进容器改 `/root/.dsh/settings.yaml` 后重启 harness 进程。

**Q3：GHCR 镜像拉取失败（私有仓库 / 首次构建未完成）？**
A：`deploy.sh` 会自动回退为本地构建；也可手动 `docker login ghcr.io` 后重试，或等 Actions 构建完成（[Actions 页面](https://github.com/yuanshandalishuishou/deepseek-harness-zulin/actions)）。

**Q4：想加自己的专家角色？**
A：复制 `souls/enterprise-boss.md` 改 frontmatter 与正文，重新构建镜像；或在运行时挂载到 `/opt/dsh-initial/souls` 并重置 `dsh-data` 卷。

**Q5：构建太慢 / 卡在 pnpm install？**
A：首次构建需安装 Xfce4 桌面 + 编译 deepseek-harness，通常 20~40 分钟。GitHub Actions 默认走官方/全球源并启用缓存（`type=gha`）可显著加快二次构建；国内本地构建传入清华 / npmmirror 镜像参数后拉取更快。

**Q6：容器重启后插件又要重装？**
A：不会。`.plugins_installed` 标记存于 `dsh-data` 卷，首次安装后即跳过。

**Q7：执行 `token-free-gateway webauth` 后卡在 "Please login ... in the opened browser window"？**
A：这是**无头陷阱**——本镜像的 entrypoint 已先拉起一个无头 Chromium 常驻 9222，于是 `webauth` 直接连上那个**看不见**的浏览器，登录页开在了你无法看到的地方。解决：
   1. 先 `Ctrl+C` 退出当前卡住的 webauth；
   2. **推荐**用[方法 A](#授权方法-a在本机有显示器的电脑授权后拷贝凭证推荐)：在本机（有显示器的电脑）跑 `token-free-gateway webauth` 完成登录，再把本机的 `~/.token-free-gateway/auth-profiles.json` 用 `docker cp` 拷进容器 `/root/.token-free-gateway/auth-profiles.json`；
   3. 若坚持在容器内授权，需先在**有桌面/X 显示**的环境里 `token-free-gateway chrome stop`（让 9222 空闲），再跑 `webauth`，最后 `docker restart dsh-prod`。

**Q8：Hermes 默认模型为什么是 deepseek-v4-pro 而不是 deepseek-chat？**
A：`deepseek-chat` 是已弃用的旧 **API** 模型名；当前 DeepSeek 官方 API 模型为 `deepseek-v4-flash` / `deepseek-v4-pro`，与 OpenClaw 的命名完全一致，故本仓库统一为 `deepseek-v4-pro`。注意：通过 Token-Free Gateway 调用 DeepSeek **网页**模型时仍使用 `deepseek-chat`（网页模型名），二者来源不同，请按各自说明填写。

**Q9：13456 访问报错 / /v1/models 为空？**
A：依次排查：① 是否加了 `-e ENABLE_TOKEN_FREE_GATEWAY=1` 且映射了 `-p 13456:3456`；② 容器内 Chromium 是否拉起（`docker logs dsh-debian13 | grep -i chrome`）；③ 是否完成至少一家 provider 的授权（未授权时 `/v1/models` 为空、聊天返回 "No authorized provider"）；④ 防火墙是否放行 13456。状态用 `http://<宿主IP>:13456/health` 查看（`browser`/`providers`/`models` 字段）。

**Q10：Token-Free Gateway 调用各家模型时报 "session_expired" / 突然不可用？**
A：对应 provider 的网页登录态过期了。重新跑一次 `webauth`（方法 A 或 B）更新 `auth-profiles.json` 即可，无需重建容器。

---

## 角色设定脚本（镜像保持原始状态）

镜像内 **不写死** 任何业务角色，所有角色（persona）都由可版本化、可复用的 shell 脚本在需要时按需应用。脚本位于仓库 `role-scripts/` 目录，并随镜像部署到容器 `/opt/role-scripts/`，同时在 `/usr/local/bin/` 下建立同名软链接，便于直接调用。

### DeepSeek Harness 角色
```bash
deepseekharness_role.sh            # 默认 enterprise-boss（纪总，八专家总协调人）
deepseekharness_role.sh dev-expert # 纪码（研发专家）
```
脚本从镜像自带资产 `/opt/dsh-initial/souls/*.md` 安装人设到 `/root/.dsh/souls/`，并写入 `/root/.dsh/settings.yaml` 的 `system-prompt.persona`。可用人设即 `/opt/dsh-initial/souls/` 下的 `.md` 文件名（去掉 `.md`）。

### OpenClaw 角色
```bash
openclaw_role.sh   # 默认从 /opt/openclaw-initial/openclaw/workspace 应用纪总 + 八专家人设
```
脚本仅同步角色定义文件（`SOUL.md` / `AGENTS.md` / `IDENTITY.md` / `USER.md` 及可选 `souls/`）到 `/root/.openclaw/workspace`，**不会覆盖你的会话与项目数据**。

> 两条脚本均幂等。切换角色后重启对应服务（或重启容器）即生效。如此可保证同一份镜像在不同部署中复用，角色差异只体现在「运行哪个脚本」。

## 虚拟显示（Xvfb）

镜像已预装 `xvfb`（`Xvfb` / `xvfb-run`）。在无图形界面又需要跑带界面的自动化（脚本化网页授权、截图等）时：
```bash
xvfb-run -a <你的命令>            # 自动分配 :99 等显示
# 或手动: Xvfb :99 -screen 0 1280x1024x24 &  export DISPLAY=:99
```
注意：Token-Free Gateway 的可视化登录仍推荐走 **xRDP 远程桌面**（见上文）；Xvfb 更适用于无头自动化场景。

---

## 许可证与上游

- 上游项目：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)（请遵循其许可证）。
- Token-Free Gateway：[andeya/token-free-gateway](https://github.com/andeya/token-free-gateway)（MIT）。
- 本仓库的 Dockerfile、角色设定、部署脚本按 **MIT** 许可证开源，可自由修改分发；但「八位专家」角色设定为特定业务场景定制内容，二次分发时请注明来源。
- 相关链接：[GitHub 仓库](https://github.com/yuanshandalishuishou/deepseek-harness-zulin) · [GHCR 镜像](https://ghcr.io/yuanshandalishuishou/deepseek-harness-zulin)
