#!/usr/bin/env bash
# Docker HEALTHCHECK：聚合健康接口可达 + status.json 无 down 服务
set -euo pipefail

# nginx 主入口可达
curl -fsSk https://127.0.0.1/healthz -o /dev/null --max-time 3

# status.json 存在且没有 down 的服务（aggregator 每 15s 刷新）
if [ -f /var/www/html/status.json ]; then
  if grep -q '"status": *"down"' /var/www/html/status.json; then
    echo "[healthcheck] 存在 down 服务" >&2
    exit 1
  fi
fi
exit 0
