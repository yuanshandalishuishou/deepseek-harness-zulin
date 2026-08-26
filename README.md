# DeepSeek Harness 租赁版（deepseek-harness-zulin）

> 基于 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 的**央企融资租赁场景「八位专家」数字化参谋团队**容器化部署方案。

本项目把 DeepSeek 官方 Harness 与一套为大型央企融资租赁公司量身定制的多智能体角色（"八位专家"）打包进一个开箱即用的 Debian 13 容器，并通过 **GitHub Actions 实现「推送即构建 Docker 镜像」**，镜像自动发布到 GitHub Container Registry（GHCR）。

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
- **完整桌面与远程接入**：内置 Xfce4 桌面（xRDP 3389）+ OpenSSH（22），既可用 Web UI，也可远程桌面/SSH 进入调试。
- **配置不含密钥**：API Key 等敏感信息**仅在容器首次启动时由环境变量注入**生成 `settings.yaml`，镜像本身零密钥，可直接公开分发。
- **推送即构建**：每次 push 到 `main` 或打 `v*` 标签，GitHub Actions 自动构建并推送 `:latest` / 版本标签镜像到 GHCR。
- **镜像源自适应**：Dockerfile 默认使用官方/全球源（Node.js、npm/pnpm、apt），保证在 GitHub Actions 境外 runner 上稳定构建；国内本地构建可用 `--build-arg` 一键切回清华/ npmmirror 加速。

---

## 架构与端口

```
                  ┌──────────────────────────────────────────────┐
  浏览器 13000 ──▶│  DeepSeek Harness Web (pnpm dsh web :3000)     │
  xRDP  13389 ──▶│  Xfce4 桌面 (xrdp)                             │
  SSH   10022 ──▶│  OpenSSH (root)                                │
                  │                                                │
                  │  容器内：/opt/dsh (deepseek-harness)          │
                  │        /root/.dsh (配置+角色，由 dsh-data 卷)  │
                  └──────────────────────────────────────────────┘
```

| 容器内端口 | 宿主机映射 | 服务 |
|-----------|-----------|------|
| `3000` | `13000` | Harness Web UI |
| `22` | `10022` | SSH（root / deepseek） |
| `3389` | `13389` | xRDP 远程桌面（root / deepseek） |

> 默认 root 密码为 `deepseek`，仅用于本地/内网调试，生产环境请通过 `entrypoint.sh` 或挂载 `sshd_config` 自行加固。

---

## 目录结构

```
deepseek-harness-zulin/
├── Dockerfile                      # 容器镜像定义（debian:trixie-slim + Node v24.1.0）
├── entrypoint.sh                   # 容器入口：首次启动生成 settings.yaml、启动服务
├── deploy.sh                       # 一键部署：优先拉 GHCR 镜像，回退本地构建
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
├── .gitattributes                  # 强制 LF，保证 shell 脚本在容器内可执行
├── .dockerignore
├── .gitignore
└── README.md
```

> 注意：`entrypoint.sh` 是容器入口，**必须保持 LF 换行**，`.gitattributes` 已全局强制，请勿在 Windows 编辑器中改成 CRLF。

---

## 前置依赖

- 一台能运行 Docker 的 Linux 主机（推荐 Debian 12+/Ubuntu 22.04+，Windows/macOS 亦可，但本文以 Linux 为例）。
- Docker Engine 24+（脚本会自动安装缺失的 Docker）。
- 一个可用的 LLM API Key（DeepSeek 或硅基流动 / 阿里百炼等）。
- 约 **8 GB 磁盘空间**（镜像本身约 3~4 GB，含 Node/pnpm 全量构建产物与桌面环境）。

---

## 安装方式

### 方式一：直接拉取 GHCR 镜像（推荐）

镜像由 GitHub Actions 自动构建并发布，无需本地编译：

```bash
docker pull ghcr.io/yuanshandalishuishou/deepseek-harness-zulin:latest

docker run -d --name dsh-debian13 --restart unless-stopped \
    -p 10022:22 -p 13000:3000 -p 13389:3389 \
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
    -p 10022:22 -p 13000:3000 -p 13389:3389 \
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

**`MODEL_CHOICE` 取值：**

| 值 | 提供商 | 所需变量 | 默认模型 |
|----|--------|---------|---------|
| `1` | DeepSeek 官方 | `DEEPSEEK_API_KEY` | `deepseek-v4-flash`（快/通用） |
| `2` | 硅基流动（SiliconFlow） | `OPENAI_API_KEY` | `sf-qwen2.5-72b`（Qwen/Qwen2.5-72B-Instruct） |
| `3` | 阿里百炼（DashScope） | `OPENAI_API_KEY` | `dash-qwen-plus`（qwen-plus） |
| `4` | DeepSeek + 自定义模型名 | `DEEPSEEK_API_KEY` + `CUSTOM_MODEL_NAME` | `deepseek-v4-flash` |
| `5` | 自定义 OpenAI 兼容 | `OPENAI_API_KEY` + `CUSTOM_OPENAI_BASE_URL` + `CUSTOM_OPENAI_MODEL` | 由 `CUSTOM_OPENAI_MODEL` 决定 |

> **⚠️ DeepSeek 模型名已更新（2026-07-24 起）**：旧名 `deepseek-chat` / `deepseek-reasoner` 已正式弃用失效，调用会直接报错。当前官方 API 模型为 **`deepseek-v4-flash`**（通用/高速）、**`deepseek-v4-pro`**（强推理/编码）与实验性的 **`deepseek-v4-flash-vision-exp`**（多模态）。本仓库已统一切换为 `deepseek-v4-flash` + `deepseek-v4-pro`；如需更强的推理能力，把 `CUSTOM_MODEL_NAME` 设为 `deepseek-v4-pro` 并用 `MODEL_CHOICE=4`，或直接改 `entrypoint.sh` 中的默认模型。

示例——使用硅基流动 Qwen：

```bash
docker run -d --name dsh-debian13 \
    -p 13000:3000 -e MODEL_CHOICE=2 -e OPENAI_API_KEY=sk-sf-xxx \
    -v dsh-data:/root/.dsh \
    ghcr.io/yuanshandalishuishou/deepseek-harness-zulin:latest
```

示例——自定义 OpenAI 兼容（如本地 vLLM / 自建网关）：

```bash
docker run -d --name dsh-debian13 \
    -p 13000:3000 \
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
    -p 10022:22 -p 13389:3389 -p 13000:3000 \
    -e DEEPSEEK_API_KEY=sk-xxx \
    -e ROOT_PASSWORD='Str0ng!Pass#w0rd' \
    -v dsh-data:/root/.dsh \
    ghcr.io/yuanshandalishuishou/deepseek-harness-zulin:latest
# 也可改用非 root 账户：
#   -e ROOT_USER=alice -e ROOT_PASSWORD='...'   （会自动建用户并授权 sudo，xRDP 桌面照常可用）
```

> 注：`ROOT_USER` / `ROOT_PASSWORD` 同时作用于 **SSH(22)** 与 **xRDP(3389)**，二者共用同一个 Linux 系统账户。

---

## 访问与使用

| 服务 | 地址 / 命令 | 凭据 |
|------|------------|------|
| **Web UI** | http://localhost:13000 | 浏览器直接打开 |
| **SSH** | `ssh -p 10022 root@localhost` | `root` / `deepseek` |
| **xRDP** | Windows 远程桌面连接 `localhost:13389` | `root` / `deepseek` |

首次启动后查看日志确认就绪：

```bash
docker logs -f dsh-debian13
# 看到 "启动 DeepSeek Harness on port 3000..." 即可访问 Web UI
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

---

## 自定义与二次开发

1. **新增 / 修改角色**：编辑 `souls/*.md`（保留 frontmatter 格式），重新构建镜像（或把文件挂载进 `/opt/dsh-initial/souls` 后重置 `dsh-data` 卷）。
2. **更换默认 persona**：修改 `entrypoint.sh` 中 `persona: enterprise-boss` 与 `deploy.sh`/README 中的默认角色说明。
3. **固定上游版本**：`docker build --build-arg DSH_REF=<tag-or-sha>`。不指定时默认拉上游 `master` 分支（上游默认分支为 `master`，非 `main`）。
4. **调整桌面/工具**：编辑 `Dockerfile` 的 `apt-get install` 列表。
5. **切换基础镜像源**：默认使用官方/全球源（适配 GitHub Actions 境外构建）。国内加速请传构建参数：`--build-arg DEBIAN_MIRROR=https://mirrors.tuna.tsinghua.edu.cn --build-arg NODE_DIST=https://mirrors.tuna.tsinghua.edu.cn/nodejs-release --build-arg NPM_REGISTRY=https://registry.npmmirror.com`（`deploy.sh` 的本地回退构建已默认带上这些国内镜像）。

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
- **暴露面**：SSH(10022)/xRDP(13389)/Web(13000) 均对宿主机开放，公网部署务必加防火墙或反向代理 + 鉴权。
- **GHCR 可见性**：仓库为公开时镜像也公开，任何人可 `docker pull`；若含敏感角色设定，建议将仓库与镜像设为私有（私有镜像需 `docker login ghcr.io`）。

---

## 常见问题（FAQ）

**Q1：Web UI 打不开 / 一直转圈？**
A：先看 `docker logs -f dsh-debian13`，确认出现「启动 DeepSeek Harness on port 3000」且无报错。多数情况是端口被占用，确认 `-p 13000:3000` 映射正确、宿主机 13000 未被占用。

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

---

## 许可证与上游

- 上游项目：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)（请遵循其许可证）。
- 本仓库的 Dockerfile、角色设定、部署脚本按 **MIT** 许可证开源，可自由修改分发；但「八位专家」角色设定为特定业务场景定制内容，二次分发时请注明来源。
- 相关链接：[GitHub 仓库](https://github.com/yuanshandalishuishou/deepseek-harness-zulin) · [GHCR 镜像](https://ghcr.io/yuanshandalishuishou/deepseek-harness-zulin)
