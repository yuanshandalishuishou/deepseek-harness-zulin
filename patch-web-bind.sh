#!/usr/bin/env bash
# =============================================================================
# patch-web-bind.sh
# -----------------------------------------------------------------------------
# 用途：
#   移除 deepseek-harness 上游对命令行参数 `--host 0.0.0.0` 的硬编码拒绝，
#   使 `dsh web` 服务可以绑定 0.0.0.0，从而从「容器外部」——宿主机、局域网
#   甚至（在防火墙允许的前提下）公网——直接访问 Web UI。
#
# 为什么要做这个补丁（背景 / 踩坑记录）：
#   1) 安全限制：上游 deepseek-harness 出于安全考虑（避免把无鉴权的开发服务器
#      直接暴露到全网，导致潜在的远程代码执行 RCE 风险），在启动逻辑里显式
#      拒绝 `--host 0.0.0.0`。原话大致是：
#          error: --host 0.0.0.0 is intentionally not supported yet for safety:
#                 it would expose remote code execution to the network;
#                 use 127.0.0.1 instead
#   2) 我们的场景：本项目是「容器化内部部署」，需要 Web 服务对外暴露，因此
#      在构建阶段把该限制放开。这属于可控的内部使用，并非把裸开发服务器
#      直接挂公网（公网部署仍应在外层加防火墙 / 反向代理 + 鉴权，见 README）。
#   3) 关键坑点：运行时 `dsh web` 以 tsx 源码模式加载
#      `packages/bundle/web-app/src/startup.ts`，**不是**加载编译产物
#      `lib/startup.js`。所以**必须 patch src**，只改 lib 不生效。
#   4) 下层 webserver 配置 schema 本身允许 host 取值 "127.0.0.1" | "0.0.0.0"，
#      因此移除 startup.ts 的拒绝后，`--host 0.0.0.0` 即可正常工作，无需再改别处。
#
# 幂等性：重复执行安全；若限制已不存在则直接跳过，不会误改其他内容。
#
# 调用方式：在 Dockerfile 构建阶段、clone 完成后执行一次（见 Dockerfile 注释）。
#   也可手动：`HARNESS_DIR=/opt/deepseek-harness bash patch-web-bind.sh`
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# 1) 定位 deepseek-harness 源码目录
#    （与环境变量 HARNESS_DIR 保持一致；缺省为 /opt/deepseek-harness，
#     与 Dockerfile 中的 `git clone ... /opt/deepseek-harness` 对应）
# -----------------------------------------------------------------------------
HARNESS_DIR="${HARNESS_DIR:-/opt/deepseek-harness}"

# 需要 patch 的两个候选文件（按优先级）：
#   - SRC：tsx 源码模式实际加载的文件，必须改它才生效
#   - LIB：若构建时顺带编译出了 lib，也一并处理（兜底，避免残留旧逻辑）
STARTUP_SRC="${HARNESS_DIR}/packages/bundle/web-app/src/startup.ts"
STARTUP_LIB="${HARNESS_DIR}/packages/bundle/web-app/lib/startup.js"

# -----------------------------------------------------------------------------
# 2) patch_one_file <file>
#    用 Python 精确删除整段拒绝逻辑：
#        if (options.host === '0.0.0.0') {
#          program.error('...intentionally not supported yet for safety...')
#        }
#    之所以用 Python 而不是 sed：要跨多行精确删除「整块 if」，sed 多行处理容易
#    误伤相邻代码；Python 的正则（DOTALL）可一次性把整块抹掉。
#    若正则未命中（上游代码变动），则退化为只删除 program.error 那一行——
#    留下一个空的 `if (...) {}` 块，对运行无害（已实测验证）。
# -----------------------------------------------------------------------------
patch_one_file() {
    local f="$1"
    # 文件不存在（例如 lib 未编译）则跳过，不报错
    [ -f "$f" ] || { echo "[patch-web-bind] 跳过（文件不存在）: $f"; return 0; }

    # 已无拒绝逻辑 → 说明之前已 patch 过，幂等跳过
    if ! grep -q "intentionally not supported yet for safety" "$f"; then
        echo "[patch-web-bind] 无需修改（限制已不存在）: $f"
        return 0
    fi

    echo "[patch-web-bind] 正在放开 --host 0.0.0.0 限制: $f"
    python3 - "$f" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    src = fh.read()

# 匹配并删除整段「if (options.host === '0.0.0.0') { ... program.error(...) ... }」
#   - 首行：缩进 + if (options.host === '0.0.0.0') {
#   - 中间：跨行直到包含 intentionally not supported yet for safety 的 program.error(...) 调用
#   - 尾行：独立的闭合 }
# DOTALL 让 . 能跨行匹配；非贪婪 *? 保证只吃到最近的闭合 }
pattern = re.compile(
    r"[ \t]*if\s*\(\s*options\.host\s*===\s*['\"]0\.0\.0\.0['\"]\s*\)\s*\{"
    r".*?intentionally not supported yet for safety.*?\n[ \t]*\}",
    re.DOTALL,
)
new_src, n = pattern.subn("", src)
if n == 0:
    # 兜底：只删除 program.error 那一行（留下空 if 块也无碍）
    new_src, n = re.subn(r".*intentionally not supported yet for safety.*\n", "", src)

with open(path, "w", encoding="utf-8") as fh:
    fh.write(new_src)
print(f"  [patch-web-bind] 已移除拒绝逻辑块数量 = {n}")
PYEOF
    echo "[patch-web-bind] 完成: $f"
}

# -----------------------------------------------------------------------------
# 3) 依次处理 src 与 lib
# -----------------------------------------------------------------------------
patch_one_file "$STARTUP_SRC"
patch_one_file "$STARTUP_LIB"

echo "[patch-web-bind] 全部处理完毕。dsh web 现在允许 --host 0.0.0.0。"
