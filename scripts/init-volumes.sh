#!/usr/bin/env bash
# 卷目录初始化与权限（PUID/PGID 映射，幂等）
set -euo pipefail
log() { echo "[init-volumes] $*"; }

dirs=(
  /data/dsh /data/openclaw /data/hermes /data/admin
  /data/certs
  /var/log/dsh /var/log/openclaw /var/log/hermes /var/log/admin
  /etc/letsencrypt
)
for d in "${dirs[@]}"; do
  mkdir -p "$d"
done

# 数据目录归属 PUID/PGID（卷挂载属主错位修复）
chown -R "$PUID:$PGID" /data
chmod 700 /etc/letsencrypt 2>/dev/null || true

# 各服务数据目录同时授权给对应运行用户（容器内读写）
chown -R dsh:dsh           /data/dsh      /var/log/dsh
chown -R openclaw:openclaw /data/openclaw /var/log/openclaw
chown -R hermes:hermes     /data/hermes   /var/log/hermes
chown -R admin:admin       /data/admin    /var/log/admin

log "卷目录就绪（PUID=$PUID PGID=$PGID）"
