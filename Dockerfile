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
# TODO: 替换 *_REPO/*_REF 与构建命令为实际上游信息
# ==========================================================================
FROM python:3.12-bookworm AS build-dsh
ARG DSH_REPO=https://github.com/example/deepseek-harness.git
ARG DSH_REF=main
WORKDIR /src
RUN git clone --depth 1 --branch "$DSH_REF" "$DSH_REPO" . \
 && python -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt \
 && mkdir -p /artifacts \
 && cp -r . /artifacts/app \
 && cp -r /opt/venv /artifacts/venv

FROM node:22-bookworm AS build-openclaw
ARG OPENCLAW_REPO=https://github.com/example/openclaw.git
ARG OPENCLAW_REF=main
WORKDIR /src
RUN git clone --depth 1 --branch "$OPENCLAW_REF" "$OPENCLAW_REPO" . \
 && corepack enable && pnpm install --frozen-lockfile \
 && pnpm build && pnpm prune --prod \
 && mkdir -p /artifacts \
 && cp -r dist node_modules package.json /artifacts/

FROM node:22-bookworm AS build-hermes
ARG HERMES_REPO=https://github.com/example/hermes-agent.git
ARG HERMES_REF=main
WORKDIR /src
RUN git clone --depth 1 --branch "$HERMES_REF" "$HERMES_REPO" . \
 && corepack enable && pnpm install --frozen-lockfile \
 && pnpm build && pnpm prune --prod \
 && mkdir -p /artifacts \
 && cp -r dist node_modules package.json /artifacts/

FROM node:22-bookworm AS build-admin
ARG ADMIN_REPO=https://github.com/example/web-admin.git
ARG ADMIN_REF=main
WORKDIR /src
RUN git clone --depth 1 --branch "$ADMIN_REF" "$ADMIN_REPO" . \
 && corepack enable && pnpm install --frozen-lockfile \
 && pnpm build && pnpm prune --prod \
 && mkdir -p /artifacts \
 && cp -r dist node_modules package.json /artifacts/

# ---------- 产物汇聚（由 ARG 选择 stub 或真实构建） ----------
FROM ${DSH_ARTIFACTS} AS artifacts-dsh
FROM ${OPENCLAW_ARTIFACTS} AS artifacts-openclaw
FROM ${HERMES_ARTIFACTS} AS artifacts-hermes
FROM ${ADMIN_ARTIFACTS} AS artifacts-admin

# ==========================================================================
# 运行时
# ==========================================================================
# 仅用于提取 Node 22 运行时（与构建阶段同版本，glibc 一致）
FROM node:22-bookworm AS node-runtime

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

# Node 22 运行时（与构建阶段同版本，glibc 一致）
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
