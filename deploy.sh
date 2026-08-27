#!/bin/bash
# =============================================================================
# DeepSeek Harness 一键部署脚本（GitHub 仓库版）
# 项目地址: https://github.com/yuanshandalishuishou/deepseek-harness-zulin
# 镜像地址: ghcr.io/yuanshandalishuishou/deepseek-harness-zulin:latest
#
# 优先拉取 GitHub Actions 自动构建的 GHCR 镜像；拉取失败时自动回退为
# 克隆仓库 + 本地构建。所有 API Key / 模型选择通过环境变量传入容器，
# 在容器首次启动时由 entrypoint.sh 生成配置（镜像内不含任何密钥）。
#
# 端口映射：SSH 10022→22 | Harness 13000→3000 | xRDP 13389→3389 | OpenClaw 18789→18789 | Hermes Web UI 18000→3000 | Hermes 管理面板 18080→8080 | Token-Free Gateway 13456→3456(默认启用)
# =============================================================================
set -euo pipefail

# =========================== 颜色定义 ===========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# =========================== 配置变量（可通过环境变量覆盖） ===========================
REPO_URL="https://github.com/yuanshandalishuishou/deepseek-harness-zulin.git"
GHCR_IMAGE="ghcr.io/yuanshandalishuishou/deepseek-harness-zulin:latest"

# DeepSeek API Key
DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"
# OpenAI 兼容 API Key（用于硅基流动、百炼等）
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
# 模型选择：1=DeepSeek官方, 2=硅基流动, 3=阿里百炼, 4=DeepSeek+自定义, 5=自定义OpenAI
MODEL_CHOICE="${MODEL_CHOICE:-1}"
# MODEL_CHOICE=4 或 5 时需要设置
CUSTOM_MODEL_NAME="${CUSTOM_MODEL_NAME:-gpt-4o-mini}"
CUSTOM_OPENAI_BASE_URL="${CUSTOM_OPENAI_BASE_URL:-}"
CUSTOM_OPENAI_MODEL="${CUSTOM_OPENAI_MODEL:-}"

# Token-Free Gateway（免 API Key 网页会话网关，默认启用）
# 通过无头 Chromium 登录各 AI 网站后，以 OpenAI 兼容 /v1 接口转发请求。
# 设为 0 可关闭；TFG_API_KEY 留空则不鉴权（仅建议内网使用）。
ENABLE_TOKEN_FREE_GATEWAY="${ENABLE_TOKEN_FREE_GATEWAY:-1}"
TFG_PORT="${TFG_PORT:-3456}"
TFG_API_KEY="${TFG_API_KEY:-}"
TFG_CDP_URL="${TFG_CDP_URL:-http://127.0.0.1:9222}"

# Docker 镜像名与容器名（本地构建回退时使用）
IMAGE_NAME="deepseek-harness-debian13:latest"
CONTAINER_NAME="dsh-debian13"

# =========================== 检查 Docker ===========================
if ! command -v docker &> /dev/null; then
    warn "Docker 未安装，正在自动安装..."
    apt update -qq && apt install -y -qq docker.io docker-compose || err "Docker 安装失败"
    systemctl enable --now docker
    ok "Docker 安装完成"
else
    ok "Docker 已安装: $(docker --version)"
fi

# =========================== 可选：配置 Docker 镜像加速器 ===========================
configure_docker_mirror() {
    info "配置 Docker 镜像加速器..."
    local daemon_json="/etc/docker/daemon.json"
    local mirrors=("https://docker.m.daocloud.io" "https://dockerproxy.com" "https://hub.rat.dev" "https://docker.1panel.live")
    if [ -f "$daemon_json" ]; then cp "$daemon_json" "${daemon_json}.bak.$(date +%s)"; fi
    cat > "$daemon_json" << EOF
{
    "registry-mirrors": [$(printf '"%s",' "${mirrors[@]}" | sed 's/,$//')]
}
EOF
    systemctl restart docker
    ok "Docker 加速器已配置"
}

# =========================== 获取镜像：优先 GHCR，回退本地构建 ===========================
RUN_IMAGE=""
if docker pull "$GHCR_IMAGE"; then
    ok "GHCR 预构建镜像拉取成功"
    RUN_IMAGE="$GHCR_IMAGE"
else
    warn "GHCR 镜像拉取失败（可能为私有仓库或尚未完成首次构建），回退为本地构建..."
    if ! docker pull debian:trixie-slim &> /dev/null; then
        warn "基础镜像拉取失败，尝试配置加速器..."
        configure_docker_mirror
    fi
    SRC_DIR="$(pwd)/deepseek-harness-zulin-src"
    if [ -d "$SRC_DIR/.git" ]; then
        info "更新本地仓库..."
        git -C "$SRC_DIR" pull --ff-only || warn "仓库更新失败，使用现有代码继续"
    else
        info "克隆仓库..."
        git clone "$REPO_URL" "$SRC_DIR" || err "仓库克隆失败"
    fi
    info "开始构建 Docker 镜像（国内镜像加速）..."
    docker build -t "$IMAGE_NAME" \
        --build-arg DEBIAN_MIRROR="${DSH_DEBIAN_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn}" \
        --build-arg NODE_DIST="${DSH_NODE_DIST:-https://mirrors.tuna.tsinghua.edu.cn/nodejs-release}" \
        --build-arg NPM_REGISTRY="${DSH_NPM_REGISTRY:-https://registry.npmmirror.com}" \
        "$SRC_DIR"
    ok "镜像构建完成"
    RUN_IMAGE="$IMAGE_NAME"
fi

# =========================== 启动容器 ===========================
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

info "启动容器..."
docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p 10022:22 \
    -p 13000:3000 \
    -p 13389:3389 \
    -p 18789:18789 \
    -p 18000:3000 \
    -p 18080:8080 \
    -p 13456:3456 \
    -e DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
    -e OPENAI_API_KEY="$OPENAI_API_KEY" \
    -e MODEL_CHOICE="$MODEL_CHOICE" \
    -e CUSTOM_MODEL_NAME="$CUSTOM_MODEL_NAME" \
    -e CUSTOM_OPENAI_BASE_URL="$CUSTOM_OPENAI_BASE_URL" \
    -e CUSTOM_OPENAI_MODEL="$CUSTOM_OPENAI_MODEL" \
    -e ENABLE_TOKEN_FREE_GATEWAY="$ENABLE_TOKEN_FREE_GATEWAY" \
    -e TFG_PORT="$TFG_PORT" \
    -e TFG_API_KEY="$TFG_API_KEY" \
    -e TFG_CDP_URL="$TFG_CDP_URL" \
    -v dsh-data:/root/.dsh \
    -v dsh-chrome-tfg:/root/.chrome-tfg-debug \
    -v dsh-tfg-auth:/root/.token-free-gateway \
    "$RUN_IMAGE"

ok "容器已启动: $CONTAINER_NAME"

# =========================== 输出信息 ===========================
echo ""
echo "════════════════════════════════════════════════════════"
echo -e "${GREEN}✅ DeepSeek Harness 部署成功！${NC}"
echo "════════════════════════════════════════════════════════"
echo ""
echo "  Web UI:     http://localhost:13000"
echo "  SSH:        ssh -p 10022 root@localhost  (密码: deepseek)"
echo "  xRDP:       localhost:13389  (root / deepseek)"
echo "  OpenClaw:   http://localhost:18789  (网关，八位专家多角色)"
echo "  Hermes UI:  http://localhost:18000  (Web UI 对话界面，登录令牌见容器日志 / HERMES_WEBUI_TOKEN)"
echo "  Hermes 面板: http://localhost:18080  (管理面板，需先配置认证 provider)"
echo "  Token-Free Gateway: http://localhost:13456  (免 API Key 网关，OpenAI 兼容 /v1)"
echo ""
echo "  运行镜像:   $RUN_IMAGE"
echo "  数据卷:     dsh-data → /root/.dsh（首次启动自动初始化）"
echo "  数据卷:     dsh-chrome-tfg → /root/.chrome-tfg-debug（持久化 Gateway Chrome 登录会话）"
echo "  数据卷:     dsh-tfg-auth → /root/.token-free-gateway（持久化 Gateway 捕获的网页凭证，重启免重新授权）"
echo "  默认角色:   纪总 (enterprise-boss)"
echo "  模型选择:   MODEL_CHOICE=$MODEL_CHOICE（1=DeepSeek官方 2=硅基流动 3=百炼 4=DS自定义 5=自定义OpenAI）"
echo "  Gateway:    ENABLE_TOKEN_FREE_GATEWAY=$ENABLE_TOKEN_FREE_GATEWAY（1=启用 0=关闭），端口 $TFG_PORT"
echo ""
echo "  日志:       docker logs -f $CONTAINER_NAME"
echo "════════════════════════════════════════════════════════"
