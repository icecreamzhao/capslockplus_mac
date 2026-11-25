#!/usr/bin/env bash
# 一次命令重建整个离线词库：mdx -> dict.sqlite.new，散装资源 -> dict-assets/，
# 校验通过后再原子替换 dict.sqlite。
#
# 用法：
#   scripts/build-offline-dict.sh            # 全量重建
#   scripts/build-offline-dict.sh --only merc # 只跑一本，调试用（不替换正式库）
#   scripts/build-offline-dict.sh --no-audio  # 不抽 mdd 里的读音
#
# 环境变量：DICT_ROOT（默认 ~/Documents/dict）、OUT_DIR（默认 ~/.config/capslock-plus-mac）、
#           DICT_AUDIO（默认 1 抽音频，设 0 关闭）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DICT_ROOT="${DICT_ROOT:-$HOME/Documents/dict}"
OUT_DIR="${OUT_DIR:-$HOME/.config/capslock-plus-mac}"
DICT_AUDIO="${DICT_AUDIO:-1}"
DB="$OUT_DIR/dict.sqlite"
NEW="$OUT_DIR/dict.sqlite.new"
ASSETS="$OUT_DIR/dict-assets"
CONVERTER="$SCRIPT_DIR/mdx-to-sqlite.py"
ASSET_EXTRACTOR="$SCRIPT_DIR/extract-dict-assets.py"

audio_enabled=1
if [[ "$DICT_AUDIO" =~ ^(0|[Nn][Oo]|[Ff][Aa][Ll][Ss][Ee]|[Oo][Ff][Ff])$ ]]; then
    audio_enabled=0
fi

# NAME|中文显示名|mdx 相对路径|主样式表文件名
CATALOG=$(cat <<'EOF'
oaldpe|牛津高阶10|欧陆词典包资源/①牛津系列词典（共15本）/1.英汉双 牛津高阶10（精装完美版）/oaldpe.mdx|
ldoce6ec|朗文当代6|欧陆词典包资源/④朗文系列词典 （共9本）/1.英汉双 朗文当代6 （精装完美版）/LDOCE6EC.mdx|
collins|柯林斯高阶|欧陆词典包资源/③柯林斯系列词典 （共8本）/1.英汉双 柯林斯高阶 （精装版）/柯林斯高阶双解.mdx|
cambridge|剑桥高阶|欧陆词典包资源/②剑桥系列词典 （共7本）/3.英汉双 剑桥高阶 （精装完美版）/Cambridge English-Chinese (Simplified) Dictionary.mdx|
macmillan|麦克米伦|欧陆词典包资源/⑥麦克米伦系列词典 （共3本）/3.英汉双 麦克米伦高阶 （精装完美版）/麦克米伦词典.mdx|entry.css
merriam|韦氏高阶|欧陆词典包资源/⑤韦氏系列词典 （共4本）/1.英汉双 韦氏高阶2019 （精装完美版）/韦氏高阶.mdx|
newoxford|新牛津双解|欧陆词典包资源/①牛津系列词典（共15本）/6.英汉双 新牛津高阶2（精装版）/新牛双解词典.mdx|
lugu|英汉大词典|欧陆词典包资源/⑦其他词典（共31本）/14.英汉大词典（陆谷孙）/陆谷孙.mdx|
vocabcom|Vocabulary.com|欧陆词典包资源/⑦其他词典（共31本）/2.Vocabulary.com （精装版）/Vocabulary.com Dictionary.mdx|
xinhua|新华字典|欧陆词典包资源/⑦其他词典（共31本）/20.新华字典/新华字典（汉英双语版）.mdx|
wuguanghua|汉英大词典|欧陆词典包资源/⑦其他词典（共31本）/15.汉英大词典（吴光华）/吴光华汉英.mdx|
xsjhy|新世纪汉英|欧陆词典包资源/⑦其他词典（共31本）/19.新世纪汉英大词典（精装版）/xsjhy20oct2.mdx|
EOF
)

ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --only)
            [ $# -ge 2 ] || { echo "--only 需要一个词典名" >&2; exit 2; }
            ONLY="$2"
            shift 2
            ;;
        --only=*)
            ONLY="${1#*=}"
            shift
            ;;
        --no-audio)
            audio_enabled=0
            shift
            ;;
        -h|--help)
            echo "用法: $0 [--only NAME] [--no-audio]"
            echo "环境变量: DICT_ROOT（默认 ~/Documents/dict）、OUT_DIR（默认 ~/.config/capslock-plus-mac）、DICT_AUDIO（默认 1）"
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            exit 2
            ;;
    esac
done

names=()
labels=()
mdxs=()
csses=()
matched=0
while IFS='|' read -r name label rel css; do
    [ -z "$name" ] && continue
    if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then
        continue
    fi
    matched=1
    names+=("$name")
    labels+=("$label")
    mdxs+=("$DICT_ROOT/$rel")
    csses+=("$css")
done <<< "$CATALOG"

if [ ${#names[@]} -eq 0 ]; then
    if [ -n "$ONLY" ]; then
        echo "清单里没有词典 $ONLY" >&2
    else
        echo "词典清单为空" >&2
    fi
    exit 2
fi
[ "$matched" -eq 1 ] || exit 2

missing=0
for i in "${!names[@]}"; do
    if [ ! -f "${mdxs[$i]}" ]; then
        echo "找不到 mdx：${mdxs[$i]}" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || exit 1

PY="$HOME/.local/venvs/dictconv/bin/python"
[ -x "$PY" ] || PY=python3
command -v "$PY" >/dev/null 2>&1 || { echo "找不到 python：$PY" >&2; exit 1; }

mkdir -p "$OUT_DIR" "$ASSETS"
rm -f "$NEW" "$NEW-wal" "$NEW-shm"

# ---------------------------------------------------------------- 1. 转 sqlite
echo "[1/4] 解析 ${#names[@]} 本词典 → $NEW"
convert_args=(--out "$NEW")
for i in "${!names[@]}"; do
    convert_args+=(--dict "${names[$i]}=${mdxs[$i]}")
    convert_args+=(--label "${names[$i]}=${labels[$i]}")
    if [ -n "${csses[$i]}" ]; then
        convert_args+=(--css "${names[$i]}=${csses[$i]}")
    fi
done
convert_args+=(--verify)
"$PY" "$CONVERTER" "${convert_args[@]}"

# ---------------------------------------------------------------- 2. 散装资源
echo "[2/4] 复制 mdx 同目录的散装资源 → $ASSETS/<name>/"
for i in "${!names[@]}"; do
    name="${names[$i]}"
    src_dir="$(dirname "${mdxs[$i]}")"
    dest="$ASSETS/$name"
    copied=0
    while IFS= read -r -d '' file; do
        mkdir -p "$dest"
        cp -p "$file" "$dest/"
        copied=$((copied + 1))
    done < <(find "$src_dir" -maxdepth 1 -type f \
        \( -iname '*.css' -o -iname '*.js' -o -iname '*.png' -o -iname '*.jpg' \
           -o -iname '*.woff*' -o -iname '*.ttf' \) -print0 2>/dev/null)
    echo "  $name: 复制 $copied 个文件"
done

# ---------------------------------------------------------------- 3. mdd 资源
if [ "$audio_enabled" -eq 1 ]; then
    echo "[3/4] 从 mdd 抽取排版资源与音频"
else
    echo "[3/4] 从 mdd 抽取排版资源（--no-audio）"
fi
mdd_paths=()
mdd_names=()
for i in "${!names[@]}"; do
    src_dir="$(dirname "${mdxs[$i]}")"
    stem="$(basename "${mdxs[$i]}")"
    stem="${stem%.*}"
    while IFS= read -r -d '' mdd; do
        mdd_paths+=("$mdd")
        mdd_names+=("${names[$i]}")
    done < <(find "$src_dir" -maxdepth 1 -type f -iname "$stem*.mdd" -print0 2>/dev/null)
done
if [ ${#mdd_paths[@]} -eq 0 ]; then
    echo "  没有找到 mdd，跳过"
else
    echo "  抽 ${#mdd_paths[@]} 个 mdd"
    mdd_args=(--out "$ASSETS")
    for j in "${!mdd_paths[@]}"; do
        mdd_args+=(--mdd "${mdd_paths[$j]}" --dict "${mdd_names[$j]}")
    done
    audio_log="$(mktemp)"
    # 资源抽取失败不阻断词库构建，下次还能单独重跑
    extract_ok=1
    if [ "$audio_enabled" -eq 1 ]; then
        "$PY" "$ASSET_EXTRACTOR" "${mdd_args[@]}" --include-audio | tee "$audio_log" || extract_ok=0
    else
        "$PY" "$ASSET_EXTRACTOR" "${mdd_args[@]}" | tee "$audio_log" || extract_ok=0
    fi
    if [ "$extract_ok" -eq 0 ]; then
        echo "警告：mdd 资源抽取失败，保留已有资源继续" >&2
    fi
    if [ "$audio_enabled" -eq 1 ]; then
        awk -F'[:= ]+' '/: audio=[0-9]+ size=[0-9.]+MB$/ {
                total += $3; mb = $5; sub(/MB$/, "", mb); total_mb += mb
            }
            END {
                printf "  音频合计：%d 个文件，%.1f MB\n", total, total_mb
                if (total_mb > 8192) {
                    print "  提示：音频超过 8GB，占用较大（本机空间充足，确认后保留）"
                }
            }' "$audio_log"
    fi
    rm -f "$audio_log"
fi

# ---------------------------------------------------------------- 4. 校验替换
echo "[4/4] 校验 $NEW"
"$PY" - "$NEW" "${names[@]}" <<'PY'
import sqlite3
import sys

db, expected = sys.argv[1], sys.argv[2:]
con = sqlite3.connect(db)
dist = dict(con.execute("SELECT source, COUNT(*) FROM entries GROUP BY source").fetchall())
total = sum(dist.values())

problems = []
if total <= 0:
    problems.append("entries 为空")
for source in expected:
    if dist.get(source, 0) <= 0:
        problems.append("%s 没有条目" % source)
    row = con.execute("SELECT v FROM meta WHERE k = ?", ("label_" + source,)).fetchone()
    if not row or not (row[0] or "").strip():
        problems.append("缺少 label_%s" % source)
    row = con.execute("SELECT v FROM meta WHERE k = ?", ("order_" + source,)).fetchone()
    if row is None:
        problems.append("缺少 order_%s" % source)

unexpected = sorted(set(dist) - set(expected))
if unexpected:
    print("  注意：库里还有清单外的 source：%s" % ", ".join(unexpected))
print("  source 分布：%s" % ", ".join("%s=%d" % item for item in sorted(dist.items())))
print("  合计 %d 条" % total)
if problems:
    print("校验失败：%s" % "；".join(problems), file=sys.stderr)
    sys.exit(1)
print("校验通过")
PY

echo "  中文词头抽查"
"$PY" - "$NEW" "${names[@]}" <<'PY'
import sqlite3
import sys

db, expected = sys.argv[1], set(sys.argv[2:])
checks = [("xinhua", "一"), ("wuguanghua", "学习"), ("xsjhy", "学习")]
con = sqlite3.connect(db)
failed = []
for source, word in checks:
    if source not in expected:
        continue
    count = con.execute(
        "SELECT COUNT(*) FROM entries WHERE source = ? AND word = ?", (source, word)
    ).fetchone()[0]
    print("  %s 查 %s -> %d 条" % (source, word, count))
    if count < 1:
        failed.append("%s 查不到 %s" % (source, word))
if failed:
    print("中文抽查失败：%s" % "；".join(failed), file=sys.stderr)
    sys.exit(1)
print("中文抽查通过")
PY

if [ -d "$ASSETS" ]; then
    asset_files=$(find "$ASSETS" -type f | wc -l | tr -d ' ')
    asset_size=$(du -sh "$ASSETS" 2>/dev/null | cut -f1)
    echo "  assets：$asset_files 个文件，共 ${asset_size:-未知}"
fi

if [ -n "$ONLY" ]; then
    echo "调试模式（--only $ONLY）：已生成 $NEW，未替换 $DB"
    exit 0
fi

# 目标库若还带着旧的 -wal/-shm，替换主文件后会被误当成新库的日志，先清掉
rm -f "$DB-wal" "$DB-shm"
mv -f "$NEW" "$DB"
echo "完成：${DB}（$(du -h "$DB" | cut -f1)）"
