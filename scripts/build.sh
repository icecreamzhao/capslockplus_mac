#!/bin/bash
# 组装 .app 并签名。签名身份固定，TCC 授权跟它绑定，换签名会导致权限重新弹窗。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
IDENTITY="${CODESIGN_ID:-Apple Development: 1127534615@qq.com (33NUEFMU8B)}"
APP="dist/CapslockPlusMac.app"

swift build -c "$CONFIG" --arch arm64
BIN_DIR=$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CapslockPlusMac" "$APP/Contents/MacOS/CapslockPlusMac"
cp resources/Info.plist "$APP/Contents/Info.plist"
# 菜单栏图标等资源（vector PDF 走 isTemplate，深浅色菜单栏自动反色）
cp resources/*.pdf "$APP/Contents/Resources/" 2>/dev/null || true

codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "built: $APP"
echo "bin:   $BIN_DIR/CapslockPlusMac"
