# =============================================================================
# DeepSeek Harness 镜像（deepseek-harness-zulin）
# -----------------------------------------------------------------------------
# 基础镜像 : debian:trixie-slim
# 运行时   : Node.js v24.1.0 + pnpm（corepack 启用）
# 桌面     : Xfce4 + xrdp（远程桌面）+ OpenSSH（远程 Shell）
# 端口     : 22(SSH) / 3080(Harness Web，官方默认) / 3389(xRDP)
#
# 设计要点：
#   1) 镜像内【不包含任何 API Key】。所有敏感配置在容器「首次启动」时，
#      由 entrypoint.sh 根据环境变量生成 /root/.dsh/settings.yaml。
#   2) 上游 deepseek-harness 的 `startup.ts` 默认拒绝 `--host 0.0.0.0`，
#      本镜像在构建阶段用 scripts/patch-web-bind.sh 放开该限制，使 Web 可对外暴露。
#   3) 上游 feat(gui) 之后前端构建链路有断点，已在下方 RUN 中用三段式补丁序列补齐。
# =============================================================================
FROM debian:trixie-slim

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
# 安装 Node.js v24.1.0（默认官方源 nodejs.org，x86_64）
# 再用 corepack 启用并准备好 pnpm（deepseek-harness 使用 pnpm 作为包管理器）
# -----------------------------------------------------------------------------
RUN curl -fsSL ${NODE_DIST}/v24.1.0/node-v24.1.0-linux-x64.tar.gz -o node.tar.gz && \
    tar -xzf node.tar.gz -C /usr/local --strip-components=1 && \
    rm node.tar.gz && \
    npm config set registry ${NPM_REGISTRY} && \
    npm install -g corepack && corepack enable && corepack prepare pnpm@latest --activate

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

# -----------------------------------------------------------------------------
# 复制仓库内的角色文件、启动脚本、Web 绑定补丁脚本
# -----------------------------------------------------------------------------
# 八位专家角色（souls/）先放进 /opt/dsh-initial，待首次启动由 entrypoint 复制到数据卷
COPY souls/ /opt/dsh-initial/souls/
# Web 绑定补丁脚本（构建阶段已在上一步执行过；再次 COPY 仅为保持镜像内可读、便于调试）
COPY patch-web-bind.sh /opt/dsh-initial/patch-web-bind.sh
# 容器入口
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Web 监听端口改为官方默认 3080；22/3389 保持不变
EXPOSE 22 3080 3389

# 健康检查：轮询容器内 Web 端口（与 WEB_PORT 默认 3080 一致）
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://127.0.0.1:3080 || exit 1

ENTRYPOINT ["/entrypoint.sh"]
