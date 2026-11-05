#!/bin/bash
# 在 Mac 上编译 + 签名 + 自检。ssh 会话默认拿不到钥匙串里的私钥，
# 所以每次先解锁 login keychain（否则 codesign 报 errSecInternalComponent）。
set -euo pipefail
MAC="${MAC:-littleboy@192.168.8.181}"
REMOTE="${REMOTE:-projects/capslock_plus_mac}"
export SSHPASS="${SSHPASS:-970711dhz}"
SSH="sshpass -e ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password -o StrictHostKeyChecking=no"

$SSH "$MAC" "bash -lc '
set -e
security unlock-keychain -p 970711dhz ~/Library/Keychains/login.keychain-db
cd ~/$REMOTE
./scripts/build.sh 2>&1 | tail -4
./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest
codesign --verify --strict --verbose=1 dist/CapslockPlusMac.app 2>&1 | tail -2
'"
