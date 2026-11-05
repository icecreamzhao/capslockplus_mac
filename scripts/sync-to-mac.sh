#!/bin/bash
# 把 Mac 侧仓库快进到 GitHub 上的 origin/master。
# 约定的分工：Linux 这边写代码并 push，Mac 只 pull + 编译验证。
# 不再用 rsync 覆盖文件——两边各有 .git，rsync 会把历史互相踩掉。
set -euo pipefail
cd "$(dirname "$0")/.."
MAC="${MAC:-littleboy@192.168.8.181}"
REMOTE="${REMOTE:-projects/capslock_plus_mac}"
export SSHPASS="${SSHPASS:-970711dhz}"
SSH="sshpass -e ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password -o IdentitiesOnly=yes -o StrictHostKeyChecking=no"

# 本地有未提交改动就别同步，否则"改了没提交、Mac 上跑的还是旧的"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "!! 本地有未提交改动，先 commit 再同步：" >&2
  git status --short >&2
  exit 1
fi

$SSH "$MAC" "bash -lc '
set -e
cd ~/$REMOTE
if [ -n \"\$(git status --porcelain)\" ]; then
  echo \"!! Mac 侧有本地改动，拒绝快进：\"
  git status --short
  exit 1
fi
git fetch --quiet origin
git merge --ff-only origin/master
echo \"mac HEAD=\$(git rev-parse --short HEAD)\"
'"
echo "synced -> $MAC:$REMOTE (from origin/master)"
