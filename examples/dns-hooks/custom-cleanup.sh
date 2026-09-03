#!/usr/bin/env bash
# =========================================================================
# 自定义 DNS-01 cleanup hook 模板（与 custom-auth.sh 配对）
# 挂载到容器: /etc/aio/dns-hooks/custom-cleanup.sh（需可执行权限）
#
# 任务: 删除 auth 阶段创建的 TXT 记录 _acme-challenge.<域名>。
# =========================================================================
set -euo pipefail

DOMAIN="${CERTBOT_DOMAIN#*.}"
echo "[custom-dns] 删除 _acme-challenge.${DOMAIN} 的 TXT 记录"

# TODO: 调用你的 DNS 提供商 API 删除对应 TXT 记录，例如:
# curl -fsS -X DELETE "https://dns.example.com/api/records" \
#   -H "Authorization: Bearer ${MY_DNS_TOKEN}" \
#   -d "{\"name\":\"_acme-challenge.${DOMAIN}\",\"type\":\"TXT\",\"content\":\"${CERTBOT_VALIDATION}\"}"
