# =============================================================================
# DeepSeek Harness 镜像（deepseek-harness-zulin）
# -----------------------------------------------------------------------------
# 基础镜像 : node:24.18.0-trixie（官方镜像，已自带 Node.js v24.18.0）
# 运行时   : Node.js v24.18.0 + pnpm（corepack 启用）
# 桌面     : Xfce4 + xrdp（远程桌面）+ OpenSSH（远程 Shell）
# 端口     : 22(SSH) / 3080(Harness Web，官方默认) / 3389(xRDP)
#            18789(OpenClaw 网关) / 3000(Hermes Web UI) / 8080(Hermes 管理面板)
#            16688(管理端口) / 3456(Token-Free Gateway 免 Token 网关，OpenAI 兼容 /v1)
#
# 设计要点：
#   1) 镜像内【不包含任何 API Key】。所有敏感配置在容器「首次启动」时，
#      由 entrypoint.sh 根据环境变量生成 /root/.dsh/settings.yaml。
#   2) 上游 deepseek-harness 的 `startup.ts` 默认拒绝 `--host 0.0.0.0`，
#      本镜像在构建阶段用 scripts/patch-web-bind.sh 放开该限制，使 Web 可对外暴露。
#   3) 上游 feat(gui) 之后前端构建链路有断点，已在下方 RUN 中用三段式补丁序列补齐。
# =============================================================================
FROM node:24.18.0-trixie

# -----------------------------------------------------------------------------
# 构建参数（可在 `docker build --build-arg` 时覆盖）
# -----------------------------------------------------------------------------
# deepseek-harness 上游仓库地址
ARG DSH_REPO=https://github.com/deepseek-ai/deepseek-harness.git
# 上游默认分支为 master（不是 main）。请勿改错，否则 git checkout 会失败。
ARG DSH_REF=master

# 镜像源配置：默认全部使用官方/全球源，保证在 GitHub Actions（境外 runner）上稳定构建。
# 国内本地构建可自行加速，例如：
#   --build-arg DEBIAN_MIRROR=https://mirrors.tuna.tsinghua.edu.cn
#   --build-arg NODE_DIST=https://mirrors.tuna.tsinghua.edu.cn/nodejs-release
#   --build-arg NPM_REGISTRY=https://registry.npmmirror.com
ARG DEBIAN_MIRROR=
ARG NODE_DIST=https://nodejs.org/dist
ARG NPM_REGISTRY=https://registry.npmjs.org

# Token-Free Gateway 版本：默认 latest（每次构建拉官方最新 linux-x64 预编译二进制）。
# 如需锁定版本可传 --build-arg TFG_VERSION=v0.5.1
ARG TFG_VERSION=latest
# Token-Free Gateway 官方仓库（唯一可信来源，禁止替换为任何镜像/分支/复刻，避免供应链投毒）
ARG TFG_REPO=https://github.com/andeya/token-free-gateway.git

# -----------------------------------------------------------------------------
# 容器环境变量（运行时可见）
# -----------------------------------------------------------------------------
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=zh_CN.UTF-8 \
    LANGUAGE=zh_CN:zh \
    LC_ALL=zh_CN.UTF-8 \
    DSH_HOME=/root/.dsh \
    # Web 服务监听端口：官方默认即 3080。可用 -e WEB_PORT=xxxx 覆盖。
    WEB_PORT=3080

# 仅在指定 DEBIAN_MIRROR 时替换 apt 源（默认沿用官方 deb.debian.org）
RUN if [ -n "$DEBIAN_MIRROR" ]; then \
      sed -i "s|http://deb.debian.org|${DEBIAN_MIRROR}|g; s|http://security.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list.d/debian.sources; \
    fi

# -----------------------------------------------------------------------------
# 安装系统软件：中文locale、桌面(xfce4)+xrdp、OpenSSH、构建工具链、常用调试工具
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    locales fonts-wqy-zenhei fonts-wqy-microhei tzdata \
    xfce4 xfce4-goodies xrdp xorgxrdp \
    openssh-server \
    git curl wget sudo ca-certificates \
    build-essential python3 python3-pip \
    nano vim htop net-tools xz-utils \
    && echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen zh_CN.UTF-8 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 启用 corepack 并准备好 pnpm（deepseek-harness 使用 pnpm 作为包管理器）
# 基础镜像 node:24.18.0-trixie 已自带 Node.js v24.18.0，无需手动下载安装
# -----------------------------------------------------------------------------
RUN npm config set registry ${NPM_REGISTRY} && \
    npm install -g corepack && corepack enable && corepack prepare pnpm@latest --activate

# -----------------------------------------------------------------------------
# 安装 OpenClaw（多角色 AI 助手网关；默认端口 18789）
# 基础镜像已自带 Node.js v24，直接全局安装即可
# -----------------------------------------------------------------------------
RUN npm install -g openclaw@latest

# -----------------------------------------------------------------------------
# 安装 hermes-web-ui（Hermes 社区版 Web UI，浏览器对话界面；本镜像在 entrypoint
# 中以 --port 3000 启动，作为 Hermes 的「Web UI」映射到容器 3000）
# -----------------------------------------------------------------------------
RUN npm install -g hermes-web-ui@latest

# -----------------------------------------------------------------------------
# 配置桌面与 SSH
# -----------------------------------------------------------------------------
# xRDP 登录后自动启动 Xfce4 会话
RUN echo "startxfce4" > /root/.xsession

# 允许 root 通过密码登录 SSH / xRDP（凭据由 entrypoint.sh 在运行时按环境变量设置）
RUN sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    mkdir -p /root/.ssh && chmod 700 /root/.ssh

# -----------------------------------------------------------------------------
# 先把 Web 绑定补丁脚本放进镜像（构建阶段 clone 后需要执行它；
# 顺序必须早于下方的 clone + build RUN）
# -----------------------------------------------------------------------------
COPY patch-web-bind.sh /tmp/patch-web-bind.sh
RUN chmod +x /tmp/patch-web-bind.sh

# -----------------------------------------------------------------------------
# 克隆 deepseek-harness 并构建
# 构建说明（2026-08 修补，已在 x86_64 实测通过）：
#   上游 feat(gui) 之后，`pnpm run build`（build:lib）只产出 host 面 lib，
#   不含 client 面（packages/client/web/lib）与前端 dist，导致
#   `dsh web` 启动报 "frontend dist not built"。
#   补丁序列：
#     1) pnpm run build:lib
#          —— 产出 host 面 lib（含 typert 的 tsdown 插件，供后续 client 构建依赖）
#     2) pnpm exec tsdown --env.DSH_BUILD_FACE client
#          —— 跳过上游 tsc 类型检查（当前 client 面存在类型不一致报错），
#             直接用 rolldown 转译产出 client 面 lib/（packages/client/web/lib 等）
#     3) pnpm --filter @deepseek-ai/dsh-web-frontend run build
#          —— vite 构建前端，产出 apps/web/dist（dsh web 启动时所找的 dist）
# -----------------------------------------------------------------------------
WORKDIR /opt
RUN git clone "$DSH_REPO" deepseek-harness && \
    cd deepseek-harness && \
    # 切到目标分支/提交；上游默认 master，若 checkout 失败则兜底 master
    git checkout "$DSH_REF" || git checkout master && \
    # 放开 --host 0.0.0.0 限制（详见 scripts/patch-web-bind.sh 注释）
    bash /tmp/patch-web-bind.sh && \
    pnpm config set registry ${NPM_REGISTRY} && \
    pnpm install && \
    pnpm run build:lib && \
    pnpm exec tsdown --env.DSH_BUILD_FACE client && \
    pnpm --filter @deepseek-ai/dsh-web-frontend run build && \
    # 断言前端 dist 已产出，否则提前失败，避免构建出「跑不起 web」的镜像
    ls apps/web/dist/index.html && \
    # 建立兼容软链：/opt/dsh 指向 /opt/deepseek-harness
    ln -s /opt/deepseek-harness /opt/dsh

# crypto polyfill：兜底 globalThis.crypto.randomUUID（根治设置页
# "crypto.randomUUID is not a function" 报错）。由 entrypoint 通过
# NODE_OPTIONS=--require 注入到 Harness Web 进程。
COPY dsh-crypto-polyfill.cjs /opt/deepseek-harness/dsh-crypto-polyfill.cjs

# -----------------------------------------------------------------------------
# 安装 Hermes Agent（NousResearch；Web 仪表盘默认端口 9119，本镜像改用 8080）
# 官方安装脚本会自动安装 Python 3.11 / uv / Node 等依赖。
# 以非交互方式运行；CI=1 避免交互式向导卡住构建。
# -----------------------------------------------------------------------------
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o /tmp/hermes-install.sh \
    && CI=1 bash /tmp/hermes-install.sh < /dev/null \
    && rm -f /tmp/hermes-install.sh

# Hermes 的 Web 仪表盘依赖 web / pty 扩展（FastAPI + Uvicorn + ptyprocess）
ENV PATH="/root/.local/bin:/root/.hermes/bin:/root/.cargo/bin:$PATH"
RUN if [ -d /root/.hermes/hermes-agent ]; then \
      cd /root/.hermes/hermes-agent && uv pip install -e ".[web,pty]"; \
    else \
      echo "[WARN] hermes-agent 源码目录未找到，跳过 web/pty 扩展安装（仪表盘将不可用）"; \
    fi

# -----------------------------------------------------------------------------
# 复制仓库内的角色文件、启动脚本、Web 绑定补丁脚本
# -----------------------------------------------------------------------------
# 八位专家角色（souls/）先放进 /opt/dsh-initial，待首次启动由 entrypoint 复制到数据卷
COPY souls/ /opt/dsh-initial/souls/
# Web 绑定补丁脚本（构建阶段已在上一步执行过；再次 COPY 仅为保持镜像内可读、便于调试）
COPY patch-web-bind.sh /opt/dsh-initial/patch-web-bind.sh
# OpenClaw 工作区模板（八位专家多角色，与 DeepSeek Harness souls 一致）
COPY openclaw/ /opt/openclaw-initial/openclaw/
# 复用 DeepSeek Harness 的八位专家人设，复制到 OpenClaw 工作区 souls/
# （构建期复制，保证两套系统的多角色设定完全一致、单一来源）
RUN mkdir -p /opt/openclaw-initial/openclaw/workspace/souls \
    && cp -r /opt/dsh-initial/souls/. /opt/openclaw-initial/openclaw/workspace/souls/ 2>/dev/null || true

# Hermes Agent 配置模板（默认 DeepSeek，密钥由运行时环境变量注入）
COPY hermes/ /opt/hermes-initial/

# 管理端口服务（16688）：在线管理界面，修改 OpenClaw/Hermes 令牌、模型、API Key 并热重启
COPY mgmt/ /opt/mgmt/
# 为系统 python3 安装 PyYAML（管理端口回退路径需要；离线则跳过，不影响主流程）
RUN pip3 install --no-cache-dir -i https://pypi.tuna.tsinghua.edu.cn/simple pyyaml 2>/dev/null || true

# -----------------------------------------------------------------------------
# 安装 Token-Free Gateway（免 Token 网关，容器内端口 3456，提供 OpenAI 兼容 /v1）
# 下载方式（关键，满足「构建期下载而非本地下载后 COPY」的要求）：
#   * 下方 RUN 在「镜像构建阶段」直接用 curl 从官方仓库拉取预编译二进制并解包进镜像
#     （构建期下载 → 镜像内自带二进制），【绝不采用「宿主机本地下载后再 COPY 进镜像」】。
#   * 理由：最终镜像由 GitHub Actions 的境外 runner 完成官方下载后推送到 GHCR，国内用户只需
#     `docker pull` 即可获得含二进制的成品镜像，从而规避本机/内网直连 GitHub Releases 不稳定问题。
# 安全约定（务必遵守，防供应链投毒）：
#   * 仅从官方仓库 github.com/andeya/token-free-gateway 的 GitHub Releases 拉取预编译二进制，
#     绝不改用任何镜像站 / fork / 第三方转存，避免被植入恶意代码。
#   * 下载后必须用官方同版本 checksums-sha256.txt 做 sha256 校验，校验失败立即中止构建。
#   * TFG_VERSION=latest 时每次构建自动取官方最新 linux-x64 版本；如需锁定可传 --build-arg。
# 运行时开关：容器启动时用 -e ENABLE_TOKEN_FREE_GATEWAY=1 启用（默认开启；置 0/false/空 关闭），见 entrypoint.sh。
# 运行时依赖：Chromium（网关经 CDP 9222 驱动浏览器复用登录态）+ Bun（tfg-capture 捕获脚本）。
# -----------------------------------------------------------------------------
RUN set -e; \
    if [ "$TFG_VERSION" = "latest" ]; then \
      TFG_BASE="https://github.com/andeya/token-free-gateway/releases/latest/download"; \
    else \
      TFG_BASE="https://github.com/andeya/token-free-gateway/releases/download/${TFG_VERSION}"; \
    fi; \
    cd /tmp; \
    echo "[TFG] 下载官方校验和与预编译二进制 (base=$TFG_BASE)"; \
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors "$TFG_BASE/checksums-sha256.txt" -o tfg_checksums.txt; \
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors "$TFG_BASE/token-free-gateway-linux-x64.tar.gz" -o tfg_linux_x64.tar.gz; \
    echo "[TFG] 校验 sha256 ..."; \
    EXP=$(grep ' token-free-gateway-linux-x64.tar.gz$' tfg_checksums.txt | awk '{print $1}'); \
    ACT=$(sha256sum tfg_linux_x64.tar.gz | awk '{print $1}'); \
    if [ -z "$EXP" ] || [ "$EXP" != "$ACT" ]; then \
      echo "[TFG][FATAL] 校验和不匹配！期望=$EXP 实际=$ACT —— 疑似下载被篡改或源异常，中止构建"; \
      exit 1; \
    fi; \
    echo "[TFG] 校验通过 ($ACT)"; \
    mkdir -p /tmp/tfgextract && tar xzf tfg_linux_x64.tar.gz -C /tmp/tfgextract; \
    TFG_BIN=$(find /tmp/tfgextract -type f \( -name 'token-free-gateway' -o -name 'token-free-gateway-linux-x64' -o -name 'token-free-gateway-linux-x86_64' \) | head -1); \
    if [ -z "$TFG_BIN" ]; then \
      TFG_BIN=$(find /tmp/tfgextract -type f -perm -u+x | head -1); \
    fi; \
    if [ -z "$TFG_BIN" ]; then echo "[TFG][FATAL] 压缩包内未找到 token-free-gateway 二进制"; exit 1; fi; \
    echo "[TFG] 定位到二进制: $TFG_BIN"; \
    mv "$TFG_BIN" /usr/local/bin/token-free-gateway; \
    chmod +x /usr/local/bin/token-free-gateway; \
    /usr/local/bin/token-free-gateway --version || true; \
    rm -rf /tmp/tfgextract /tmp/tfg_linux_x64.tar.gz /tmp/tfg_checksums.txt; \
    echo "[TFG] 官方预编译二进制已安装到 /usr/local/bin/token-free-gateway"

# Bun（网关为 Bun 生态；tfg-capture 捕获脚本与兜底运行需要）
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:$PATH"

# Chromium（网关经 CDP 9222 驱动「有头」浏览器，复用各 AI 网站登录态转发请求）
RUN apt-get update && apt-get install -y --no-install-recommends chromium socat \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && ln -sf "$(command -v chromium)" /usr/bin/chromium 2>/dev/null || true

# 克隆官方源码（仅用于 tfg-capture 捕获脚本与 `bun index.ts` 兜底运行；二进制仍是上面的官方预编译件）
# 同样只指向官方仓库，不使用任何非官方副本。
RUN rm -rf /opt/token-free-gateway \
    && git clone --depth 1 "$TFG_REPO" /opt/token-free-gateway \
    && cd /opt/token-free-gateway \
    && (bun install || echo "[TFG][WARN] 源码依赖安装失败，tfg-capture 可能不可用（网关服务本身不受影响）")

# 用本项目自带的定制脚本覆盖官方同名文件
COPY tfg-capture.ts /opt/token-free-gateway/src/cli/tfg-capture.ts
COPY tfg-chrome-xrdp.sh /usr/local/bin/tfg-chrome-xrdp.sh
RUN chmod +x /usr/local/bin/tfg-chrome-xrdp.sh
COPY tfg-chrome.desktop /etc/xdg/autostart/tfg-chrome.desktop

# 容器入口
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Web 监听端口改为官方默认 3080；22/3389 保持不变；新增 OpenClaw(18789) / Hermes Web UI(3000) / Hermes 管理面板(8080) / 管理端口(16688) / Token-Free Gateway(3456)
EXPOSE 22 3080 3389 18789 3000 8080 16688 3456

# 健康检查：轮询容器内 Web 端口（与 WEB_PORT 默认 3080 一致）
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://127.0.0.1:3080 || exit 1

ENTRYPOINT ["/entrypoint.sh"]
