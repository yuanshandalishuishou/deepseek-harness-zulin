#!/usr/bin/env bash
# 真实 Hermes Agent gateway 启动器 — 供 supervisor 直接 exec
# 由 HERMES_COMMAND 默认值引用(见 entrypoint.sh); 产物 /opt/hermes/app(源码+.venv, uv sync)
# 数据目录 $HERMES_HOME(默认 /data/hermes), 由 supervisor 模板注入并 chown。
set -euo pipefail
cd /opt/hermes/app || { echo "[run-hermes] /opt/hermes/app 不存在(非真实构建?)" >&2; exit 1; }
exec .venv/bin/hermes gateway run
