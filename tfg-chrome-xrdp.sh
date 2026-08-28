#!/bin/bash
# tfg-chrome-xrdp.sh —— 由 xRDP(xfce) 会话自启动调用。
#
# 在客户通过 xRDP 远程桌面登录后，拉起一个“有头”(headed) Chromium 并开启远程调试(CDP 9222)，
# 供客户【可视化】登录各 AI 网站（DeepSeek / Claude / ChatGPT 等）；token-free-gateway 通过该端口
# 复用会话（免 API Key 转发请求）。
#
# 为什么是有头而非无头：
#   token-free-gateway 的 webauth 通过 9222 驱动浏览器并等待客户手动登录。若浏览器为无头模式，
#   窗口不可见，客户无法输入账号 —— 即“无头陷阱”。改为有头并在 xRDP 桌面中运行后，客户能直接
#   看到并操作登录页，登录态（cookie）持久化在卷 dsh-chrome-tfg 中。
#
# 存活说明：xRDP 会话断开后默认保留（sesman KillDisconnected=false），因此本 Chromium 在客户断开
#   RDP 后仍存活，网关可持续工作；仅当客户主动注销 xRDP 会话时才会结束。
set -u

CHROME_DIR=/root/.chrome-tfg-debug
mkdir -p "$CHROME_DIR"

# 已在运行则跳过（避免重复拉起 / 端口冲突）
if curl -s -m 2 http://127.0.0.1:9222/json/version >/dev/null 2>&1; then
    echo "[tfg-chrome] Chromium 已在 9222 运行，跳过"
    exit 0
fi

# 仅清锁文件，不删整个 profile（保留卷上已登录会话）
rm -f "$CHROME_DIR/SingletonLock" "$CHROME_DIR/SingletonLock".* "$CHROME_DIR/SingletonCookie" 2>/dev/null

# 等待 xRDP 会话注入 DISPLAY（通常为 :10）
for _i in $(seq 1 30); do
    [ -n "${DISPLAY:-}" ] && break
    sleep 1
done
export DISPLAY="${DISPLAY:-:10}"

nohup chromium --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --remote-debugging-port=9222 --remote-allow-origins=* \
    --user-data-dir="$CHROME_DIR" --no-first-run \
    --window-position=24,24 --window-size=1280,800 \
    > /var/log/tfg-chrome-xrdp.log 2>&1 &
disown
echo "[tfg-chrome] 有头 Chromium 已拉起 (CDP 9222, DISPLAY=$DISPLAY)"
