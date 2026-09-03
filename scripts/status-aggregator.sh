#!/usr/bin/env bash
# 状态聚合器：每 15s 探活各启用服务，写 /var/www/html/status.json
# 导航页状态灯与 /healthz 均消费该文件
set -uo pipefail

OUT=/var/www/html/status.json
INTERVAL="${STATUS_INTERVAL:-15}"

svc_port() {
  case "$1" in
    dsh)      echo 3080  ;;
    openclaw) echo 18789 ;;
    hermes)   echo 6060  ;;
    admin)    echo 34567 ;;
  esac
}

probe() {  # probe <svc> → up|down（HTTP < 500 视为存活）
  local port code
  port=$(svc_port "$1")
  code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 \
         "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)
  [ "$code" -lt 500 ] && echo up || echo down
}

echo "[aggregator] 启动，间隔 ${INTERVAL}s"
while true; do
  [ -f /etc/aio/enabled.env ] && . /etc/aio/enabled.env
  tmp="${OUT}.tmp"
  {
    printf '{\n  "ts": "%s",\n  "mode": "%s",\n  "services": {\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ACCESS_MODE:-unknown}"
    first=true
    for svc in ${ENABLED_SERVICES:-}; do
      st=$(probe "$svc")
      $first || printf ',\n'
      first=false
      printf '    "%s": {"status": "%s", "port": %s}' "$svc" "$st" "$(svc_port "$svc")"
    done
    # selfcheck 写入的附加字段（如 sub_filter_residue）合并保留
    if [ -f /var/www/html/selfcheck.json ]; then
      if [ -n "${ENABLED_SERVICES:-}" ]; then printf ',\n'; else printf '\n'; fi
      printf '  "selfcheck": '
      cat /var/www/html/selfcheck.json
      printf '\n'
    else
      printf '\n'
    fi
    printf '}\n'
  } > "$tmp"
  mv "$tmp" "$OUT"
  sleep "$INTERVAL"
done
