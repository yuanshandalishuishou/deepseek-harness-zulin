#!/usr/bin/env bash
# ============================================================================
# openclaw_role.sh —— 设置 OpenClaw 的角色（默认应用镜像自带的纪总 + 八专家人设）
# ----------------------------------------------------------------------------
# 设计原则：镜像保持「原始状态」，角色由本脚本在需要时按需应用。
#
# 用法:
#   bash /opt/role-scripts/openclaw_role.sh [WORKSPACE_SRC]
#
#   WORKSPACE_SRC 默认 /opt/openclaw-initial/openclaw/workspace
#   该目录内的 SOUL.md / AGENTS.md / IDENTITY.md / USER.md（及可选 souls/）
#   即定义了 OpenClaw 的默认角色人格。
#
# 行为:
#   1. 从镜像自带工作区源复制角色相关文件到 /root/.openclaw/workspace
#   2. 仅同步角色文件，不覆盖用户自己的会话/项目数据
#   3. 提示重启 OpenClaw 使其生效
# ============================================================================
set -euo pipefail

SRC="${1:-/opt/openclaw-initial/openclaw/workspace}"
DST="/root/.openclaw/workspace"

if [ ! -d "$SRC" ]; then
  echo "ERROR: 未找到 OpenClaw 人设源目录: $SRC" >&2
  exit 1
fi

mkdir -p "$DST"

# 仅同步角色定义文件，避免抹掉用户工作区里的真实数据
for f in SOUL.md AGENTS.md IDENTITY.md USER.md; do
  if [ -f "$SRC/$f" ]; then
    cp -f "$SRC/$f" "$DST/"
    echo "  已同步 $f"
  fi
done

if [ -d "$SRC/souls" ]; then
  mkdir -p "$DST/souls"
  cp -f "$SRC/souls"/*.md "$DST/souls"/ 2>/dev/null || true
  echo "  已同步 souls/"
fi

echo "OpenClaw 角色已应用（源: $SRC）"
echo "工作区: $DST"
echo "（如 OpenClaw 已在运行，请重启 gateway/agent 使其生效：重启容器，或重启 openclaw 服务）"
