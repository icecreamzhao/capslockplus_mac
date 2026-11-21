#!/bin/bash
# 把录屏（.mov / .mp4）转成适合放进 README 的 GIF。
#
# 为什么不是一条 ffmpeg 命令了事：直接 -i in.mov out.gif 会用固定 256 色调色板，
# 界面截图（大片纯色 + 细字）会出现脏边和色带。这里走两遍：先从素材统计出专用调色板，
# 再按这个调色板抖动，最后交给 gifsicle 做无损重排 + 有损压缩。
#
# 用法:
#   ./scripts/make-gif.sh in.mov out.gif
#   ./scripts/make-gif.sh in.mov out.gif --start 1.2 --dur 6 --width 900 --fps 12
#   ./scripts/make-gif.sh in.mov out.gif --crop 1200:800:200:300     # 宽:高:左:上
#   ./scripts/make-gif.sh in.mov out.gif --lossy 60                  # 更小更糊，0-200
#
# 依赖: ffmpeg、gifsicle（brew install ffmpeg gifsicle）
set -euo pipefail

if [ $# -lt 2 ]; then
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

IN="$1"; OUT="$2"; shift 2
START=""; DUR=""; WIDTH=900; FPS=12; CROP=""; LOSSY=80

while [ $# -gt 0 ]; do
    case "$1" in
        --start) START="$2"; shift 2 ;;
        --dur)   DUR="$2";   shift 2 ;;
        --width) WIDTH="$2"; shift 2 ;;
        --fps)   FPS="$2";   shift 2 ;;
        --crop)  CROP="$2";  shift 2 ;;
        --lossy) LOSSY="$2"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

for bin in ffmpeg gifsicle; do
    command -v "$bin" >/dev/null || { echo "缺少 $bin：brew install ffmpeg gifsicle" >&2; exit 1; }
done
[ -f "$IN" ] || { echo "找不到输入文件: $IN" >&2; exit 1; }

# 关键：先裁到内容区、再降帧、再缩放。顺序反了会把细节烧掉再补，GIF 只会更糊更大。
CHAIN=""
[ -n "$CROP" ] && CHAIN="crop=${CROP},"
CHAIN="${CHAIN}fps=${FPS},scale=${WIDTH}:-1:flags=lanczos"

TMP="$(mktemp "${TMPDIR:-/tmp}/capslockgif.XXXXXX").gif"
trap 'rm -f "$TMP"' EXIT

SS_ARGS=()
[ -n "$START" ] && SS_ARGS=(-ss "$START")
T_ARGS=()
[ -n "$DUR" ] && T_ARGS=(-t "$DUR")

ffmpeg -v error -y "${SS_ARGS[@]}" "${T_ARGS[@]}" -i "$IN" \
    -vf "${CHAIN},split[a][b];[a]palettegen=stats_mode=diff:max_colors=256[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
    -loop 0 "$TMP"

# -O3 去冗余帧，--lossy 允许色差换体积；GIF 越小 GitHub 加载越快
gifsicle -O3 --lossy="$LOSSY" --colors 256 "$TMP" -o "$OUT"

BYTES=$(wc -c < "$OUT" | tr -d ' ')
FRAMES=$(gifsicle --info "$OUT" | grep -c '^  \+[0-9]\+ ' || true)
printf 'out=%s bytes=%s (%.1fMB) width=%s fps=%s\n' \
    "$OUT" "$BYTES" "$(echo "$BYTES" | awk '{print $1/1048576}')" "$WIDTH" "$FPS"

if [ "$BYTES" -gt 10485760 ]; then
    echo "⚠ 超过 GitHub 单文件舒服阈值（10MB），建议收窄宽度/降 fps/加 --lossy 或裁掉无关区域" >&2
elif [ "$BYTES" -gt 5242880 ]; then
    echo "提示：>5MB，README 里滚动加载会明显卡，建议 --width 760 --fps 10 再压一次" >&2
fi

echo "README 里引用：![演示](docs/$(basename "$OUT"))"
