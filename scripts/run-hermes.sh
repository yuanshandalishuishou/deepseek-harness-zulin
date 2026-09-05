#!/usr/bin/env bash
# 真实 Hermes Agent 启动器 — 供 supervisor 直接 exec
# 由 HERMES_COMMAND 默认值引用(见 entrypoint.sh); 产物 /opt/hermes/app(源码+.venv, uv sync)
# 数据目录 $HERMES_HOME(默认 /data/hermes), 由 supervisor 模板注入并 chown。
#
# 重要: Hermes 有两个独立服务, 切勿混淆:
#   hermes dashboard  → Web UI(默认 9119), 本平台 /hermes/ 反代的就是它
#   hermes gateway    → 消息网关(agent 运行/消息收发, 非 Web UI)
# 因此这里启动 dashboard 并钉在 127.0.0.1:6060(与 nginx 桩端口一致, 反代无需改),
# 而非 gateway run。dashboard 支持 --host/--port/--no-open(见 hermes_cli/dashboard_procs.py)。
# 注: dashboard 实际路由(/api、/ws 等)与桩不同, 路径/子域模式的 sub_filter 改写需在
#      真实构建 workflow(B-2)中按上游版本校准; 本脚本仅保证"绑对地址与端口"。
set -euo pipefail
cd /opt/hermes/app || { echo "[run-hermes] /opt/hermes/app 不存在(非真实构建?)" >&2; exit 1; }
exec .venv/bin/hermes dashboard --host 127.0.0.1 --port 6060 --no-open
