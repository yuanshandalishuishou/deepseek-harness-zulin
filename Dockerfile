# syntax=docker/dockerfile:1
# =========================================================================
# 一体化 AI 服务平台镜像（v2.0）
#
# 首版构建（桩模式，无需真实上游仓库，直接可构建可冒烟）:
#   docker build -t aio-platform:2.0.0 .
#
# 接入真实上游（逐个服务切换，示例为 DSH）:
#   docker build \
#     --build-arg STUB_MODE=false \
#     --build-arg DSH_ARTIFACTS=build-dsh \
#     --build-arg DSH_REPO=https://github.com/<org>/<dsh>.git \
#     --build-arg DSH_REF=v1.2.3 \
#     -t aio-platform:2.0.0 .
# =========================================================================

# ---------- 产物来源选择（stub-* / build-*） ----------
ARG STUB_MODE=true
ARG DSH_ARTIFACTS=stub-dsh
ARG OPENCLAW_ARTIFACTS=stub-openclaw
ARG HERMES_ARTIFACTS=stub-hermes
ARG ADMIN_ARTIFACTS=stub-admin

# ==========================================================================
# 桩阶段：零依赖模拟服务（默认）
# ==========================================================================
FROM scratch AS stub-dsh
COPY stubs/stub_server.py /artifacts/

FROM scratch AS stub-openclaw
COPY stubs/stub_server.py /artifacts/

FROM scratch AS stub-hermes
COPY stubs/stub_server.py /artifacts/

FROM scratch AS stub-admin
COPY stubs/stub_server.py /artifacts/

# ==========================================================================
# 真实上游构建阶段（按需启用；BuildKit 下未引用时不构建）
# 切换方式: docker build --build-arg STUB_MODE=false \
#                        --build-arg DSH_ARTIFACTS=build-dsh \
#                        --build-arg OPENCLAW_ARTIFACTS=build-openclaw \
#                        --build-arg HERMES_ARTIFACTS=build-hermes ...
# 说明: DSH 无官方镜像, 仅能源码 pnpm 构建; OpenClaw/Hermes 亦按源码构建。
#       三者默认仅监听 127.0.0.1, 与本镜像"业务绑回环+nginx 网关对外"架构天然兼容。
# ==========================================================================

# ---- DSH: TypeScript/pnpm monorepo, @deepseek-ai/dsh, 默认 3080, 仅回环 ----
FROM node:24-bookworm AS build-dsh
ARG DSH_REPO=https://github.com/deepseek-ai/deepseek-harness.git
ARG DSH_REF=dsh-v0.1.3-alpha.1
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && git clone --depth 1 --branch "$DSH_REF" "$DSH_REPO" . \
 && corepack enable \
 && pnpm install --frozen-lockfile \
 && pnpm run build \
 && mkdir -p /artifacts \
 # 启动走 apps/cli/src/bin.ts (root script dsh: node --import tsx/esm ...),
 # 需保留 workspace + devDeps(tsx), 故整目录随产物; 精简层意义有限。
 && cp -r . /artifacts/app

# ---- OpenClaw: TypeScript/pnpm monorepo, gateway 子命令, 默认 18789 ----
# 官方链: corepack + pnpm install --frozen-lockfile + pnpm build:docker + pnpm ui:build
# 构建需 make/g++(native 编译), 内存建议 >=6GB; 用 node:24-bookworm(非 slim, 需编译链)。
FROM node:24-bookworm AS build-openclaw
ARG OPENCLAW_REPO=https://github.com/openclaw/openclaw.git
ARG OPENCLAW_REF=v2026.9.1
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
        python3 make g++ procps \
 && rm -rf /var/lib/apt/lists/* \
 && git clone --depth 1 --branch "$OPENCLAW_REF" "$OPENCLAW_REPO" . \
 && corepack enable \
 && NODE_OPTIONS=--max-old-space-size=2048 pnpm install --frozen-lockfile \
 && NODE_OPTIONS=--max-old-space-size=2048 pnpm build:docker \
 && NODE_OPTIONS=--max-old-space-size=2048 pnpm ui:build \
 && mkdir -p /artifacts \
 # 运行时入口 node dist/index.js gateway, 需 dist + prod node_modules + package.json
 && cp -r dist node_modules package.json /artifacts/

# ---- Hermes: Python/uv, NousResearch/hermes-agent, gateway 常驻; dashboard 9119 / API 8642 ----
FROM python:3.11-bookworm AS build-hermes
ARG HERMES_REPO=https://github.com/NousResearch/hermes-agent.git
ARG HERMES_REF=v2026.8.31
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates python3-dev build-essential gcc g++ make cmake \
 && rm -rf /var/lib/apt/lists/* \
 # uv 管理依赖(全精确锁版本, 必须 --frozen 防 exclude-newer 解析失败)
 && curl -LsSf https://astral.sh/uv/install.sh | sh \
 && git clone --depth 1 --branch "$HERMES_REF" "$HERMES_REPO" . \
 && /root/.local/bin/uv sync --frozen --extra all \
 && /root/.local/bin/uv pip install --no-deps -e . \
 && mkdir -p /artifacts \
 # 运行时用 .venv/bin/hermes gateway run; 需项目源码 + .venv
 && cp -r . /artifacts/app

# ---- Admin: 本镜像内置管理面板(导航/状态聚合), 不接外部 repo; 恒用 stub-admin ----
# 说明: ADMIN 是自研组件(www/ 模板 + status-aggregator), 由 stub_server.py 34567 提供,
#       无需也不应从外部 git 拉取。保留本阶段仅为占位, 实践中勿设 ADMIN_ARTIFACTS=build-admin。
FROM scratch AS build-admin
COPY www/ /artifacts/www/

# ---------- 产物汇聚（由 ARG 选择 stub 或真实构建） ----------
FROM ${DSH_ARTIFACTS} AS artifacts-dsh
FROM ${OPENCLAW_ARTIFACTS} AS artifacts-openclaw
FROM ${HERMES_ARTIFACTS} AS artifacts-hermes
FROM ${ADMIN_ARTIFACTS} AS artifacts-admin

# ==========================================================================
# 运行时
# ==========================================================================
# 仅用于提取 Node 运行时。升到 24 以兼容真实上游引擎约束:
#   DSH     engines.node ^22.19||>=24
#   OpenClaw 需 >=24.15 (官方 node:24-bookworm)
#  Hermes 运行走 Python, 不受影响。
FROM node:24-bookworm AS node-runtime

FROM debian:bookworm-slim
ARG STUB_MODE
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      nginx supervisor openssh-server cron logrotate \
      tini gettext-base curl ca-certificates openssl git \
      python3 python3-venv fail2ban \
      certbot python3-certbot-dns-cloudflare \
      python3-certbot-dns-route53 python3-certbot-dns-google \
      python3-certbot-dns-digitalocean \
    && rm -rf /var/lib/apt/lists/*

# Node 24 运行时（与构建阶段同版本，glibc 一致）
COPY --from=node-runtime /usr/local/ /usr/local/

# 各服务非 root 用户
RUN useradd -r -u 1001 dsh \
 && useradd -r -u 1002 openclaw \
 && useradd -r -u 1003 hermes \
 && useradd -r -u 1004 admin

# 服务产物
COPY --from=artifacts-dsh      /artifacts/ /opt/dsh/
COPY --from=artifacts-openclaw /artifacts/ /opt/openclaw/
COPY --from=artifacts-hermes   /artifacts/ /opt/hermes/
COPY --from=artifacts-admin    /artifacts/ /opt/admin/

# 平台配置与脚本
COPY conf/         /etc/aio/conf/
COPY www/          /etc/aio/www/
COPY scripts/      /etc/aio/scripts/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /etc/aio/scripts/*.sh \
             /etc/aio/scripts/dns-hooks/*.py \
 && mkdir -p /var/www/html /var/www/acme /data /var/log

# 桩模式：写入 stub 默认启动命令（可被环境变量 *_COMMAND 覆盖）
RUN if [ "$STUB_MODE" = "true" ]; then \
      printf '%s\n' \
        'DSH_COMMAND="python3 /opt/dsh/stub_server.py 3080 dsh"' \
        'OPENCLAW_COMMAND="python3 /opt/openclaw/stub_server.py 18789 openclaw"' \
        'HERMES_COMMAND="python3 /opt/hermes/stub_server.py 6060 hermes"' \
        'ADMIN_COMMAND="python3 /opt/admin/stub_server.py 34567 admin"' \
        > /etc/aio/stub-defaults.env ; \
    fi

EXPOSE 80 443 22 3080 18789 6060 34567

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD /etc/aio/scripts/healthcheck.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
