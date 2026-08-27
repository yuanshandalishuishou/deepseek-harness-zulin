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
#   OPENCLAW_PORT            OpenClaw 网关容器内监听端口（默认 18789）
#   HERMES_PORT              Hermes 管理面板容器内监听端口（默认 8080）
#   HERMES_WEB_PORT           Hermes Web UI（hermes-web-ui）容器内监听端口（默认 3000）
#   ENABLE_TOKEN_FREE_GATEWAY 是否启用 Token-Free Gateway 免 Token 网关（默认 0=关闭；1=开启）
#   TFG_PORT                 Token-Free Gateway 容器内监听端口（默认 3456，提供 OpenAI 兼容 /v1）
#   TFG_API_KEY              客户端调用网关的 Bearer Token（默认空=不鉴权，局域网内建议留空）
#   TFG_CDP_URL              Chromium CDP 调试端点（默认 http://127.0.0.1:9222）
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

# =========================== ⑤ 首次启动安装插件市场 ===========================
# 社区维护的 DeepSeek Harness 插件市场，npm 包名为 dshmarket
# （仓库 github.com/dsh-market/dsh-market；注意不是 @deepseek-ai/dsh-market）。
# 前置：dsh web 版本需 >= 0.1.0-rc.6（当前 0.1.1-rc.2，满足），且可访问 npm 源。
# 安装失败仅告警、不阻断 Web 启动（plugin add 失败则用户在 Web 界面手动安装即可）。
if [ ! -f /root/.dsh/.plugins_installed ]; then
    echo "[INFO] 首次启动，安装插件市场 dshmarket（社区维护的 DeepSeek Harness 插件市场）..."
    cd /opt/dsh
    if pnpm dsh plugin --profile web add dshmarket 2>&1; then
        echo "[INFO] dshmarket 安装成功"
    else
        echo "[WARN] dshmarket 安装失败（可稍后在 Web 界面「插件市场」手动安装），继续启动 Web..."
    fi
    touch /root/.dsh/.plugins_installed
fi

# =========================== ⑥ 启动远程接入服务（SSH / xRDP） ===========================
if [ -x /usr/sbin/sshd ]; then /usr/sbin/sshd; echo "[INFO] SSH 已启动"; fi
if [ -x /usr/sbin/xrdp-sesman ] && [ -x /usr/sbin/xrdp ]; then
    /usr/sbin/xrdp-sesman &
    /usr/sbin/xrdp --nodaemon &
    echo "[INFO] xrdp 已启动"
fi

# =========================== ⑥.① 启动 OpenClaw 网关（八位专家多角色，0.0.0.0 开放） ===========================
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
if command -v openclaw >/dev/null 2>&1; then
    echo "[INFO] 初始化 OpenClaw 工作区（八位专家多角色）..."
    mkdir -p /root/.openclaw
    if [ ! -d /root/.openclaw/workspace ]; then
        cp -r /opt/openclaw-initial/openclaw/workspace /root/.openclaw/workspace
        echo "[INFO] OpenClaw 工作区已初始化（souls/ 八位专家人设与 DeepSeek Harness 一致）"
    fi
    # 注入 DeepSeek API Key（镜像零密钥，运行时由环境变量提供）
    if [ -n "$DEEPSEEK_API_KEY" ]; then
        echo "DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY" > /root/.openclaw/.env
    fi
    # 生成 openclaw.json（网关端口 + 默认 DeepSeek 模型）
    # 注意：新版 openclaw 要求 gateway.mode 必须显式声明，否则网关拒绝启动。
    # 仅当文件不存在时才生成，避免覆盖管理端口(16688)在运行时修改的配置。
    if [ ! -f /root/.openclaw/openclaw.json ]; then
    cat > /root/.openclaw/openclaw.json <<JSON
{
  "agents": {
    "defaults": {
      "workspace": "/root/.openclaw/workspace",
      "model": { "primary": "deepseek/deepseek-v4-pro", "fallbacks": ["deepseek/deepseek-v4-flash"] },
      "skipBootstrap": true
    }
  },
  "gateway": { "mode": "local", "port": ${OPENCLAW_PORT} }
}
JSON
    fi
    # 启动网关：
    #  - --bind lan：绑定到容器外部网卡（0.0.0.0），这样宿主机的端口映射才能转发进来；
    #    openclaw 在绑定到 lan 时强制要求鉴权，故必须提供 token/password。
    #  - 新版 openclaw 要求 Node >=22.22.3 或 >=24.15.0；镜像自带 Node 为 24.1.0（不支持，
    #    落在 23~24.15 的缺口区间），因此改用镜像内预装的 /opt/node24（v24.20.0）。
    # 网关令牌：优先读取管理端口(16688)写入的 /root/.openclaw/gateway_token，否则用默认值。
    OC_TOKEN="openclaw-default-token"
    [ -f /root/.openclaw/gateway_token ] && OC_TOKEN="$(cat /root/.openclaw/gateway_token)"
    export OPENCLAW_GATEWAY_TOKEN="$OC_TOKEN"
    export PATH="/opt/node24/bin:$PATH"
    nohup openclaw gateway --port "$OPENCLAW_PORT" --bind lan > /var/log/openclaw.log 2>&1 &
    echo "[INFO] OpenClaw 网关已启动: 0.0.0.0:${OPENCLAW_PORT} (网关令牌见 OPENCLAW_GATEWAY_TOKEN)"
else
    echo "[WARN] 未检测到 openclaw 命令，跳过 OpenClaw 网关启动"
fi

# =========================== ⑥.② 启动 Hermes Agent（Web UI + 管理面板，均 0.0.0.0 开放） ===========================
HERMES_WEB_PORT="${HERMES_WEB_PORT:-3000}"
HERMES_DASH_PORT="${HERMES_DASH_PORT:-8080}"
export PATH="/root/.local/bin:/root/.hermes/bin:/root/.cargo/bin:$PATH"
if command -v hermes >/dev/null 2>&1; then
    echo "[INFO] 初始化 Hermes 配置（默认 DeepSeek）..."
    mkdir -p /root/.hermes
    if [ ! -f /root/.hermes/config.yaml ]; then
        cp /opt/hermes-initial/config.yaml /root/.hermes/config.yaml
        echo "[INFO] Hermes config.yaml 已初始化"
    fi
    # 注入 DeepSeek API Key 到 ~/.hermes/.env（网关 / Web UI 运行时读取；镜像零密钥）
    if [ -n "$DEEPSEEK_API_KEY" ]; then
        echo "DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY" > /root/.hermes/.env
    fi
    # 启动 Hermes Web UI（社区版 hermes-web-ui，浏览器对话界面）。
    # 该命令会自动拉起 Gateway(8642) 与 BFF(8648)，前端监听 ${HERMES_WEB_PORT} 并绑定 0.0.0.0。
    if command -v hermes-web-ui >/dev/null 2>&1; then
        export AUTH_TOKEN="${HERMES_WEBUI_TOKEN:-hermes-webui-default}"
        export BIND_HOST=0.0.0.0
        nohup hermes-web-ui start --port "$HERMES_WEB_PORT" > /var/log/hermes-webui.log 2>&1 &
        echo "[INFO] Hermes Web UI 已启动: 0.0.0.0:${HERMES_WEB_PORT} (登录令牌见 /var/log/hermes-webui.log 或由 HERMES_WEBUI_TOKEN 指定)"
    else
        echo "[WARN] 未检测到 hermes-web-ui 命令，跳过 Web UI 启动"
    fi
    # 启动 Hermes 管理面板 Dashboard（9119 默认，本镜像改用 ${HERMES_DASH_PORT}）
    # 新版 Hermes Dashboard 在绑定到非回环地址(0.0.0.0)时强制要求鉴权提供方，
    # 否则拒绝暴露。这里通过环境变量注入 basic_auth（与 config.yaml 中的
    # dashboard.basic_auth 配套；插件 requires_env=HERMES_DASHBOARD_BASIC_AUTH_USERNAME
    # 决定了必须用环境变量激活，仅写 config.yaml 不够）。
    DEFAULT_DASH_HASH='scrypt$16384$8$1$atn9dAPGLudawkpjmIJUkw==$SUY+40pyRdC3Tlvre8KVidhdBqtxr71GonlYgpAzY3c='
    export HERMES_DASHBOARD_BASIC_AUTH_USERNAME="${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-admin}"
    export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH="${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH:-$DEFAULT_DASH_HASH}"
    nohup hermes dashboard --port "$HERMES_DASH_PORT" --host 0.0.0.0 --no-open > /var/log/hermes.log 2>&1 &
    echo "[INFO] Hermes 管理面板已启动: 0.0.0.0:${HERMES_DASH_PORT} (basic_auth 用户见 HERMES_DASHBOARD_BASIC_AUTH_USERNAME)"
else
    echo "[WARN] 未检测到 hermes 命令，跳过 Hermes 启动"
fi

# =========================== ⑥.③ 启动 Token-Free Gateway（免 Token 网关，默认关闭） ===========================
# 通过 -e ENABLE_TOKEN_FREE_GATEWAY=1 开启；可选 -e TFG_PORT（默认 3456）、-e TFG_API_KEY（默认空=不鉴权）、
# -e TFG_CDP_URL（默认 http://127.0.0.1:9222）。
# 该网关是 OpenAI 兼容网关（/v1/chat/completions），通过浏览器网页会话免 API Key 调用
# Claude / ChatGPT / DeepSeek / Qwen / Gemini / Kimi / Grok / Doubao / GLM / Perplexity / 智谱 / 小米 MiMo 等 13 家模型。
# 原理：驱动一个无头 Chromium（CDP 9222）登录各 AI 网站，再用网页会话转发请求（无需任何 API Key）。
# 使用前需先做一次网页授权：docker exec -it <容器> token-free-gateway webauth（在浏览器中登录各 AI 账号）。
ENABLE_TOKEN_FREE_GATEWAY="${ENABLE_TOKEN_FREE_GATEWAY:-0}"
TFG_PORT="${TFG_PORT:-3456}"
TFG_CDP_URL="${TFG_CDP_URL:-http://127.0.0.1:9222}"
if [ "$ENABLE_TOKEN_FREE_GATEWAY" = "1" ]; then
    echo "[INFO] 启用 Token-Free Gateway（端口 ${TFG_PORT}）"
    # 1) 拉起无头 Chromium 调试实例（CDP 9222），供网关通过网页会话免 Token 调用
    CHROME_DIR=/root/.chrome-tfg-debug
    if command -v chromium >/dev/null 2>&1 || [ -x /usr/bin/chromium ]; then
        # 仅清理上一次可能残留的锁文件，避免 “profile in use” 导致 Chromium 启动失败；
        # 不要删除整个目录，以便挂载的数据卷（/root/.chrome-tfg-debug）能持久化已登录的网页会话。
        rm -f "$CHROME_DIR/SingletonLock" "$CHROME_DIR/SingletonLock".* "$CHROME_DIR/SingletonCookie" 2>/dev/null
        nohup chromium --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
            --remote-debugging-port=9222 --remote-allow-origins=* \
            --user-data-dir="$CHROME_DIR" --no-first-run \
            > /var/log/chrome-tfg.log 2>&1 &
        echo "[INFO] Chromium 调试实例已启动 (CDP 9222)"
        # 等待 CDP 端口就绪，确保网关启动时即已连接浏览器
        for _i in $(seq 1 30); do
            if curl -s -m 2 http://127.0.0.1:9222/json/version >/dev/null 2>&1; then break; fi
            sleep 1
        done
    else
        echo "[WARN] 未找到 chromium，Token-Free Gateway 无法连接浏览器（服务仍会启动但无法转发请求）"
    fi
    # 2) 启动网关（优先独立二进制；缺失时回退到 bun 运行源码）
    GW=""
    if [ -x /usr/local/bin/token-free-gateway ]; then
        GW=/usr/local/bin/token-free-gateway
    elif command -v bun >/dev/null 2>&1 && [ -f /opt/token-free-gateway/index.ts ]; then
        GW="bun /opt/token-free-gateway/index.ts"
    fi
    if [ -n "$GW" ]; then
        export TFG_PORT TFG_CDP_URL
        export TFG_API_KEY="${TFG_API_KEY:-}"
        nohup $GW serve > /var/log/token-free-gateway.log 2>&1 &
        echo "[INFO] Token-Free Gateway 已启动: 0.0.0.0:${TFG_PORT} (OpenAI 兼容 /v1，base-url=http://localhost:${TFG_PORT}/v1)"
    else
        echo "[WARN] 未找到 token-free-gateway 二进制/源码，跳过启动"
    fi
else
    echo "[INFO] Token-Free Gateway 未启用（ENABLE_TOKEN_FREE_GATEWAY!=1）"
fi

# =========================== ⑥.⑤ 注入浏览器端 crypto.randomUUID polyfill ===========================
# 当页面以 http://局域网IP 形式访问时，浏览器处于“非安全上下文”，不暴露
# crypto.randomUUID（与 crypto.subtle 一同被禁用），导致 Web 端「加载提供方目录」
# 等操作报 "crypto.randomUUID is not a function"。
# 这里向构建产物 apps/web/dist 注入一段浏览器端 polyfill（用可用的
# crypto.getRandomValues 兜底），每次容器启动都执行且幂等（已注入则跳过），
# 因此镜像重建（web 重新打包）后依然生效，无需开启 HTTPS。
inject_browser_polyfill() {
  local root="/opt/deepseek-harness"
  local dist="$root/apps/web/dist"
  [ -d "$dist" ] || { echo "[WARN] 未找到 $dist，跳过浏览器 polyfill 注入"; return; }
  node - "$dist" <<'NODE'
const fs=require('fs'),path=require('path');
const dist=process.argv[2];
const MARK='dsh-browser-polyfill';
const POLY="(function(){try{if(typeof globalThis!=='undefined'&&globalThis.crypto&&!globalThis.crypto.randomUUID){var c=globalThis.crypto;var h=[];for(var i=0;i<256;i++){h[i]=(i+256).toString(16).slice(1);}c.randomUUID=function(){var b=new Uint8Array(16);c.getRandomValues(b);b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;return h[b[0]]+h[b[1]]+h[b[2]]+h[b[3]]+'-'+h[b[4]]+h[b[5]]+'-'+h[b[6]]+h[b[7]]+'-'+h[b[8]]+h[b[9]]+'-'+h[b[10]]+h[b[11]]+h[b[12]]+h[b[13]]+h[b[14]]+h[b[15]];};}}catch(e){if(typeof console!=='undefined'&&console.warn)console.warn('[dsh-browser-polyfill]',e);}})();";
const idx=path.join(dist,'index.html');
if(fs.existsSync(idx)){
  let html=fs.readFileSync(idx,'utf8');
  if(!html.includes(MARK)){
    const m=/<head(?:\s[^>]*)?>/i.exec(html);
    const inj=m[0]+"\n<script>"+POLY+"</script><!-- "+MARK+" -->";
    html=html.slice(0,m.index)+inj+html.slice(m.index+m[0].length);
    fs.writeFileSync(idx,html);
    console.log('[INFO] 浏览器 polyfill 已注入 index.html');
  } else { console.log('[INFO] index.html 已含 polyfill，跳过'); }
}
const adir=path.join(dist,'assets');
if(fs.existsSync(adir)){
  for(const f of fs.readdirSync(adir)){
    if(!/^index-.*\.js$/.test(f))continue;
    const p=path.join(adir,f);
    let body=fs.readFileSync(p,'utf8');
    if(body.includes(MARK))continue;
    body+="\n/* "+MARK+" */\ntry{if(typeof globalThis!=='undefined'&&globalThis.crypto&&!globalThis.crypto.randomUUID){var __c=globalThis.crypto;var __h=[];for(var __i=0;__i<256;__i++){__h[__i]=(__i+256).toString(16).slice(1);}__c.randomUUID=function(){var __b=new Uint8Array(16);__c.getRandomValues(__b);__b[6]=(__b[6]&15)|64;__b[8]=(__b[8]&63)|128;return __h[__b[0]]+__h[__b[1]]+__h[__b[2]]+__h[__b[3]]+'-'+__h[__b[4]]+__h[__b[5]]+'-'+__h[__b[6]]+__h[__b[7]]+'-'+__h[__b[8]]+__h[__b[9]]+'-'+__h[__b[10]]+__h[__b[11]]+__h[__b[12]]+__h[__b[13]]+__h[__b[14]]+__h[__b[15]];};}}catch(e){}\n";
    fs.writeFileSync(p,body);
    console.log('[INFO] 浏览器 polyfill 已注入 '+f);
  }
}
NODE
}
inject_browser_polyfill

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

# =========================== ⑥.④ 启动管理端口（16688） ===========================
# 在线管理界面：首次随机凭据 + 强制改密，可修改 OpenClaw / Hermes 的令牌、模型、API Key
# 并热重启对应服务。凭据见 /root/.dsh/MGMT_CREDENTIALS.txt 与容器日志。
MGMT_PORT="${MGMT_PORT:-16688}"
if [ -f /opt/mgmt/mgmt.py ]; then
    export MGMT_PORT
    nohup /usr/local/lib/hermes-agent/venv/bin/python /opt/mgmt/mgmt.py > /var/log/mgmt.log 2>&1 &
    echo "[INFO] 管理端口已启动: 0.0.0.0:${MGMT_PORT} (首次随机凭据见 /root/.dsh/MGMT_CREDENTIALS.txt 与容器日志)"
fi

echo "[INFO] 启动 DeepSeek Harness on ${WEB_HOST}:${WEB_PORT} (trusted: $WEB_TRUSTED_HOSTS)..."
exec pnpm dsh web --host "$WEB_HOST" --port "$WEB_PORT" --no-open $TRUSTED_ARGS
