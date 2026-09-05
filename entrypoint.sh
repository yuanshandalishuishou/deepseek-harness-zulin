#!/usr/bin/env bash
# =========================================================================
# 一体化平台 Entrypoint（幂等，可重复执行）
# 流程: 校验env → 展开secrets → 初始化卷 → 鉴权 → SSH → 证书
#       → 渲染配置 → nginx -t → 后台自检 → exec supervisord
# =========================================================================
set -euo pipefail

AIO=/etc/aio
log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint][WARN] $*" >&2; }
die()  { echo "[entrypoint][FATAL] $*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. 默认值
export ACCESS_MODE="${ACCESS_MODE:-path}"
export DOMAIN="${DOMAIN:-localhost}"
export PROXY_READ_TIMEOUT="${PROXY_READ_TIMEOUT:-600}"
export PUID="${PUID:-1000}"
export PGID="${PGID:-1000}"
export TZ="${TZ:-Asia/Shanghai}"
export LOG_LEVEL="${LOG_LEVEL:-info}"
export DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"
export ENABLE_DSH="${ENABLE_DSH:-true}"
export ENABLE_OPENCLAW="${ENABLE_OPENCLAW:-true}"
export ENABLE_HERMES="${ENABLE_HERMES:-true}"
export ENABLE_ADMIN="${ENABLE_ADMIN:-true}"
export ENABLE_DSH_PORT="${ENABLE_DSH_PORT:-false}"
export ENABLE_OPENCLAW_PORT="${ENABLE_OPENCLAW_PORT:-false}"
export ENABLE_HERMES_PORT="${ENABLE_HERMES_PORT:-false}"
export ENABLE_ADMIN_PORT="${ENABLE_ADMIN_PORT:-false}"
export ENABLE_SSH="${ENABLE_SSH:-false}"
export SSH_PORT="${SSH_PORT:-22}"
export SSH_USER="${SSH_USER:-aioadm}"
export ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-false}"
export FAIL2BAN_BANTIME="${FAIL2BAN_BANTIME:-1h}"
export FAIL2BAN_FINDTIME="${FAIL2BAN_FINDTIME:-10m}"
export FAIL2BAN_MAXRETRY="${FAIL2BAN_MAXRETRY:-5}"
export ACME_STAGING="${ACME_STAGING:-true}"
export ADMIN_USER="${ADMIN_USER:-admin}"
export ALLOWED_IPS="${ALLOWED_IPS:-}"

[[ "$ACCESS_MODE" =~ ^(path|subdomain)$ ]] || die "ACCESS_MODE 仅支持 path|subdomain"

# ------------------------------------------------- 2. 展开 *_FILE secrets
# 约定: XXX_FILE=/run/secrets/yyy 时，将文件内容读入 XXX
expand_file_vars() {
  local var file_var
  for var in $(compgen -e); do
    [[ "$var" =~ _FILE$ ]] || continue
    file_var="${var%_FILE}"
    [[ -f "${!var}" ]] || die "secret 文件不存在: ${!var} (来自 $var)"
    export "$file_var"="$(cat "${!var}")"
  done
}
expand_file_vars

# ------------------------------------ 2b. 服务启动命令（可配置 CLI）
# STUB_MODE 构建的镜像自带 stub 默认命令（见 Dockerfile），环境变量优先级最高
[ -f /etc/aio/stub-defaults.env ] && . /etc/aio/stub-defaults.env
# 默认启动命令 = 真实上游(仅 STUB_MODE=false 时 stub-defaults.env 不存在才生效)。
# 指向 run-<svc>.sh 启动器(脚本内 cd 到产物子目录 + exec 真实服务), 避免 supervisor
# command 内嵌引号/cd&& 的 shell 解析陷阱。数据目录 /data/<svc> 由 init-volumes chown 给各用户。
# 注: 真实命令为方向性默认, 精确 flag 在真实构建 workflow 中按上游版本校准。
export DSH_COMMAND="${DSH_COMMAND:-/etc/aio/scripts/run-dsh.sh}"
export OPENCLAW_COMMAND="${OPENCLAW_COMMAND:-/etc/aio/scripts/run-openclaw.sh}"
export HERMES_COMMAND="${HERMES_COMMAND:-/etc/aio/scripts/run-hermes.sh}"
# Admin 为内置管理面板(stub_server.py 提供导航/状态), 恒不由外部 repo 驱动
export ADMIN_COMMAND="${ADMIN_COMMAND:-python3 /opt/admin/stub_server.py 34567 admin}"
log "DSH_COMMAND      = $DSH_COMMAND"
log "OPENCLAW_COMMAND = $OPENCLAW_COMMAND"
log "HERMES_COMMAND   = $HERMES_COMMAND"
log "ADMIN_COMMAND    = $ADMIN_COMMAND"

# HOST_IP 自动探测兜底
if [ -z "${HOST_IP:-}" ]; then
  HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  export HOST_IP="${HOST_IP:-localhost}"
  log "HOST_IP 未设置，自动探测为: $HOST_IP"
fi

# ------------------------------------------------- 3. 校验必填项（fail fast）
need_auth=false
[ "$ENABLE_ADMIN" = "true" ] && need_auth=true
for v in ENABLE_DSH_PORT ENABLE_OPENCLAW_PORT ENABLE_HERMES_PORT ENABLE_ADMIN_PORT; do
  [ "${!v}" = "true" ] && need_auth=true
done
if $need_auth && [ -z "${ADMIN_PASSWORD:-}" ]; then
  die "管理口/端口网关已启用，但 ADMIN_PASSWORD(_FILE) 未设置"
fi
if [ "$ENABLE_SSH" = "true" ] && [ -z "${SSH_AUTHORIZED_KEYS:-}" ]; then
  die "ENABLE_SSH=true 时必须提供 SSH_AUTHORIZED_KEYS(_FILE)"
fi

# ------------------------------------------------- 4. 初始化卷目录与权限
"$AIO/scripts/init-volumes.sh"

# ------------------------------------------------- 5. 生成 htpasswd
if $need_auth; then
  printf '%s:%s\n' "$ADMIN_USER" "$(openssl passwd -apr1 "$ADMIN_PASSWORD")" \
    > /etc/nginx/.htpasswd
  # nginx worker 以 www-data 运行，必须能读取凭据文件（否则带凭据请求 500）
  chgrp www-data /etc/nginx/.htpasswd
  chmod 640 /etc/nginx/.htpasswd
  log "已生成 basic auth 凭据（用户: $ADMIN_USER）"
fi

# ------------------------------------------------- 6. SSH（保留项，加固）
SSHD_CONF=/etc/supervisor/conf.d/sshd.conf
rm -f "$SSHD_CONF"
if [ "$ENABLE_SSH" = "true" ]; then
  mkdir -p /etc/ssh/keys /run/sshd
  # host key 持久化（容器重建指纹不变）
  [ -f /etc/ssh/keys/ssh_host_ed25519_key ] || \
    ssh-keygen -t ed25519 -f /etc/ssh/keys/ssh_host_ed25519_key -N "" -q
  [ -f /etc/ssh/keys/ssh_host_rsa_key ] || \
    ssh-keygen -t rsa -b 3072 -f /etc/ssh/keys/ssh_host_rsa_key -N "" -q
  chmod 600 /etc/ssh/keys/*
  # 加固配置：仅密钥、禁 root、限定用户
  cat > /etc/ssh/sshd_config.d/99-aio.conf <<EOF
Port ${SSH_PORT}
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
AllowUsers ${SSH_USER}
HostKey /etc/ssh/keys/ssh_host_ed25519_key
HostKey /etc/ssh/keys/ssh_host_rsa_key
EOF
  # 登录用户与公钥
  id "$SSH_USER" &>/dev/null || useradd -m -s /bin/bash "$SSH_USER"
  install -d -m 700 -o "$SSH_USER" -g "$SSH_USER" "/home/$SSH_USER/.ssh"
  echo "$SSH_AUTHORIZED_KEYS" > "/home/$SSH_USER/.ssh/authorized_keys"
  chmod 600 "/home/$SSH_USER/.ssh/authorized_keys"
  chown "$SSH_USER:$SSH_USER" "/home/$SSH_USER/.ssh/authorized_keys"
  # 注册到 supervisor（日志写文件，fail2ban 据此审计；docker logs 不再含 sshd 输出）
  cat > "$SSHD_CONF" <<'EOF'
[program:sshd]
command=/usr/sbin/sshd -D -e
priority=30
autorestart=true
stdout_logfile=/var/log/sshd.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=2
redirect_stderr=true
EOF
  log "SSH 已启用（用户: $SSH_USER，端口: $SSH_PORT，仅密钥登录）"
  [ "$ENABLE_FAIL2BAN" = "true" ] || \
    warn "SSH 已暴露但 ENABLE_FAIL2BAN=false，建议开启防爆破（需 --cap-add NET_ADMIN）"
fi

# ------------------------------------------------- 7. 证书解析与首次签发
resolve_certs() {
  if [ -n "${TLS_CERT_FILE:-}" ] && [ -n "${TLS_KEY_FILE:-}" ]; then
    export TLS_CERT_PATH="$TLS_CERT_FILE" TLS_KEY_PATH="$TLS_KEY_FILE"
    log "使用外部挂载证书"
  elif [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    export TLS_CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    export TLS_KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    log "使用 Let's Encrypt 证书（$DOMAIN）"
  else
    mkdir -p /data/certs
    if [ ! -f /data/certs/fullchain.pem ]; then
      openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -keyout /data/certs/privkey.pem -out /data/certs/fullchain.pem \
        -subj "/CN=$DOMAIN" 2>/dev/null
      warn "已生成自签证书兜底（生产请配置 ACME_EMAIL 或挂载证书）"
    fi
    export TLS_CERT_PATH=/data/certs/fullchain.pem TLS_KEY_PATH=/data/certs/privkey.pem
  fi
}
resolve_certs

# OpenClaw basepath：路径模式下服务感知前缀，其余模式为根
if [ "$ACCESS_MODE" = "path" ]; then
  export OPENCLAW_BASEPATH=/openclaw
else
  export OPENCLAW_BASEPATH=
fi

# ------------------------------------------------- 8. 渲染全部配置
"$AIO/scripts/render-config.sh"

# ACME 首次签发（standalone，此时 nginx 未启动、80 端口空闲）
if [ -n "${ACME_EMAIL:-}" ] && [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  if "$AIO/scripts/cert-issue.sh"; then
    resolve_certs                       # 证书路径可能已变化
    "$AIO/scripts/render-config.sh"     # 用真实证书重新渲染
  else
    warn "ACME 首次签发失败，继续使用自签证书（可重启容器重试）"
  fi
fi

# ------------------------------------------------- 9. 渲染结果校验
nginx -t || die "Nginx 配置校验失败，拒绝启动"

# ------------------------------------------------- 10. 后台自检 + 启动
"$AIO/scripts/selfcheck.sh" &
log "启动 supervisord ..."
# 注意: 必须指向项目自带配置（含 nodaemon 与 program 段落），
#       -n 显式前台运行双保险；若误用 Debian 默认配置会守护化导致容器退出
exec /usr/bin/supervisord -n -c "$AIO/conf/supervisor/supervisord.conf"
