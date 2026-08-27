#!/bin/bash
# =============================================================================
# DeepSeek Harness 容器入口脚本（entrypoint.sh）
# -----------------------------------------------------------------------------
# 职责：
#   1) 根据环境变量设置 SSH / xRDP 的登录账户与密码（二者共用同一系统账户）。
#   2) 首次启动时，根据环境变量生成 /root/.dsh/settings.yaml（镜像内不含任何密钥）。
#   3) 启动 SSH(22) 与 xRDP(3389) 远程接入服务。
#   4) 启动 DeepSeek Harness Web 服务（dsh web），监听容器内 0.0.0.0:WEB_PORT。
#
# 支持的环境变量（均在下方有默认值与详细注释）：
#   DEEPSEEK_API_KEY         DeepSeek 官方 API Key
#   OPENAI_API_KEY           OpenAI 兼容 API Key（硅基流动 / 百炼 / 自建网关）
#   MODEL_CHOICE             1=DeepSeek官方 2=硅基流动 3=阿里百炼 4=DeepSeek+自定义 5=自定义OpenAI
#   CUSTOM_MODEL_NAME        MODEL_CHOICE=4 时的 DeepSeek 模型名
#   CUSTOM_OPENAI_BASE_URL   MODEL_CHOICE=2/3/5 时的 base-url（2/3 有内置默认值）
#   CUSTOM_OPENAI_MODEL      MODEL_CHOICE=5 时的模型名
#   ROOT_USER                SSH / xRDP 登录用户名（默认 root）
#   ROOT_PASSWORD            SSH / xRDP 登录密码（默认 deepseek）
#   WEB_PORT                 dsh web 容器内监听端口（默认 3080，即官方默认）
#   WEB_HOST                 dsh web 绑定地址（默认 0.0.0.0，对容器外开放）
#   WEB_TRUSTED_HOSTS        dsh web /api 信任的浏览器来源（host:port，逗号分隔）
# =============================================================================
set -e

# =========================== ① 配置访问凭据（SSH 与 xRDP 共用同一系统账户） ===========================
# 允许通过环境变量覆盖默认用户名/密码；不传则用出厂默认值（root / deepseek）
ROOT_USER="${ROOT_USER:-root}"
ROOT_PASSWORD="${ROOT_PASSWORD:-deepseek}"

if [ "$ROOT_USER" = "root" ]; then
    # root 账户：直接用 chpasswd 设置密码
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

# 清理可能残留的 xrdp pid 文件，避免重启容器后 xrdp 误判“已在运行”
rm -f /var/run/xrdp/xrdp-sesman.pid /var/run/xrdp/xrdp.pid

# =========================== ② 读取模型 / 提供商配置（带默认值） ===========================
DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
MODEL_CHOICE="${MODEL_CHOICE:-1}"
CUSTOM_MODEL_NAME="${CUSTOM_MODEL_NAME:-gpt-4o-mini}"
CUSTOM_OPENAI_BASE_URL="${CUSTOM_OPENAI_BASE_URL:-}"
CUSTOM_OPENAI_MODEL="${CUSTOM_OPENAI_MODEL:-}"

# 硅基流动 / 阿里百炼 的内置默认 base-url（仅在用户未显式指定时填充）
case "$MODEL_CHOICE" in
    2) CUSTOM_OPENAI_BASE_URL="${CUSTOM_OPENAI_BASE_URL:-https://api.siliconflow.cn/v1}";;
    3) CUSTOM_OPENAI_BASE_URL="${CUSTOM_OPENAI_BASE_URL:-https://dashscope.aliyuncs.com/compatible-mode/v1}";;
esac

# =========================== ③ 生成 settings.yaml（仅首次启动） ===========================
# 把 heredoc 写出的模板与用户的模型选择拼接成 /root/.dsh/settings.yaml
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

    # 若选用 OpenAI 兼容提供商（硅基流动 / 百炼 / 自定义），追加对应 provider 段
    if [ "$MODEL_CHOICE" = "2" ] || [ "$MODEL_CHOICE" = "3" ] || [ "$MODEL_CHOICE" = "5" ]; then
        cat >> "$f" << SETTLEOF
  openai-compatible:
    api-key: ${OPENAI_API_KEY}
    base-url: ${CUSTOM_OPENAI_BASE_URL}
SETTLEOF
    fi

    # 固定注册两款 DeepSeek 官方 v4 模型（deepseek-chat/reasoner 已弃用失效）
    cat >> "$f" << 'SETTLEOF'

models:
  deepseek-v4-flash:
    provider: deepseek
    model: deepseek-v4-flash
  deepseek-v4-pro:
    provider: deepseek
    model: deepseek-v4-pro
SETTLEOF

    # 按 MODEL_CHOICE 追加对应的自定义模型条目
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

    # 根据 MODEL_CHOICE 决定默认模型
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

# =========================== ④ 首次启动初始化数据目录 ===========================
# 仅当 settings.yaml 或 souls/ 不存在时才重新生成（已存在则保留，方便持久化配置）
if [ ! -f /root/.dsh/settings.yaml ] || [ ! -d /root/.dsh/souls ]; then
    echo "[INFO] 初始化 /root/.dsh 数据目录..."
    mkdir -p /root/.dsh
    cp -r /opt/dsh-initial/souls /root/.dsh/souls
    write_settings_yaml /root/.dsh/settings.yaml
    echo "[INFO] 默认模型: $(grep 'default-model' /root/.dsh/settings.yaml | awk '{print $2}')"
fi

# =========================== ⑤ 首次安装核心插件 ===========================
if [ ! -f /root/.dsh/.plugins_installed ]; then
    echo "[INFO] 首次启动，安装核心插件..."
    cd /opt/dsh
    pnpm dsh plugin --profile web add @deepseek-ai/dsh-market 2>/dev/null || true
    touch /root/.dsh/.plugins_installed
fi

# =========================== ⑥ 启动远程接入服务（SSH / xRDP） ===========================
if [ -x /usr/sbin/sshd ]; then /usr/sbin/sshd; echo "[INFO] SSH 已启动"; fi
if [ -x /usr/sbin/xrdp-sesman ] && [ -x /usr/sbin/xrdp ]; then
    /usr/sbin/xrdp-sesman &
    /usr/sbin/xrdp --nodaemon &
    echo "[INFO] xrdp 已启动"
fi

# =========================== ⑦ 启动 DeepSeek Harness Web 服务 ===========================
cd /opt/dsh

# Web 服务监听端口（官方默认 3080）。可用 -e WEB_PORT=xxxx 覆盖。
WEB_PORT="${WEB_PORT:-3080}"
# Web 服务绑定地址。默认 0.0.0.0 以对容器外（宿主机/局域网）开放。
# 注意：上游 startup.ts 原本硬编码拒绝 0.0.0.0，本镜像已在构建阶段由
#       scripts/patch-web-bind.sh 放开该限制（详见该脚本注释）。
WEB_HOST="${WEB_HOST:-0.0.0.0}"

# /api 浏览器信任围栏（browser-trust fence）：仅放行本机来源与受信任主机，
# 用于防止跨站请求伪造。局域网内用浏览器直连时，请传入宿主机地址以放行 /api。
# 默认值包含 127.0.0.1（SSH 隧道场景）与 192.168.31.100（本机局域网 IP 场景）；
# 其他网络环境请按实际访问地址自行追加，例如 -e WEB_TRUSTED_HOSTS=宿主IP:映射端口
WEB_TRUSTED_HOSTS="${WEB_TRUSTED_HOSTS:-127.0.0.1:13000,192.168.31.100:13000}"

# 把逗号分隔的受信任主机逐个转成 `--trusted-host <host>` 参数
TRUSTED_ARGS=""
IFS=',' read -ra _ths <<< "$WEB_TRUSTED_HOSTS"
for _th in "${_ths[@]}"; do
  _th="$(echo "$_th" | xargs)"          # 去除首尾空白
  [ -n "$_th" ] && TRUSTED_ARGS="$TRUSTED_ARGS --trusted-host $_th"
done

# --no-open：关闭自动打开浏览器（容器内无桌面浏览器，必须加，否则会报错）
# 最终启动命令示例：pnpm dsh web --host 0.0.0.0 --port 3080 --no-open --trusted-host 127.0.0.1:13000 ...

# crypto polyfill：通过 NODE_OPTIONS=--require 注入，兜底 globalThis.crypto.randomUUID，
# 根治浏览器/运行期替换 crypto 导致的设置页 "crypto.randomUUID is not a function" 报错。
if [ -f /opt/deepseek-harness/dsh-crypto-polyfill.cjs ]; then
  export NODE_OPTIONS="--require /opt/deepseek-harness/dsh-crypto-polyfill.cjs"
  echo "[INFO] 已启用 crypto polyfill（NODE_OPTIONS=${NODE_OPTIONS}）"
fi

echo "[INFO] 启动 DeepSeek Harness on ${WEB_HOST}:${WEB_PORT} (trusted: $WEB_TRUSTED_HOSTS)..."
exec pnpm dsh web --host "$WEB_HOST" --port "$WEB_PORT" --no-open $TRUSTED_ARGS
