#!/bin/bash
# 重新构建并重启 app；先杀掉旧进程，避免多实例抢 event tap。
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
pkill -x CapslockPlusMac 2>/dev/null || true
sleep 0.3
open dist/CapslockPlusMac.app
sleep 0.5
echo "--- log ---"
tail -n 20 ~/Library/Logs/CapslockPlusMac.log 2>/dev/null || echo "(no log yet)"
