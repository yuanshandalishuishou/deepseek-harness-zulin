#!/usr/bin/env bash
# =========================================================================
# 配置渲染：模板（/etc/aio/conf）→ 运行时配置
# 关键: envsubst 使用显式变量白名单，避免误替换 Nginx 自身的 $host 等变量
# =========================================================================
set -euo pipefail

AIO="${AIO_HOME:-/etc/aio}"
NGX="${NGX_HOME:-/etc/nginx}"
SUP_CONFD="${SUP_CONFD:-/etc/supervisor/conf.d}"
WWW="${WWW_ROOT:-/var/www/html}"
log() { echo "[render] $*"; }

# envsubst 白名单：模板中只允许出现这些占位变量
SUBST='${DOMAIN} ${HOST_IP} ${PROXY_READ_TIMEOUT} ${OPENCLAW_BASEPATH} ${TLS_CERT_PATH} ${TLS_KEY_PATH} ${LOG_LEVEL} ${DEEPSEEK_API_KEY} ${DSH_COMMAND} ${OPENCLAW_COMMAND} ${HERMES_COMMAND} ${ADMIN_COMMAND} ${GATEWAY_IP}'

# 端口网关监听地址：容器主 IP（而非 0.0.0.0）。
# 关键原因: 业务服务绑 127.0.0.1:PORT，若网关绑 0.0.0.0:PORT，Linux 下
# 特定地址再绑同端口会 EADDRINUSE，服务重启永远无法恢复（CI 实测复现）。
# 网关只绑主 IP 即可两全: docker -p 的 DNAT 指向容器 IP，外部可达；
# 127.0.0.1:PORT 留给业务服务与内部探活。
GATEWAY_IP="${GATEWAY_IP:-$(hostname -i 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -1 || true)}"
if [ -z "$GATEWAY_IP" ]; then
  GATEWAY_IP="0.0.0.0"
  log "[WARN] 无法解析容器主 IP，网关回退 0.0.0.0（与业务服务存在端口竞争风险）"
fi
export GATEWAY_IP   # envsubst 只读进程环境变量，必须导出（本地 shell 变量不可见）

# ---- 服务清单与端口映射 ----
svc_port() {
  case "$1" in
    dsh)      echo 3080  ;;
    openclaw) echo 18789 ;;
    hermes)   echo 6060  ;;
    admin)    echo 34567 ;;
  esac
}
svc_enabled() {  # svc_enabled dsh → 0/1
  local var="ENABLE_$(echo "$1" | tr 'a-z' 'A-Z')"
  [ "${!var}" = "true" ]
}
port_enabled() { # port_enabled dsh → 0/1
  local var="ENABLE_$(echo "$1" | tr 'a-z' 'A-Z')_PORT"
  [ "${!var}" = "true" ]
}

ENABLED_SERVICES=""
for svc in dsh openclaw hermes admin; do
  svc_enabled "$svc" && ENABLED_SERVICES="$ENABLED_SERVICES $svc"
done
ENABLED_SERVICES="${ENABLED_SERVICES# }"
log "启用的服务: ${ENABLED_SERVICES:-（无）}"

# ---- 1. nginx 主配置 ----
envsubst "$SUBST" < "$AIO/conf/nginx/nginx.conf.template" > "$NGX/nginx.conf"

# ---- 2. 清理并重建 conf.d ----
rm -rf "$NGX/conf.d"
mkdir -p "$NGX/conf.d/services" "$NGX/conf.d/gateways" "$NGX/snippets"

# ---- 3. 静态片段（无变量，直接拷贝）----
cp "$AIO/conf/nginx/snippets/proxy-headers.conf" "$NGX/snippets/"
cp "$AIO/conf/nginx/snippets/ws.conf"            "$NGX/snippets/"
cp "$AIO/conf/nginx/snippets/sub-filter-dsh.conf" "$NGX/snippets/"

# ---- 4. IP 白名单片段（由 ALLOWED_IPS 逐条生成）----
: > "$NGX/snippets/allowed-ips.conf"
if [ -n "$ALLOWED_IPS" ]; then
  IFS=',' read -ra CIDRS <<< "$ALLOWED_IPS"
  for c in "${CIDRS[@]}"; do
    echo "allow $(echo "$c" | xargs);" >> "$NGX/snippets/allowed-ips.conf"
  done
  echo "deny all;" >> "$NGX/snippets/allowed-ips.conf"
  log "IP 白名单: $ALLOWED_IPS"
else
  echo "[render][WARN] ALLOWED_IPS 为空，管理口/端口网关对所有来源开放" >&2
fi

# ---- 5. 80 端口 server（ACME 挑战 + 跳 HTTPS）----
envsubst "$SUBST" < "$AIO/conf/nginx/servers/http-80.conf.template" \
  > "$NGX/conf.d/00-http-80.conf"

# ---- 6. 主入口 server（按 ACCESS_MODE）----
envsubst "$SUBST" < "$AIO/conf/nginx/modes/main-${ACCESS_MODE}.conf.template" \
  > "$NGX/conf.d/10-main.conf"

# ---- 7. 各服务配置（path=location 块 / subdomain=server 块）----
for svc in $ENABLED_SERVICES; do
  envsubst "$SUBST" < "$AIO/conf/nginx/services/${ACCESS_MODE}/${svc}.conf.template" \
    > "$NGX/conf.d/services/${svc}.conf"
done

# ---- 8. 端口网关（按 ENABLE_*_PORT）----
for svc in dsh openclaw hermes admin; do
  if svc_enabled "$svc" && port_enabled "$svc"; then
    envsubst "$SUBST" < "$AIO/conf/nginx/gateways/${svc}.conf.template" \
      > "$NGX/conf.d/gateways/${svc}.conf"
    log "端口网关: $svc → ${GATEWAY_IP}:$(svc_port "$svc")"
  fi
done

# ---- 9. Supervisor 服务程序配置 ----
mkdir -p "$SUP_CONFD"
rm -f "$SUP_CONFD"/svc-*.conf
for svc in $ENABLED_SERVICES; do
  envsubst "$SUBST" < "$AIO/conf/supervisor/${svc}.conf.template" \
    > "$SUP_CONFD/svc-${svc}.conf"
done

# ---- 10. 导航页与模式描述文件 ----
mkdir -p "$WWW"
envsubst "$SUBST" < "$AIO/www/index.html.template" > "$WWW/index.html"

# mode.json：导航页 JS 据此渲染卡片与入口链接
{
  printf '{\n  "mode": "%s",\n  "domain": "%s",\n  "host_ip": "%s",\n  "services": [\n' \
    "$ACCESS_MODE" "$DOMAIN" "$HOST_IP"
  first=true
  for svc in $ENABLED_SERVICES; do
    $first || printf ',\n'
    first=false
    p=$(svc_port "$svc")
    pe=false; port_enabled "$svc" && pe=true
    printf '    {"name": "%s", "port": %s, "port_enabled": %s}' "$svc" "$p" "$pe"
  done
  printf '\n  ]\n}\n'
} > "$WWW/mode.json"

# ---- 11. enabled.env：供 aggregator/selfcheck 等脚本读取 ----
cat > "$AIO/enabled.env" <<EOF
ENABLED_SERVICES="$ENABLED_SERVICES"
ACCESS_MODE="$ACCESS_MODE"
DOMAIN="$DOMAIN"
HOST_IP="$HOST_IP"
EOF

log "渲染完成（模式: $ACCESS_MODE）"
