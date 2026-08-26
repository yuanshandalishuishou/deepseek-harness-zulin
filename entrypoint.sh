#!/bin/bash
# =============================================================================
# DeepSeek Harness 容器入口脚本
# 首次启动时根据环境变量生成 /root/.dsh/settings.yaml（镜像内不含任何密钥）
#
# 支持的环境变量：
#   DEEPSEEK_API_KEY        DeepSeek 官方 API Key
#   OPENAI_API_KEY          OpenAI 兼容 API Key（硅基流动/百炼等）
#   MODEL_CHOICE            1=DeepSeek官方 2=硅基流动 3=阿里百炼 4=DeepSeek+自定义 5=自定义OpenAI
#   CUSTOM_MODEL_NAME       MODEL_CHOICE=4 时的 DeepSeek 模型名
#   CUSTOM_OPENAI_BASE_URL  MODEL_CHOICE=2/3/5 时的 base-url（2/3 有默认值）
#   CUSTOM_OPENAI_MODEL     MODEL_CHOICE=5 时的模型名
#   ROOT_USER               SSH / xRDP 登录用户名（默认 root）
#   ROOT_PASSWORD           SSH / xRDP 登录密码（默认 deepseek）
# =============================================================================
set -e

# =========================== 配置访问凭据（SSH 与 xRDP 共用系统账户） ===========================
ROOT_USER="${ROOT_USER:-root}"
ROOT_PASSWORD="${ROOT_PASSWORD:-deepseek}"

if [ "$ROOT_USER" = "root" ]; then
    echo "root:${ROOT_PASSWORD}" | chpasswd
else
    # 非 root 用户：创建账户并授权 sudo，xRDP 桌面会话需要该用户的 .xsession
    id -u "$ROOT_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ROOT_USER"
    echo "${ROOT_USER}:${ROOT_PASSWORD}" | chpasswd
    usermod -aG sudo "$ROOT_USER" 2>/dev/null || usermod -aG wheel "$ROOT_USER" 2>/dev/null || true
    if [ ! -f "/home/${ROOT_USER}/.xsession" ]; then
        echo "startxfce4" > "/home/${ROOT_USER}/.xsession"
        chown "${ROOT_USER}:${ROOT_USER}" "/home/${ROOT_USER}/.xsession"
    fi
fi
echo "[INFO] 访问账户: ${ROOT_USER} / (密码已按环境变量设置)"

rm -f /var/run/xrdp/xrdp-sesman.pid /var/run/xrdp/xrdp.pid

DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
MODEL_CHOICE="${MODEL_CHOICE:-1}"
CUSTOM_MODEL_NAME="${CUSTOM_MODEL_NAME:-gpt-4o-mini}"
CUSTOM_OPENAI_BASE_URL="${CUSTOM_OPENAI_BASE_URL:-}"
CUSTOM_OPENAI_MODEL="${CUSTOM_OPENAI_MODEL:-}"

# 硅基流动 / 阿里百炼 的默认 base-url
case "$MODEL_CHOICE" in
    2) CUSTOM_OPENAI_BASE_URL="${CUSTOM_OPENAI_BASE_URL:-https://api.siliconflow.cn/v1}";;
    3) CUSTOM_OPENAI_BASE_URL="${CUSTOM_OPENAI_BASE_URL:-https://dashscope.aliyuncs.com/compatible-mode/v1}";;
esac

# =========================== 生成 settings.yaml ===========================
write_settings_yaml() {
    local f="$1"
    cat > "$f" << SETTLEOF
system-prompt:
  persona: enterprise-boss

providers:
  deepseek:
    api-key: ${DEEPSEEK_API_KEY}
    base-url: https://api.deepseek.com
SETTLEOF

    if [ "$MODEL_CHOICE" = "2" ] || [ "$MODEL_CHOICE" = "3" ] || [ "$MODEL_CHOICE" = "5" ]; then
        cat >> "$f" << SETTLEOF
  openai-compatible:
    api-key: ${OPENAI_API_KEY}
    base-url: ${CUSTOM_OPENAI_BASE_URL}
SETTLEOF
    fi

    cat >> "$f" << 'SETTLEOF'

models:
  deepseek-v4-flash:
    provider: deepseek
    model: deepseek-v4-flash
  deepseek-v4-pro:
    provider: deepseek
    model: deepseek-v4-pro
SETTLEOF

    case "$MODEL_CHOICE" in
        2)
            cat >> "$f" << SETTLEOF
  sf-qwen2.5-72b:
    provider: openai-compatible
    model: Qwen/Qwen2.5-72B-Instruct
SETTLEOF
            ;;
        3)
            cat >> "$f" << SETTLEOF
  dash-qwen-plus:
    provider: openai-compatible
    model: qwen-plus
SETTLEOF
            ;;
        4)
            cat >> "$f" << SETTLEOF
  custom-model:
    provider: deepseek
    model: ${CUSTOM_MODEL_NAME}
SETTLEOF
            ;;
        5)
            cat >> "$f" << SETTLEOF
  custom-openai-compatible:
    provider: openai-compatible
    model: ${CUSTOM_OPENAI_MODEL}
SETTLEOF
            ;;
    esac

    local default_model="deepseek-v4-flash"
    case "$MODEL_CHOICE" in
        2) default_model="sf-qwen2.5-72b";;
        3) default_model="dash-qwen-plus";;
        4) default_model="deepseek-v4-flash";;
        5) default_model="custom-openai-compatible";;
    esac
    cat >> "$f" << SETTLEOF

default-model: ${default_model}
SETTLEOF
}

# =========================== 首次启动初始化 ===========================
if [ ! -f /root/.dsh/settings.yaml ] || [ ! -d /root/.dsh/souls ]; then
    echo "[INFO] 初始化 /root/.dsh 数据目录..."
    mkdir -p /root/.dsh
    cp -r /opt/dsh-initial/souls /root/.dsh/souls
    write_settings_yaml /root/.dsh/settings.yaml
    echo "[INFO] 默认模型: $(grep 'default-model' /root/.dsh/settings.yaml | awk '{print $2}')"
fi

# 插件安装（仅首次）
if [ ! -f /root/.dsh/.plugins_installed ]; then
    echo "[INFO] 首次启动，安装核心插件..."
    cd /opt/dsh
    pnpm dsh plugin --profile web add @deepseek-ai/dsh-market 2>/dev/null || true
    touch /root/.dsh/.plugins_installed
fi

# =========================== 启动服务 ===========================
if [ -x /usr/sbin/sshd ]; then /usr/sbin/sshd; echo "[INFO] SSH 已启动"; fi
if [ -x /usr/sbin/xrdp-sesman ] && [ -x /usr/sbin/xrdp ]; then
    /usr/sbin/xrdp-sesman &
    /usr/sbin/xrdp --nodaemon &
    echo "[INFO] xrdp 已启动"
fi

cd /opt/dsh
echo "[INFO] 启动 DeepSeek Harness on port 3000..."
exec pnpm dsh web --port 3000 --host 0.0.0.0 --allow-non-loopback
