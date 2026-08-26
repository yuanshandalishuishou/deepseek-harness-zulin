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
ARG DSH_REF=main

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=zh_CN.UTF-8 \
    LANGUAGE=zh_CN:zh \
    LC_ALL=zh_CN.UTF-8 \
    DSH_HOME=/root/.dsh

# 使用 HTTP 清华源
RUN sed -i 's|http://deb.debian.org|http://mirrors.tuna.tsinghua.edu.cn|g; s|http://security.debian.org|http://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/debian.sources

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

# 安装 Node.js v24.1.0（清华源，x86_64）
RUN curl -fsSL https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/v24.1.0/node-v24.1.0-linux-x64.tar.gz -o node.tar.gz && \
    tar -xzf node.tar.gz -C /usr/local --strip-components=1 && \
    rm node.tar.gz && \
    npm config set registry https://registry.npmmirror.com && \
    npm install -g corepack && corepack enable && corepack prepare pnpm@latest --activate

# 配置 xrdp
RUN echo "startxfce4" > /root/.xsession

# SSH 配置
RUN sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    mkdir -p /root/.ssh && chmod 700 /root/.ssh

# 克隆官方项目并构建
WORKDIR /opt
RUN git clone "$DSH_REPO" deepseek-harness && \
    cd deepseek-harness && \
    git checkout "$DSH_REF" && \
    pnpm config set registry https://registry.npmmirror.com && \
    pnpm install && pnpm run build && \
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
