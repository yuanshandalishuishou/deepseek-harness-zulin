#!/usr/bin/env bash
# =========================================================================
# 自定义 DNS-01 auth hook 模板（ACME_DNS_PROVIDER=custom 时使用）
# 挂载到容器: /etc/aio/dns-hooks/custom-auth.sh（需可执行权限）
#
# certbot 注入的环境变量:
#   CERTBOT_DOMAIN      待验证域名（可能是 *.example.com，注意去前缀）
#   CERTBOT_VALIDATION  TXT 记录值
#   CERTBOT_TOKEN       挑战 token（一般不用）
#
# 任务: 在 DNS 提供商处创建 TXT 记录 _acme-challenge.<域名>，
#       并等待解析生效（sleep 或轮询公共 DNS 查询）。
# =========================================================================
set -euo pipefail

DOMAIN="${CERTBOT_DOMAIN#*.}"   # 去掉通配符前缀
echo "[custom-dns] 为 _acme-challenge.${DOMAIN} 创建 TXT: ${CERTBOT_VALIDATION}"

# TODO: 调用你的 DNS 提供商 API 创建 TXT 记录，例如:
# curl -fsS -X POST "https://dns.example.com/api/records" \
#   -H "Authorization: Bearer ${MY_DNS_TOKEN}" \
#   -d "{\"name\":\"_acme-challenge.${DOMAIN}\",\"type\":\"TXT\",\"content\":\"${CERTBOT_VALIDATION}\"}"

sleep "${DNS_PROPAGATION_SECONDS:-40}"
