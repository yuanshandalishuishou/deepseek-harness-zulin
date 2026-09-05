#!/usr/bin/env bash
# 真实 DSH(DeepSeek Harness) 启动器 — 供 supervisor 直接 exec(无需 shell 解析引号)
# 由 DSH_COMMAND 默认值引用(见 entrypoint.sh); 产物在 /opt/dsh/app(整目录随产物)
# 默认仅监听 127.0.0.1:3080, 由 nginx 网关/反代对外。数据目录 $DSH_HOME(默认 /data/dsh)。
# 注: DSH 对 --host 0.0.0.0 硬拒绝, 勿试图直绑对外; 反代到回环即可。
set -euo pipefail
cd /opt/dsh/app || { echo "[run-dsh] /opt/dsh/app 不存在(非真实构建?)" >&2; exit 1; }
exec node --import tsx/esm apps/cli/src/bin.ts web --no-open
