#!/usr/bin/env bash
# =========================================================================
# 真实构建冒烟测试（B-2）
#
# 与 stub 冒烟(smoke-test.sh)不同：本脚本不校验"桩行为"(SSE 改写/WS/sub_filter)，
# 而是验证【被指定为真实构建】的上游确实能起来并监听预期端口——即证明
#   Dockerfile build-* 阶段产物布局 + supervisor 模板 + run-*.sh 命令 三者一致。
#
# 用法:
#   real-smoke-test.sh <container> [svc ...]
#   svc ∈ dsh | openclaw | hermes   （仅列出本次以真实模式构建的服务）
# 示例:
#   real-smoke-test.sh aio-ci dsh            # 仅 DSH 为真实构建
#   real-smoke-test.sh aio-ci dsh openclaw   # DSH + OpenClaw 为真实构建
#
# 未列出的服务(如仍是桩)不被断言——避免把"桩正常"误判为"真实服务正常"。
# =========================================================================
set -uo pipefail

CONTAINER="${1:-aio-ci}"
shift || true

# 期望为真实构建的服务（来自命令行）
REAL_SVCS=("$@")
if [ ${#REAL_SVCS[@]} -eq 0 ]; then
  REAL_SVCS=(dsh openclaw hermes)   # 兜底：全断言
fi

PORT_MAP=( [dsh]=3080 [openclaw]=18789 [hermes]=6060 [admin]=34567 )
PROG_MAP=( [dsh]=dsh [openclaw]=openclaw [hermes]=hermes [admin]=admin )

log()  { echo "[real-smoke] $*"; }
warn() { echo "[real-smoke][WARN] $*" >&2; }

# 容器内执行（失败不退出脚本，由我们判断）
dexec() { docker exec "$CONTAINER" "$@"; }

# ---------- 0. 容器基础健康检查（nginx） ----------
log "等待 nginx 健康(healthz)…"
for i in $(seq 1 30); do
  code=$(dexec curl -ksS -o /dev/null -w '%{http_code}' https://127.0.0.1/healthz 2>/dev/null || echo 000)
  [ "$code" = "200" ] && { log "  healthz -> 200 OK"; break; }
  [ "$i" -eq 30 ] && { warn "  healthz 未在 150s 内返回 200 (最后=$code)"; }
  sleep 5
done

# ---------- 1. 逐服务：supervisor RUNNING + 端口监听 ----------
FAIL=0
for svc in "${REAL_SVCS[@]}"; do
  port=${PORT_MAP[$svc]:-0}
  prog=${PROG_MAP[$svc]:-$svc}
  log "==== 校验真实服务: $svc (supervisor=$prog, 端口=$port) ===="

  # 1a. supervisor 状态达到 RUNNING（最多 ~4 分钟）
  up=false
  for i in $(seq 1 48); do
    st=$(dexec supervisorctl status "$prog" 2>/dev/null | awk '{print $2}' | head -1)
    if [ "$st" = "RUNNING" ]; then up=true; break; fi
    # BACKOFF/EXITED 说明启动即崩——仍需给重试时间，但记录
    if [ "$st" = "EXITED" ] || [ "$st" = "FATAL" ]; then
      warn "  $prog 状态=$st (启动失败?) @${i}"; fi
    sleep 5
  done
  if ! $up; then
    warn "  $prog 未在 4 分钟内达到 RUNNING"
    dexec bash -c "tail -40 /var/log/supervisor/${prog}.log 2>/dev/null" || true
    FAIL=1; continue
  fi
  log "  supervisor $prog -> RUNNING"

  # 1b. 端口在 127.0.0.1 上监听（最多 ~1 分钟）
  listening=false
  for i in $(seq 1 12); do
    # curl 能拿到任意 HTTP 响应(2xx/3xx/401/404)即视为端口已起
    if dexec curl -sS --max-time 4 -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null; then
      listening=true; break
    fi
    sleep 5
  done
  if ! $listening; then
    warn "  $svc 端口 $port 在 127.0.0.1 上未监听(连接被拒/超时)"
    dexec bash -c "tail -40 /var/log/supervisor/${prog}.log 2>/dev/null" || true
    FAIL=1; continue
  fi
  log "  端口 $port -> LISTENING (127.0.0.1)"
done

# ---------- 2. 汇总 ----------
echo
log "===== 真实构建冒烟结果 ====="
if [ "$FAIL" -eq 0 ]; then
  log "全部指定真实服务( ${REAL_SVCS[*]} )均 RUNNING 且端口监听 —— 真实构建链路验证通过"
  exit 0
else
  warn "存在未达预期的真实服务，详情见上方 [WARN]。"
  exit 1
fi
