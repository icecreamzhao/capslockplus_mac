#!/bin/bash
# 安装 root LaunchDaemon：
#   sudo TOKEN=<44 字符 token> ./deploy/install-telemetry-daemon.sh
# 可选：APP=/Applications/CapslockPlusMac.app SERVER_URL=http://192.168.8.101:8787
set -euo pipefail

LABEL="com.icecreamzhao.capslockplus.telemetry"
APP="${APP:-/Applications/CapslockPlusMac.app}"
DIR="/Library/Application Support/CapslockPlusMac"
CONFIG="$DIR/telemetry.json"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SERVER_URL="${SERVER_URL:-http://192.168.8.101:8787}"
TOKEN="${TOKEN:-}"

if [[ $EUID -ne 0 ]]; then
    echo "需要 root：sudo TOKEN=<44 字符 token> $0" >&2
    exit 1
fi
if [[ ! -x "$APP/Contents/MacOS/CapslockPlusMac" ]]; then
    echo "找不到可执行文件：$APP/Contents/MacOS/CapslockPlusMac" >&2
    exit 1
fi
if [[ -z "$TOKEN" ]]; then
    echo "缺少 TOKEN。用法：sudo TOKEN=<44 字符 token> $0" >&2
    exit 1
fi
if [[ ! "$TOKEN" =~ ^[A-Za-z0-9+/=_-]+$ ]]; then
    echo "TOKEN 含非法字符（只允许 base64url 字符）" >&2
    exit 1
fi
if [[ ! "$SERVER_URL" =~ ^https?://[^\"[:space:]]+$ ]]; then
    echo "SERVER_URL 不合法：$SERVER_URL" >&2
    exit 1
fi
if [[ ${#TOKEN} -ne 44 ]]; then
    echo "WARN: token 长度 ${#TOKEN}，服务端契约是 44 字符" >&2
fi

install -d -m 700 -o root -g wheel "$DIR"

umask 077
tmp_config="$(mktemp "$DIR/.telemetry.json.XXXXXX")"
printf '{"server_url":"%s","token":"%s","enabled":true}\n' "$SERVER_URL" "$TOKEN" > "$tmp_config"
chmod 600 "$tmp_config"
chown root:wheel "$tmp_config"
mv -f "$tmp_config" "$CONFIG"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -m 644 -o root -g wheel "$SCRIPT_DIR/$LABEL.plist" "$PLIST"

launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl enable "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
launchctl kickstart -k "system/$LABEL"

sleep 1
echo "installed: $PLIST"
echo "config:    $CONFIG"
echo "database:  $DIR/telemetry.db"
echo "agent log: /var/root/Library/Logs/CapslockPlusMac.log"
launchctl print "system/$LABEL" 2>/dev/null | head -5 || true
