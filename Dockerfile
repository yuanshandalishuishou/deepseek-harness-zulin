# =============================================================================
# DeepSeek Harness 镜像
# 基础镜像: debian:trixie-slim | Node.js v24.1.0 | 桌面: xfce4 + xrdp
# 端口: 22(SSH) / 3000(Harness Web) / 3389(xRDP)
# 说明: 镜像内不包含任何 API Key，所有配置在容器首次启动时
#       由 entrypoint.sh 根据环境变量生成 /root/.dsh/settings.yaml
# =============================================================================
FROM debian:trixie-slim

# deepseek-harness 上游仓库（可用 --build-arg 固定版本）
ARG DSH_REPO=https://github.com/deepseek-ai/deepseek-harness.git
# 注意：上游默认分支为 master（非 main），请勿改错，否则 git checkout 会失败
ARG DSH_REF=master

# 镜像源：默认全部使用官方/全球源，保证在 GitHub Actions（境外 runner）上稳定构建。
# 国内本地构建可自行加速，例如：
#   --build-arg DEBIAN_MIRROR=https://mirrors.tuna.tsinghua.edu.cn
#   --build-arg NODE_DIST=https://mirrors.tuna.tsinghua.edu.cn/nodejs-release
#   --build-arg NPM_REGISTRY=https://registry.npmmirror.com
ARG DEBIAN_MIRROR=
ARG NODE_DIST=https://nodejs.org/dist
ARG NPM_REGISTRY=https://registry.npmjs.org

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=zh_CN.UTF-8 \
    LANGUAGE=zh_CN:zh \
    LC_ALL=zh_CN.UTF-8 \
    DSH_HOME=/root/.dsh

# 仅在指定 DEBIAN_MIRROR 时替换 apt 源（默认沿用官方 deb.debian.org）
RUN if [ -n "$DEBIAN_MIRROR" ]; then \
      sed -i "s|http://deb.debian.org|${DEBIAN_MIRROR}|g; s|http://security.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list.d/debian.sources; \
    fi

# 安装基础软件包
RUN apt-get update && apt-get install -y --no-install-recommends \
    locales fonts-wqy-zenhei fonts-wqy-microhei tzdata \
    xfce4 xfce4-goodies xrdp xorgxrdp \
    openssh-server \
    git curl wget sudo ca-certificates \
    build-essential python3 python3-pip \
    nano vim htop net-tools xz-utils \
    && echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen zh_CN.UTF-8 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 安装 Node.js v24.1.0（默认官方源 nodejs.org，x86_64）
RUN curl -fsSL ${NODE_DIST}/v24.1.0/node-v24.1.0-linux-x64.tar.gz -o node.tar.gz && \
    tar -xzf node.tar.gz -C /usr/local --strip-components=1 && \
    rm node.tar.gz && \
    npm config set registry ${NPM_REGISTRY} && \
    npm install -g corepack && corepack enable && corepack prepare pnpm@latest --activate

# 配置 xrdp
RUN echo "startxfce4" > /root/.xsession

# SSH 配置
RUN sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    mkdir -p /root/.ssh && chmod 700 /root/.ssh

# 克隆官方项目并构建
WORKDIR /opt
# 构建说明（2026-08 修补）：
#   上游 feat(gui) 后，`pnpm run build`（build:lib）只产出 host 面 lib，
#   不含 client 面（packages/client/web/lib）与前端 dist，导致
#   `dsh web` 启动报 "frontend dist not built"。
#   补丁序列（已在 x86_64 实测通过）：
#     1) pnpm run build:lib              —— host 面 lib（含 typert tsdown 插件）
#     2) pnpm exec tsdown --env.DSH_BUILD_FACE client —— 跳过 tsc 类型检查，直接转译产出 client 面 lib/
#     3) pnpm --filter @deepseek-ai/dsh-web-frontend run build —— vite 产出 apps/web/dist
RUN git clone "$DSH_REPO" deepseek-harness && \
    cd deepseek-harness && \
    git checkout "$DSH_REF" || git checkout master && \
    pnpm config set registry ${NPM_REGISTRY} && \
    pnpm install && pnpm run build:lib && \
    pnpm exec tsdown --env.DSH_BUILD_FACE client && \
    pnpm --filter @deepseek-ai/dsh-web-frontend run build && \
    ls apps/web/dist/index.html && \
    ln -s /opt/deepseek-harness /opt/dsh

# 复制角色文件与启动脚本
RUN mkdir -p /opt/dsh-initial
COPY souls/ /opt/dsh-initial/souls/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22 3000 3389
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://127.0.0.1:3000 || exit 1
ENTRYPOINT ["/entrypoint.sh"]
