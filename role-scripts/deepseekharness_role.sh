#!/usr/bin/env bash
# ============================================================================
# deepseekharness_role.sh —— 设置 DeepSeek Harness 的角色（persona）
# ----------------------------------------------------------------------------
# 设计原则：镜像保持「原始状态」，角色由本脚本在需要时按需应用，
#           不依赖镜像内被写死的特定人设，便于不同部署复用同一镜像。
#
# 用法:
#   bash /opt/role-scripts/deepseekharness_role.sh [PERSONA_ID]
#
#   PERSONA_ID 默认 enterprise-boss（纪总，八专家总协调人）。
#   可选值 = /opt/dsh-initial/souls/ 下各 .md 文件名（去掉 .md），例如:
#     enterprise-boss / financial-expert / compliance-expert / tax-expert /
#     architect-expert / dev-expert / qa-expert / party-labor-discipline
#
# 行为:
#   1. 从镜像自带人设源 /opt/dsh-initial/souls 安装全部 .md 到 /root/.dsh/souls
#   2. 校验所选 persona 的 soul 文件存在
#   3. 写入/更新 /root/.dsh/settings.yaml 的 system-prompt.persona
#   4. 提示重启 harness 使其生效
# ============================================================================
set -euo pipefail

PERSONA="${1:-enterprise-boss}"
SOULS_SRC="/opt/dsh-initial/souls"
SOULS_DST="/root/.dsh/souls"
SETTINGS="/root/.dsh/settings.yaml"

# 1) 安装人设文件（纯复制镜像自带资产，保证「原始」可复现）
mkdir -p "$SOULS_DST"
if [ -d "$SOULS_SRC" ]; then
  cp -f "$SOULS_SRC"/*.md "$SOULS_DST"/ 2>/dev/null || true
fi

# 2) 校验所选 persona
if [ ! -f "$SOULS_DST/${PERSONA}.md" ]; then
  echo "ERROR: 未找到人设: $SOULS_DST/${PERSONA}.md" >&2
  echo "可用人设: $(ls "$SOULS_DST" 2>/dev/null | sed 's/\.md$//' | tr '\n' ' ')" >&2
  exit 1
fi

# 3) 确保 settings.yaml 存在
if [ ! -f "$SETTINGS" ]; then
  echo "ERROR: 未找到 $SETTINGS，请先启动一次容器以生成配置" >&2
  exit 1
fi

# 4) 写入/更新 system-prompt.persona（仅用 sed/grep，避免引入额外依赖）
grep -q '^system-prompt:' "$SETTINGS" || printf '\nsystem-prompt:\n' >> "$SETTINGS"
if grep -q '^  persona:' "$SETTINGS"; then
  sed -i -E "s|^  persona:.*|  persona: ${PERSONA}|" "$SETTINGS"
else
  sed -i -E "s|^system-prompt:.*|system-prompt:\n  persona: ${PERSONA}|" "$SETTINGS"
fi

echo "DeepSeek Harness 角色已设置为: ${PERSONA}"
echo "配置文件: $SETTINGS"
echo "（如 harness 已在运行，请重启使其生效：重启容器，或 pkill -HUP -f 'dsh web'）"
