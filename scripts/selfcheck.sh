#!/usr/bin/env bash
# 启动自检（后台运行，不阻塞启动）：
#   1) 等待 nginx 与各服务就绪
#   2) 路径模式下抓取 DSH 页面，扫描 sub_filter 残留绝对路径
#   3) 结果写 /var/www/html/selfcheck.json（aggregator 合并进 status.json）
set -uo pipefail
log() { echo "[selfcheck] $*"; }

OUT=/var/www/html/selfcheck.json
[ -f /etc/aio/enabled.env ] && . /etc/aio/enabled.env

# ---- 1. 等待 nginx 就绪（最多 90s）----
for i in $(seq 1 30); do
  curl -fsSk https://127.0.0.1/healthz -o /dev/null --max-time 2 && break
  sleep 3
done

# ---- 2. 各服务探活报告 ----
residue=false
residue_detail=""
report=""
for svc in ${ENABLED_SERVICES:-}; do
  case "$svc" in
    dsh) port=3080 ;; openclaw) port=18789 ;; hermes) port=6060 ;; admin) port=34567 ;;
  esac
  for i in $(seq 1 20); do
    code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 \
           "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)
    [ "$code" -lt 500 ] && break
    sleep 3
  done
  log "$svc (127.0.0.1:$port) → HTTP $code"
  report="$report $svc=$code"
done

# ---- 3. DSH sub_filter 残留扫描（仅路径模式且启用 DSH）----
if [ "${ACCESS_MODE:-}" = "path" ] && [[ " ${ENABLED_SERVICES:-} " == *" dsh "* ]]; then
  html=$(curl -fsSk --max-time 10 "https://127.0.0.1/dsh/" 2>/dev/null || true)
  # 命中未被改写的绝对路径引用（引号/模板字符串开头）
  hits=$(printf '%s' "$html" | grep -oE '["'"'"'`]/(api|static|ws)/[^"'"'"'` ]*' | sort -u || true)
  if [ -n "$hits" ]; then
    residue=true
    residue_detail=$(printf '%s' "$hits" | head -5 | tr '\n' ' ')
    log "WARN: DSH 页面存在未替换的绝对路径: $residue_detail"
    log "WARN: 请增补 conf/nginx/snippets/sub-filter-dsh.conf 规则，或改用子域名模式"
  else
    log "DSH sub_filter 残留扫描通过"
  fi
fi

# ---- 4. 写结果（供 status.json 合并与导航页展示）----
cat > "$OUT" <<EOF
{
  "probes": "$(echo "$report" | xargs)",
  "sub_filter_residue": ${residue},
  "residue_detail": "${residue_detail}",
  "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
log "自检完成"
