#!/bin/bash
# 把本仓库同步到 Mac（codex 在 Linux 这边写代码，Mac 只负责编译验证）
set -euo pipefail
cd "$(dirname "$0")/.."
MAC="${MAC:-littleboy@192.168.8.181}"
REMOTE="${REMOTE:-~/projects/capslock_plus_mac}"

rsync -az --delete \
  --exclude '.build/' --exclude 'dist/' --exclude '*.log' --exclude '.git/' \
  -e "sshpass -e ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password -o StrictHostKeyChecking=no" \
  ./ "$MAC:$REMOTE/"

echo "synced -> $MAC:$REMOTE"
