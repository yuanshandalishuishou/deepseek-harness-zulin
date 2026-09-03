#!/usr/bin/env bash
# =========================================================================
# 冒烟测试（对应方案文档 2.16 节清单）
# 在宿主机执行:  bash scripts/smoke-test.sh [容器名] [管理密码]
#   $1 容器名     默认 aio-test
#   $2 管理密码   默认 admin（basic auth / 端口网关验证用）
# 依赖: docker、curl；WS 检查在容器内用 python3 完成（镜像自带）
# =========================================================================
set -uo pipefail

CID="${1:-aio-test}"
PW="${2:-admin}"
BASE=https://localhost
PASS=0; FAIL=0

t() {  # t <名称> <期望> <实际>
  if [ "$2" = "$3" ]; then
    echo "  PASS  $1"; PASS=$((PASS+1))
  else
    echo "  FAIL  $1（期望 $2，实际 $3）"; FAIL=$((FAIL+1))
  fi
}

code() { curl -ksS -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }

echo "== 1. 各路径可达性（path 模式）=="
t "导航页 /            → 200" 200 "$(code $BASE/)"
t "/dsh/               → 200" 200 "$(code $BASE/dsh/)"
t "/openclaw/          → 200" 200 "$(code $BASE/openclaw/)"
t "/hermes/            → 200" 200 "$(code $BASE/hermes/)"
t "/admin/（无凭据）   → 401" 401 "$(code $BASE/admin/)"
t "/admin/（带凭据）   → 200" 200 "$(code -u "admin:$PW" $BASE/admin/)"

echo "== 2. 尾斜杠 301 =="
t "/dsh（无尾斜杠）    → 301" 301 "$(code $BASE/dsh)"
t "  Location 含 /dsh/ " "yes" "$(curl -ksSI $BASE/dsh | grep -qi 'location: .*/dsh/' && echo yes || echo no)"

echo "== 3. sub_filter 残留扫描（DSH 页面与 JS）=="
residue=$(curl -ksS $BASE/dsh/ ; curl -ksS $BASE/dsh/app.js)
hits=$(printf '%s' "$residue" | grep -oE "[\"'\`]/(api|static|ws)/" | wc -l | xargs)
t "残留绝对路径条数     → 0" 0 "$hits"
rewritten=$(printf '%s' "$residue" | grep -oc '/dsh/api/\|/dsh/ws/' || true)
t "已改写前缀出现       → yes" "yes" "$([ "${rewritten:-0}" -gt 0 ] && echo yes || echo no)"

echo "== 4. SSE 流式（首 chunk 应快速到达，验证缓冲已关）=="
ttfb=$(curl -ksSN -o /dev/null -w '%{time_starttransfer}' --max-time 8 $BASE/dsh/api/stream)
t "首字节时间 <1.5s     → yes" "yes" "$(awk -v t="$ttfb" 'BEGIN{print (t<1.5)?"yes":"no"}')"
chunks=$(curl -ksSN --max-time 8 $BASE/dsh/api/stream | grep -c '^data:' || true)
t "SSE chunk 数 ≥3      → yes" "yes" "$([ "${chunks:-0}" -ge 3 ] && echo yes || echo no)"

echo "== 5. WebSocket 握手（容器内 python3 验证 101）=="
ws_result=$(docker exec -i "$CID" python3 - <<'PY' 2>/dev/null || echo err
import base64, os, socket
s = socket.create_connection(("127.0.0.1", 443), timeout=5)
import ssl
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
s = ctx.wrap_socket(s, server_hostname="localhost")
key = base64.b64encode(os.urandom(16)).decode()
req = ("GET /dsh/ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
       "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % key)
s.sendall(req.encode())
print("101" if b" 101" in s.recv(4096).split(b"\r\n")[0] else "no-101")
PY
)
t "WS 握手              → 101" "101" "$ws_result"

echo "== 6. 端口网关（直连模式鉴权与透传）=="
t "3080 无凭据          → 401" 401 "$(code http://localhost:3080/)"
t "3080 带凭据          → 200" 200 "$(code -u "admin:$PW" http://localhost:3080/)"

echo "== 7. 健康检查与自检 =="
t "/healthz             → 200" 200 "$(code $BASE/healthz)"
sleep 20   # 等 selfcheck 写入结论
residue_flag=$(curl -ksS $BASE/healthz | grep -o '"sub_filter_residue": *[a-z]*' | awk '{print $2}')
t "selfcheck 残留标记   → false" "false" "${residue_flag:-missing}"

echo "== 8. SSH（若 ENABLE_SSH=true 启动）=="
ssh_state=$(docker exec "$CID" bash -c 'test -f /etc/supervisor/conf.d/sshd.conf && echo on || echo off' 2>/dev/null || echo unknown)
if [ "$ssh_state" = "on" ]; then
  t "密码登录被拒         → yes" "yes" \
    "$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        aioadm@localhost true 2>&1 | grep -qi 'permission denied' && echo yes || echo no)"
  echo "  SKIP  密钥登录验证（需提供测试私钥，手工执行: ssh -i key aioadm@localhost）"
else
  echo "  SKIP  SSH 未启用（ENABLE_SSH=$ssh_state）"
fi

echo "----------------------------------------"
echo "结果: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
