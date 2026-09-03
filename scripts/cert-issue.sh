#!/usr/bin/env bash
# =========================================================================
# ACME 首次签发 + 续期 cron 配置
#
# ACME_DNS_PROVIDER 取值:
#   （空）         HTTP-01 standalone 首发，renewal 改写为 webroot
#   cloudflare    certbot-dns-cloudflare 插件（CF_DNS_API_TOKEN）
#   route53       certbot-dns-route53 插件（AWS_ACCESS_KEY_ID / SECRET）
#   google        certbot-dns-google 插件（GOOGLE_APPLICATION_CREDENTIALS(_FILE)）
#   digitalocean  certbot-dns-digitalocean 插件（DO_DNS_TOKEN）
#   dnspod        内置 manual hook（DNSPOD_TOKEN，格式 "ID,TOKEN"）
#   aliyun        内置 manual hook（ALIYUN_ACCESS_KEY_ID / SECRET）
#   custom        用户挂载 /etc/aio/dns-hooks/custom-auth.sh 与 custom-cleanup.sh
# =========================================================================
set -uo pipefail
log() { echo "[cert] $*"; }

staging_flag=""
[ "${ACME_STAGING:-true}" = "true" ] && staging_flag="--staging"

# 子域名模式推荐泛域名: *.<DOMAIN> + 裸域
domains="-d $DOMAIN"
[ "${ACCESS_MODE:-path}" = "subdomain" ] && domains="-d $DOMAIN -d *.$DOMAIN"

PROVIDER="${ACME_DNS_PROVIDER:-}"
HOOK_DIR=/etc/aio/scripts/dns-hooks

issue_with_plugin() {  # issue_with_plugin <plugin-args...>
  certbot certonly --non-interactive --agree-tos -m "$ACME_EMAIL" $staging_flag \
    "$@" $domains 2>&1 | tail -2
}

issue_with_hooks() {   # issue_with_hooks <auth-cmd> <cleanup-cmd>
  certbot certonly --non-interactive --agree-tos -m "$ACME_EMAIL" $staging_flag \
    --manual --preferred-challenges dns \
    --manual-auth-hook "$1" --manual-cleanup-hook "$2" \
    --manual-public-ip-logging-ok \
    $domains 2>&1 | tail -2
}

creds_file() {  # 生成 600 权限临时凭据文件，打印路径
  local f; f=$(mktemp); chmod 600 "$f"; cat > "$f"; echo "$f"
}

case "$PROVIDER" in
  "")
    issue_with_plugin --standalone
    ;;
  cloudflare)
    [ -n "${CF_DNS_API_TOKEN:-}" ] || { log "ERROR: 缺 CF_DNS_API_TOKEN(_FILE)"; exit 1; }
    f=$(printf 'dns_cloudflare_api_token = %s\n' "$CF_DNS_API_TOKEN" | creds_file)
    issue_with_plugin --dns-cloudflare --dns-cloudflare-credentials "$f" \
      --dns-cloudflare-propagation-seconds 30
    rm -f "$f"
    ;;
  route53)
    [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] \
      || { log "ERROR: 缺 AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY(_FILE)"; exit 1; }
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    issue_with_plugin --dns-route53 --dns-route53-propagation-seconds 30
    ;;
  google)
    [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] \
      || { log "ERROR: 缺 GOOGLE_APPLICATION_CREDENTIALS(_FILE)"; exit 1; }
    [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ] \
      || { log "ERROR: 服务账号 JSON 不存在: $GOOGLE_APPLICATION_CREDENTIALS"; exit 1; }
    issue_with_plugin --dns-google \
      --dns-google-credentials "$GOOGLE_APPLICATION_CREDENTIALS" \
      --dns-google-propagation-seconds 30
    ;;
  digitalocean)
    [ -n "${DO_DNS_TOKEN:-}" ] || { log "ERROR: 缺 DO_DNS_TOKEN(_FILE)"; exit 1; }
    f=$(printf 'dns_digitalocean_token = %s\n' "$DO_DNS_TOKEN" | creds_file)
    issue_with_plugin --dns-digitalocean --dns-digitalocean-credentials "$f" \
      --dns-digitalocean-propagation-seconds 60
    rm -f "$f"
    ;;
  dnspod|aliyun)
    issue_with_hooks \
      "python3 $HOOK_DIR/$PROVIDER.py auth" \
      "python3 $HOOK_DIR/$PROVIDER.py cleanup"
    ;;
  custom)
    [ -x /etc/aio/dns-hooks/custom-auth.sh ] && [ -x /etc/aio/dns-hooks/custom-cleanup.sh ] \
      || { log "ERROR: 请挂载可执行的 /etc/aio/dns-hooks/custom-{auth,cleanup}.sh"; exit 1; }
    issue_with_hooks \
      /etc/aio/dns-hooks/custom-auth.sh \
      /etc/aio/dns-hooks/custom-cleanup.sh
    ;;
  *)
    log "ERROR: 未知 ACME_DNS_PROVIDER: $PROVIDER"
    log "支持: cloudflare | route53 | google | digitalocean | dnspod | aliyun | custom"
    exit 1
    ;;
esac

# ---- 签发结果处理 ----
if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  log "签发成功: $DOMAIN（provider: ${PROVIDER:-http-01}）"

  # HTTP-01 场景：renewal 改为 webroot（续期时 nginx 占用 80）
  renewal="/etc/letsencrypt/renewal/$DOMAIN.conf"
  if [ -f "$renewal" ] && grep -q "authenticator = standalone" "$renewal"; then
    sed -i 's/authenticator = standalone/authenticator = webroot/' "$renewal"
    grep -q "webroot_path" "$renewal" || \
      sed -i "/authenticator = webroot/a webroot_path = /var/www/acme,\n[[webroot_map]]\n$DOMAIN = /var/www/acme" "$renewal"
    log "renewal 已切换为 webroot 模式"
  fi

  # 续期 cron：每日两次，成功后 reload nginx
  cat > /etc/cron.d/certbot-renew <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
7 */12 * * * root certbot renew -q --deploy-hook "nginx -s reload" >> /var/log/certbot-renew.log 2>&1
EOF
  chmod 644 /etc/cron.d/certbot-renew
  log "续期 cron 已配置（每日 2 次，deploy-hook 自动 reload）"
  exit 0
else
  log "签发未完成（staging=${ACME_STAGING:-true}）"
  exit 1
fi
