#!/bin/bash
# 在 Mac 上编译 + 签名 + 自检。ssh 会话默认拿不到钥匙串里的私钥，
# 所以每次先解锁 login keychain（否则 codesign 报 errSecInternalComponent）。
set -euo pipefail
MAC="${MAC:-littleboy@192.168.8.181}"
REMOTE="${REMOTE:-projects/capslock_plus_mac}"
export SSHPASS="${SSHPASS:-970711dhz}"
SSH="sshpass -e ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password -o StrictHostKeyChecking=no"

# 注意：调用方不要再把 build.sh 的输出接管道（会把失败码换成 tail 的 0），
# 这里自己判断退出码，避免"编译失败却验了旧二进制"。
$SSH "$MAC" "bash -lc '
set -e
security unlock-keychain -p 970711dhz ~/Library/Keychains/login.keychain-db
cd ~/$REMOTE
if ! swift build -c release --arch arm64 2>/tmp/cx_build_err.txt; then
  echo BUILD_FAILED
  grep -E \"error:\" /tmp/cx_build_err.txt | head -10
  exit 1
fi
./scripts/build.sh >/tmp/cx_sign.log 2>&1 || { echo SIGN_FAILED; tail -5 /tmp/cx_sign.log; exit 1; }
tail -3 /tmp/cx_sign.log
./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest
codesign --verify --strict --verbose=1 dist/CapslockPlusMac.app 2>&1 | tail -2
'"
