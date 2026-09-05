#!/usr/bin/env bash
# 真实 OpenClaw gateway 启动器 — 供 supervisor 直接 exec
# 由 OPENCLAW_COMMAND 默认值引用(见 entrypoint.sh); 产物 /opt/openclaw(dist+node_modules)
# 数据目录 $OPENCLAW_HOME / $OPENCLAW_CONFIG_DIR(默认 /data/openclaw), 由 supervisor 模板注入。
set -euo pipefail
cd /opt/openclaw || { echo "[run-openclaw] /opt/openclaw 不存在(非真实构建?)" >&2; exit 1; }
exec node dist/index.js gateway --bind lan --port 18789
