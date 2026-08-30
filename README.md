# DeepSeek Harness 租赁版（deepseek-harness-zulin）

> 把 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 与「央企融资租赁」场景定制的**八位专家**多智能体角色、三大网关（DeepSeek Harness Web / OpenClaw / Hermes）、在线**管理端口 16688**、以及**免 Token 的 Token-Free Gateway** 打包为一个开箱即用的 Debian 13 容器；通过 GitHub Actions「推送即构建」发布到 GHCR。镜像**零密钥**，所有敏感配置在首次启动由环境变量注入。

---

## 1. 功能特性

| 模块 | 能力 |
|------|------|
| **基础构建** | 基于官方 `node:24-trixie`；GitHub Actions 推送即构建并发布 GHCR（`:latest` / 版本标签 / `:sha-xxx`）；国内本地回退构建可用 `build-arg` 加速 |
| **零密钥镜像** | 镜像内不含任何 API Key / 令牌 / 密码；`ROOT_PASSWORD` 等敏感配置首次启动由 `entrypoint.sh` 按 `-e` 注入 |
| **模型切换** | `MODEL_CHOICE` 1–5：DeepSeek 官方 / 硅基流动 / 阿里百炼 / 自定义 DeepSeek / 自定义 OpenAI 兼容 |
| **远程桌面** | Xfce4 + xRDP(3389) + OpenSSH(22)，含 `crypto.randomUUID` polyfill 修复 |
| **三大网关** | DeepSeek Harness Web(3080) / OpenClaw(18789) 八专家多角色 / Hermes Web UI(3000)+管理面板(8080) |
| **管理端口 16688** | 首启随机 `admin-xxxx` 凭据 + 强制改密；在线改 OpenClaw/Hermes 令牌/模型/Key 并热重启；**聚合状态页 `/status`**（免登录只读）；**操作审计日志** |
| **Token-Free Gateway** | 内置官方 TFG，OpenAI 兼容 `/v1`，免 API Key 调用 13+ 家模型（Claude / ChatGPT / DeepSeek / Qwen / Gemini / Kimi / Grok / Doubao / GLM / Perplexity / 智谱 / 小米 MiMo 等）；**默认开启**，`-e` 开关控制；**socat 自动转发根治 13456 不通** |
| **持久化** | 数据卷 `dsh-data` / `dsh-tfg-auth` / `dsh-chrome-tfg`，重启免重新授权 |

---

## 2. 架构概览

```
                GitHub Actions (境外 runner)
   push main ──► docker build ──► ghcr.io/.../deepseek-harness-zulin:latest
                                          │  (镜像已含官方 TFG 二进制 + socat + bun + chromium)
                                          ▼
   用户/NAS:  docker pull  ──►  docker run  ──►  容器内服务编排 (entrypoint.sh)
   ┌──────────────────────────────────────────────────────────────────────┐
   │  SSH(22)  xRDP(3389)  Harness Web(3080)  OpenClaw(18789)  Hermes(3000/8080) │
   │  TFG 二进制 ── 监听 127.0.0.1:34560 ──► socat 0.0.0.0:3456 ──► 宿主 13456  │
   │  管理端口(16688): mgmt.py（随机凭据/改配置/热重启/状态页/审计）             │
   └──────────────────────────────────────────────────────────────────────┘
   持久化卷: dsh-data(/root/.dsh)  dsh-tfg-auth(/root/.token-free-gateway)  dsh-chrome-tfg(/root/.chrome-tfg-debug)
```

**关键设计**
- **镜像零密钥**：所有 Key / 令牌 / 密码仅在容器首次启动注入。
- **TFG 来源唯一可信**：仅构建期从官方 `github.com/andeya/token-free-gateway` Releases 下载并 sha256 校验（防供应链投毒），绝不采用「宿主机下载后 COPY」或任何镜像站 / fork / 第三方转存。
- **13456 根治**：TFG 监听内部端口 `34560`，`socat` 自动转发 `0.0.0.0:3456 → 127.0.0.1:34560`，无论官方二进制默认绑 127.0.0.1 还是 0.0.0.0，宿主 `13456` 都可达。

---

## 3. 快速开始

### 3.1 一键部署（推荐）

```bash
# 默认从 GHCR 拉取最新镜像并启动（TFG 默认开启）
bash deploy.sh
```

`deploy.sh` 端口映射如下（GHCR 优先，拉取失败自动回退本地构建）：

| 容器内 | 宿主映射 | 服务 |
|--------|----------|------|
| `3080`  | `13000`  | Harness Web UI |
| `22`    | `10022`  | SSH（root / 自定义） |
| `3389`  | `13389`  | xRDP 远程桌面 |
| `18789` | `18789`  | OpenClaw 网关（八专家） |
| `3000`  | `18000`  | Hermes Web UI |
| `8080`  | `18080`  | Hermes 管理面板 |
| `3456`  | `13456`  | Token-Free Gateway（OpenAI 兼容 /v1） |
| `16688` | `16688`  | 管理端口 |

### 3.2 手动 docker run

```bash
docker run -d --name dsh-zulin \
  -p 10022:22 -p 13000:3080 -p 13389:3389 \
  -p 18789:18789 -p 18000:3000 -p 18080:8080 \
  -p 16688:16688 -p 13456:3456 \
  -e ROOT_PASSWORD=你的强密码 \
  -e ENABLE_TOKEN_FREE_GATEWAY=1 \
  -v dsh-data:/root/.dsh \
  -v dsh-tfg-auth:/root/.token-free-gateway \
  -v dsh-chrome-tfg:/root/.chrome-tfg-debug \
  ghcr.io/yuanshandalishuishou/deepseek-harness-zulin:latest
```

> 默认 SSH / xRDP 账户为 `root` / `deepseek`；生产环境务必用 `-e ROOT_PASSWORD=强密码` 覆盖（覆盖动作记入审计日志）。

---

## 4. 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DEEPSEEK_API_KEY` | 空 | DeepSeek 官方 API Key |
| `OPENAI_API_KEY` | 空 | OpenAI 兼容 Key（硅基流动 / 百炼 / 自建网关） |
| `MODEL_CHOICE` | `1` | 1=DeepSeek官方 2=硅基流动 3=阿里百炼 4=DeepSeek+自定义 5=自定义OpenAI |
| `CUSTOM_MODEL_NAME` | 空 | `MODEL_CHOICE=4` 时的 DeepSeek 模型名 |
| `CUSTOM_OPENAI_BASE_URL` | 内置 | `MODEL_CHOICE=2/3/5` 的 base-url |
| `CUSTOM_OPENAI_MODEL` | 空 | `MODEL_CHOICE=5` 的模型名 |
| `ROOT_USER` | `root` | SSH / xRDP 登录用户名 |
| `ROOT_PASSWORD` | `deepseek` | SSH / xRDP 密码（覆盖动作记入审计） |
| `WEB_PORT` | `3080` | dsh web 容器内监听端口 |
| `WEB_HOST` | `0.0.0.0` | dsh web 绑定地址 |
| `OPENCLAW_PORT` | `18789` | OpenClaw 网关端口 |
| `HERMES_PORT` | `8080` | Hermes 管理面板端口 |
| `HERMES_WEB_PORT` | `3000` | Hermes Web UI 端口 |
| `ENABLE_TOKEN_FREE_GATEWAY` | `1` | **默认开启**；`1/true/yes/on/enabled`（大小写不敏感）启用，`0/false/空` 关闭 |
| `TFG_PORT` | `3456` | TFG 对外暴露端口（宿主映射 `13456:3456`） |
| `TFG_INNER_PORT` | `34560` | TFG 实际监听内部端口（socat 转发目标，一般无需改） |
| `TFG_API_KEY` | 空 | 客户端调用网关的 Bearer Token（空=不鉴权，仅建议内网） |
| `TFG_CDP_URL` | `http://127.0.0.1:9222` | Chromium CDP 调试端点 |
| `TFG_LOGIN_MODE` | `xrdp` | `xrdp`（推荐，可见浏览器登录）/ `headless`（无头 Chromium） |

---

## 5. Token-Free Gateway（免 Token 网关）

### 5.1 它是什么
一个 OpenAI 兼容网关（`/v1/chat/completions`、`/v1/models`、`/health`），通过浏览器已登录的网页会话**免 API Key** 调用多家大模型。默认开启，对外端点为 `http://<宿主IP>:13456/v1`。

### 5.2 登录授权（xrdp 模式，推荐）
1. 用 xRDP 远程桌面连接 `宿主IP:13389`（账户 `root` / `deepseek` 或你设的密码）。
2. 桌面自动拉起一个**可见** Chromium（CDP 9222）。
3. 在浏览器中登录各 AI 网站（ChatGPT / Claude / DeepSeek …）。
4. 登录后运行 `token-free-gateway webauth` 捕获会话（或直接复用已登录会话）。
5. 此后网关即可转发请求；xRDP 断开后会话默认保留，网关持续工作。

> 说明：**可见浏览器**可规避「无头陷阱」——headless 下 `webauth` 会卡在不可见窗口无法输入账号。

### 5.3 客户端调用示例
```bash
curl http://<宿主IP>:13456/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"chatgpt","messages":[{"role":"user","content":"你好"}]}'
```
（如设置了 `TFG_API_KEY`，需加 `-H "Authorization: Bearer <KEY>"`。）

### 5.4 健康检查
- `/health` 与 `/healthz` 返回 JSON 状态（免鉴权），供状态页与管理端口探测。
- `/v1/models` 列出当前已授权的模型。

### 5.5 构建期下载（安全要点）
镜像构建时，Dockerfile 用 `RUN` 在**构建阶段**直接从官方 Releases 下载预编译二进制并解包进镜像：
- 仅允许 `github.com/andeya/token-free-gateway` 官方源，禁用任何镜像站 / fork / 第三方转存；
- 下载后用官方同版本 `checksums-sha256.txt` 做 sha256 校验，**不一致立即 `exit 1`** 中止构建；
- 支持 `--build-arg TFG_VERSION=latest|vX.Y.Z`（默认 `latest`）；
- 下载带 `--retry 5` 重试。
> 最终成品镜像由 GHCR 境外 runner 拉取官方二进制后分发，国内只需 `docker pull`，规避本机直连 GitHub 不稳。

---

## 6. 管理端口 16688

- **首启随机凭据**：首次启动在 `/root/.dsh/MGMT_CREDENTIALS.txt` 生成 `admin-xxxx` 用户与随机密码，并强制首次登录后修改。
- **在线配置**：登录后可改 OpenClaw / Hermes 令牌、模型、API Key 并热重启，无需重建容器。
- **聚合状态页 `/status`**：免登录只读 HTML 概览，一览 8 项服务（Harness Web / OpenClaw / Hermes Web / Hermes 面板 / TFG / SSH / xRDP / Chromium CDP）的端口可达性。
- **JSON 接口 `/api/status`**：登录后返回结构化状态。
- **审计日志**：所有特权操作（登录、改密、改配置、TFG 应用、webauth 捕获、生成令牌、应用角色、重启、密码覆盖等）写入 `/var/log/dsh-audit.log`，含时间戳 / 用户 / 动作 / 详情。

---

## 7. 从源码构建

```bash
# 默认（TFG=latest，官方下载）
docker build -t dsh-zulin .

# 锁定 TFG 版本
docker build --build-arg TFG_VERSION=v0.5.1 -t dsh-zulin .

# 国内本地构建加速（TFG 仍强制走官方 GitHub）
docker build \
  --build-arg DEBIAN_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/debian \
  --build-arg NODE_DIST=https://npmmirror.com/mirrors/node \
  --build-arg NPM_REGISTRY=https://registry.npmmirror.com \
  -t dsh-zulin .
```

> GHCR 自动构建在每次推送 `main`（或打 `v*` 标签 / 手动）时触发，无需额外 Secret（用内置 `GITHUB_TOKEN`）。

---

## 8. 验证清单

1. **构建**：Actions 日志含 `[TFG] 校验通过 (...)` 且 `token-free-gateway --version` 正常；镜像不含任何预下载的 TFG 二进制 COPY。
2. **TFG 默认开**：不加 `-e ENABLE_TOKEN_FREE_GATEWAY` 时，`curl http://<宿主IP>:13456/health` 返回 JSON。
3. **开关归一化**：`true|yes|on|enabled` 均启用；`0|false|空` 关闭（13456 不通）。
4. **13456 根治**：容器内 `ss -tlnp` 确认 `socat` 监听 `0.0.0.0:3456`、`token-free-gateway` 监听 `127.0.0.1:34560`；宿主 13456 可达。
5. **状态页**：`http://<宿主IP>:16688/status` 免登录展示 8 项状态；登录后 `/api/status` 返回 JSON。
6. **审计**：执行改密 / 改配置 / 重启后 `cat /var/log/dsh-audit.log` 可见对应记录。
7. **密码策略**：未设 `-e ROOT_PASSWORD` 时默认 `deepseek`；设置后写入审计。

---

## 9. 公网部署检查清单（G3）

当容器暴露到公网时，**必须**逐项核对：

1. **防火墙 / 安全组**：管理端口 `16688`、SSH `10022`、xRDP `13389` 不要直接公网开放，仅对可信 IP 开放或走 VPN / 隧道。
2. **TFG 鉴权**：公网暴露 `13456` **必须**设 `TFG_API_KEY`，否则免 Key 网关会被任意调用。
3. **管理端口强密码**：首次登录 16688 后立即修改随机凭据。
4. **SSH/xRDP 密码**：务必 `-e ROOT_PASSWORD=<强密码>` 覆盖默认 `deepseek`（覆盖已计入审计）。
5. **反向代理 + TLS**：Web / 管理类 HTTP 建议前置 Nginx / Caddy 做 TLS 终止与鉴权，避免明文传输凭据。
6. **数据卷备份**：定期备份 `dsh-data` / `dsh-tfg-auth` / `dsh-chrome-tfg`。
7. **镜像更新**：关注 GHCR `:latest` 更新，必要时 `docker pull` + 重建（可选 watchtower）。
8. **审计日志外送**：将 `/var/log/dsh-audit.log` 纳入集中日志。

---

## 10. 故障排查

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| `13456` 不通 | TFG 未启用 / socat 未起 / 内部端口错 | 确认 `ENABLE_TOKEN_FREE_GATEWAY`；`docker logs` 看 socat 与 TFG 日志；容器内 `ss -tlnp` 核查 `3456`/`34560` |
| `16688` 不通 | mgmt.py 缺失 / PyYAML 未装 | 镜像已含 `mgmt/` 与 PyYAML；检查 `/var/log/mgmt.log` |
| TFG 返回 401 | 设了 `TFG_API_KEY` 但客户端未带 Token | 客户端加 `Authorization: Bearer <KEY>`，或留空 `TFG_API_KEY` |
| 登录 AI 网站卡住 | 误用 headless 模式 | 改用 `TFG_LOGIN_MODE=xrdp`，在可见桌面浏览器登录 |
| 拉取 ghcr 报 manifest unknown | 镜像未完成构建 / 悬空标签 | 确认 Actions 构建成功；必要时删除重推包 |

---

## 11. 本期决策与范围

**已确认的决策（Q1–Q6）**
- **Q1** TFG 默认**开启**（置 `0/false/空` 才关）；`deploy.sh` / `entrypoint` / README 三方默认统一为开。
- **Q2** 恒为官方下载，**不加**「本地构建可跳过 TFG 下载」开关；绝不采用「本地下载后 COPY」。
- **Q3** SSH/xRDP 默认密码保留 `deepseek`，仅 `-e` 指定时覆盖（覆盖记入审计）。
- **Q4** 纳入 F6（socat 自动转发）/ E4（聚合状态页）/ E5（审计日志）/ G3（公网清单）。
- **Q5** 暂不启用 ARM64（仅 `linux/amd64`）。
- **Q6** TFG 保持 `latest`（每次取官方最新 linux-x64）。

**本期未实现（后续增强）**：ARM64 镜像、本地跳过 TFG 开关、首启随机强密码、TFG 版本锁定、数据卷备份脚本、管理端口在线编辑 TFG 配置、重新生成 settings.yaml 按钮、`/v1/models` 前端展示、公网 API Key 强制护栏。

---

## 12. 相关文档
- `用户需求.md` — 用户视角需求（WHAT / 决策 / 验收）
- `技术方案.md` — 实现视角方案（HOW / 代码改动 / 公网清单 / 验证）

---

*镜像由 GitHub Actions 自动构建并发布至 GHCR；所有密钥运行时注入，镜像本身不含任何凭据。*
