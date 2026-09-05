#!/usr/bin/env bash
# 真实 OpenClaw gateway 启动器 — 供 supervisor 直接 exec
# 由 OPENCLAW_COMMAND 默认值引用(见 entrypoint.sh); 产物 /opt/openclaw(dist+node_modules)
# 数据目录 $OPENCLAW_HOME / $OPENCLAW_CONFIG_DIR(默认 /data/openclaw), 由 supervisor 模板注入。
#
# 绑定模式(上游 src/gateway/net.ts resolveGatewayBindHost):
#   loopback → 127.0.0.1 | lan → 0.0.0.0 | auto → 容器内 0.0.0.0 | tailnet | custom
# 本平台架构要求业务服务绑回环(127.0.0.1), 由 nginx 网关(绑容器主IP)对外;
# 故必须用 --bind loopback(默认即 loopback, 显式写出防误改), 禁用 lan/auto(会 0.0.0.0 与端口网关冲突)。
set -euo pipefail
cd /opt/openclaw || { echo "[run-openclaw] /opt/openclaw 不存在(非真实构建?)" >&2; exit 1; }
exec node dist/index.js gateway --bind loopback --port 18789
