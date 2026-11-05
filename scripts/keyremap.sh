#!/bin/bash
set -euo pipefail

HIDUTIL=/usr/bin/hidutil
MAPPING='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}'

case "${1:-}" in
    on)
        "$HIDUTIL" property --set "$MAPPING"
        "$HIDUTIL" property --get UserKeyMapping
        ;;
    off)
        "$HIDUTIL" property --set '{"UserKeyMapping":[]}'
        ;;
    status)
        "$HIDUTIL" property --get UserKeyMapping
        ;;
    *)
        echo "usage: $0 on|off|status" >&2
        exit 2
        ;;
esac
