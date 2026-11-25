#!/usr/bin/env python3
"""把 mdx 词库转成 sqlite，供 CapslockPlusMac 离线查词。

用法：
    python3 scripts/mdx-to-sqlite.py --out dict.sqlite \
        --dict oalecd9="$HOME/Documents/dict/牛津高阶英汉/牛津高阶英汉双解词典（第9版）.mdx" \
        --dict ldoce6="$HOME/Documents/dict/LDOCE/LongmanDictionaryOfContemporaryEnglish6thEnEn.mdx" \
        --label oalecd9=牛津高阶 --label ldoce6=朗文 \
        [--css ldoce6=LongmanDictionaryOfContemporaryEnglish6thEnEn.css] \
        [--limit 3000] [--show abandon hello 你好] [--verify]

要点：
- readmdict 会 import lzo，缺 python-lzo 直接 SystemExit；这里先塞一个占位模块，
  只有真遇到 LZO 压缩块才会报错（这两本都是 zlib）。
- mdx 里同一词条常有重复（牛津 205k 条对应约 100k 词），按小写 key 去重，保留第一条。
- 正文抽成纯文本行，形如 "verb\t（不顾责任等）离弃，遗弃，抛弃"，
  App 里直接按行渲染，不需要再解析 HTML。
- 只有 oalecd9 / ldoce6 有专用解析器，其他词典走 extract_generic 兜底。
- 正文以 @@@LINK= 开头的条目是跳转条目：不进 entries，记进 aliases，
  全部词典写完后按 source 展开成正式词条。
"""

import argparse
import zlib
import html
import re
import sqlite3
import sys
import time
import types

# readmdict 硬依赖 python-lzo，但只有 LZO 压缩的词库才真的用到
if "lzo" not in sys.modules:
    stub = types.ModuleType("lzo")

    def _no_lzo(*_args, **_kwargs):
        raise RuntimeError("该词库使用 LZO 压缩，请先安装 python-lzo")

    stub.decompress = _no_lzo
    sys.modules["lzo"] = stub

from readmdict import MDX  # noqa: E402

TOKEN_RE = re.compile(r"<[^>]+>|[^<]+")
SYMBOLS = "🔑🔊◆●○■□▪▫★☆※"


def tokens(source):
    """把 HTML 切成 (类型, 值)：tag 或 text。"""
    for match in TOKEN_RE.finditer(source):
        chunk = match.group(0)
        if chunk.startswith("<"):
            yield "tag", chunk
        else:
            text = html.unescape(chunk)
            text = "".join(ch for ch in text if ch not in SYMBOLS)
            text = text.replace("\r", " ").replace("\n", " ").strip()
            if text:
                yield "text", text


def tag_name(tag):
    name = tag.strip("<>").split()[0].lstrip("/").lower()
    return name


def attr(tag, name):
    match = re.search(name + r'\s*=\s*"([^"]*)"', tag)
    return match.group(1) if match else None


def clean(text):
    text = re.sub(r"\s+", " ", text).strip()
    return text


# ---------------------------------------------------------------- 牛津高阶

def extract_oalecd(source):
    """返回 (phonetic, body_lines, audio_bre, audio_ame)。

    牛津的标签不是标准 HTML：<pos> 词性、<def> 释义、<chn> 中文、
    <x ... wd="例句原文"> 例句、<phon> 音标。
    """
    phonetic = None
    senses = []          # [(pos, 中文释义)]
    examples = []        # [(英文例句, 中文翻译)]
    pos = None
    depth_chn = 0
    depth_def = 0
    in_example = False
    example_en = None
    example_zh = None
    buffer = ""
    capture = None       # 'pos' / 'chn' / 'phon'

    for kind, value in tokens(source):
        if kind == "text":
            if capture:
                buffer += value
            continue

        name = tag_name(value)
        closing = value.startswith("</")

        if name == "pos" and not closing:
            capture, buffer = "pos", ""
        elif name == "pos" and closing:
            if capture == "pos":
                pos = clean(buffer) or pos
            capture = None
        elif name == "phon" and not closing and phonetic is None:
            capture, buffer = "phon", ""
        elif name == "phon" and closing:
            if capture == "phon":
                phonetic = clean(buffer)
            capture = None
        elif name == "def" and not closing:
            depth_def += 1
        elif name == "def" and closing:
            depth_def = max(0, depth_def - 1)
        elif name == "x" and not closing:
            in_example = True
            example_en = attr(value, "wd")
            example_zh = None
        elif name == "x" and closing:
            if example_en and example_zh:
                examples.append((clean(example_en), clean(example_zh)))
            in_example = False
            example_en = None
            example_zh = None
        elif name == "chn" and not closing:
            depth_chn += 1
            capture, buffer = ("example" if in_example else "sense"), ""
        elif name == "chn" and closing:
            depth_chn = max(0, depth_chn - 1)
            if capture == "example":
                example_zh = clean(buffer)
            elif capture == "sense":
                text = clean(buffer)
                if text and len(text) < 200:
                    senses.append((pos, text))
            capture = None

    lines = []
    seen = set()
    last_pos = None
    for sense_pos, text in senses:
        label = sense_pos or last_pos
        last_pos = sense_pos or last_pos
        key = (label, text)
        if key in seen:
            continue
        seen.add(key)
        if label and label != last_pos:
            pass
        prefix = f"{label}\t" if label else ""
        lines.append(prefix + text)
        if len(lines) >= 12:
            break

    for en, zh in examples[:3]:
        lines.append(f"例\t{en} {zh}")

    return phonetic, lines, None, None


# ---------------------------------------------------------------- 朗文 LDOCE6

def extract_ldoce(source):
    """返回 (phonetic, body_lines, audio_bre, audio_ame)。"""
    phonetic = None
    pos = None
    senses = []
    examples = []
    capture = None
    buffer = ""
    depth = 0
    skip_depth = 0
    stack = []

    audio_bre = None
    audio_ame = None
    for match in re.finditer(r'sound://([^"]+\.mp3)', source):
        path = match.group(1)
        if audio_bre is None and "/bre/" in path:
            audio_bre = path
        elif audio_ame is None and "/ame/" in path:
            audio_ame = path

    # 这些容器里的内容（同义词、搭配、短语、语法框）对查词卡片没用，整块跳过
    NOISE = ("thes", "syn", "colloc", "collocation", "phrase", "gram", "wsexa", "signpost", "freq")

    for kind, value in tokens(source):
        if kind == "text":
            if capture:
                buffer += value
            continue

        name = tag_name(value)
        closing = value.startswith("</")
        current_class = attr(value, "class") or ""
        classes = current_class.split()

        if name == "span":
            if closing:
                if stack:
                    stack.pop()
                if skip_depth > 0:
                    skip_depth -= 1
                    continue
                if capture in ("pron", "pos", "def", "example") and depth > 0:
                    depth -= 1
                    if depth == 0:
                        text = clean(buffer)
                        if capture == "pron" and phonetic is None:
                            phonetic = text.strip("/ ")
                        elif capture == "pos" and text:
                            pos = text.strip(" ,.;")
                        elif capture == "def" and text:
                            senses.append((pos, text))
                        elif capture == "example" and text:
                            examples.append(text)
                        capture = None
                        buffer = ""
                continue

            stack.append(classes)
            if skip_depth > 0:
                skip_depth += 1
                continue
            if any(token in classes for token in NOISE):
                skip_depth = 1
                continue
            wanted = None
            if "pron" in classes:
                wanted = "pron"
            elif "pos" in classes:
                wanted = "pos"
            elif "def" in classes:
                wanted = "def"
            elif "example" in classes:
                wanted = "example"
            if wanted:
                if depth == 0:
                    capture, buffer = wanted, ""
                depth += 1

    lines = []
    seen = set()
    seen_text = set()
    for sense_pos, text in senses:
        if (sense_pos, text) in seen or text in seen_text:
            continue
        seen.add((sense_pos, text))
        seen_text.add(text)
        prefix = f"{sense_pos}\t" if sense_pos else ""
        lines.append(prefix + text)
        if len(lines) >= 10:
            break
    for example in examples[:3]:
        lines.append(f"例\t{example}")
    return phonetic, lines, audio_bre, audio_ame


def deflate(text: str) -> bytes:
    """raw deflate（无 zlib 头），Swift 的 NSData.decompressed(using: .zlib) 要的就是这个格式。"""
    compressor = zlib.compressobj(6, zlib.DEFLATED, -15)
    return compressor.compress(text.encode("utf-8")) + compressor.flush()


EXTRACTORS = {
    "oalecd9": extract_oalecd,
    "ldoce6": extract_ldoce,
}


# ---------------------------------------------------------------- 通用解析

BLOCK_TAGS = {
    "address", "article", "aside", "blockquote", "br", "dd", "div", "dl",
    "dt", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4",
    "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre",
    "section", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
}
DECOR = "·•∙‧・◇◆●○■□▪▫★☆※→←↑↓▸▹►▻"
TAG_RE = re.compile(r"<[^>]+>")

# 兜底音标：先找 class 里带 phonetic 的 span，再找 PRON/PRONS
PHONETIC_PATTERNS = (
    re.compile(r'<span class="[^"]*phonetic[^"]*"[^>]*>(.*?)</span>', re.S | re.I),
    re.compile(r'<span class="PRONS?[^"]*"[^>]*>(.*?)</span>', re.S | re.I),
)


def strip_tags(fragment):
    return clean(html.unescape(TAG_RE.sub(" ", fragment)))


def block_tag_name(tag):
    """<div ...> / </div> / <br/> 都归一成 div / br。"""
    return tag.strip("<>").split()[0].strip("/").lower()


def extract_generic(source):
    """通用兜底解析器：常见音标写法 + 按块级标签断行。

    返回 (phonetic, body_lines, audio_bre, audio_ame)；v1 一律不出音频。
    """
    phonetic = None
    for pattern in PHONETIC_PATTERNS:
        match = pattern.search(source)
        if not match:
            continue
        value = strip_tags(match.group(1))
        if value:
            # 两侧的 / 或 [ ] 原样保留，如 /ˈæbəndən/
            phonetic = value
            break

    lines = []
    current = []
    skip_depth = 0

    def flush():
        if not current:
            return
        text = clean("".join(current)).strip(DECOR + " \t")
        current.clear()
        if text:
            lines.append(text)

    for kind, value in tokens(source):
        if kind == "text":
            if skip_depth == 0:
                current.append(value + " ")
            continue
        name = block_tag_name(value)
        closing = value.startswith("</")
        # 内联的 css/js 不是词条内容，整块跳过
        if name in ("script", "style"):
            if not closing:
                skip_depth += 1
            elif skip_depth:
                skip_depth -= 1
            continue
        if name in BLOCK_TAGS:
            flush()
    flush()

    return phonetic, lines, None, None


LINK_PREFIX = "@@@LINK="


def expand_aliases(conn):
    """把 aliases 在同 source 内展开成 entries 行；返回展开出的词条数。

    多跑几轮以支持 alias 指向 alias 的链式跳转，展不开的保持原样。
    """
    expanded = 0
    for _ in range(8):
        before = conn.total_changes
        conn.execute(
            """
            INSERT OR REPLACE INTO entries
                (word, source, headword, phonetic, body, audio_bre, audio_ame, html)
            SELECT a.word, e.source, e.headword, e.phonetic, e.body, e.audio_bre, e.audio_ame, e.html
            FROM aliases a
            JOIN entries e ON e.word = lower(a.target) AND e.source = a.source
            WHERE NOT EXISTS (
                SELECT 1 FROM entries x WHERE x.word = a.word AND x.source = a.source
            )
            """
        )
        moved = conn.total_changes - before
        expanded += moved
        if moved == 0:
            break
    return expanded


def parse_pairs(items):
    pairs = {}
    for item in items:
        name, sep, value = item.partition("=")
        if not sep or not name.strip():
            sys.exit(f"参数格式应为 name=value：{item}")
        pairs[name.strip()] = value.strip()
    return pairs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--dict", action="append", required=True, help="name=path.mdx，可重复")
    parser.add_argument("--label", action="append", default=[], help="name=中文显示名，与 --dict 对应")
    parser.add_argument("--css", action="append", default=[], help="name=主样式表文件名，与 --dict 对应")
    parser.add_argument("--limit", type=int, default=0, help="只处理前 N 条，用于试跑")
    parser.add_argument("--show", nargs="*", default=[], help="转换后打印这些词的解析结果")
    parser.add_argument("--verify", action="store_true", help="转换后打印每本词典的入库统计")
    args = parser.parse_args()

    specs = []
    for spec in args.dict:
        name, sep, path = spec.partition("=")
        if not sep or not name.strip() or not path.strip():
            sys.exit(f"--dict 格式应为 name=path.mdx：{spec}")
        specs.append((name.strip(), path.strip()))
    dict_names = {name for name, _ in specs}
    labels = parse_pairs(args.label)
    stylesheets = parse_pairs(args.css)
    for name in list(labels) + list(stylesheets):
        if name not in dict_names:
            print(f"警告：--label/--css 里的 {name} 不在本次 --dict 里，忽略", file=sys.stderr)
            labels.pop(name, None)
            stylesheets.pop(name, None)

    conn = sqlite3.connect(args.out)
    conn.execute("PRAGMA journal_mode=OFF")
    conn.execute("PRAGMA synchronous=OFF")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS entries(
            word TEXT NOT NULL,
            source TEXT NOT NULL,
            headword TEXT NOT NULL,
            phonetic TEXT,
            body TEXT NOT NULL,
            audio_bre TEXT,
            audio_ame TEXT,
            html BLOB,
            PRIMARY KEY(word, source)
        ) WITHOUT ROWID
    """)
    # 老库（没有 html 列）就地补列，不用删库重转
    existing = {row[1] for row in conn.execute("PRAGMA table_info(entries)")}
    if "html" not in existing:
        conn.execute("ALTER TABLE entries ADD COLUMN html BLOB")
        print("migrated: added column html")
    conn.execute("CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS aliases(
            word TEXT NOT NULL, target TEXT NOT NULL, source TEXT NOT NULL,
            PRIMARY KEY(word, source)
        ) WITHOUT ROWID
    """)

    processed = []
    for order, (label, path) in enumerate(specs):
        extractor = EXTRACTORS.get(label) or extract_generic

        started = time.time()
        mdict = MDX(path)
        rows = []
        aliases = []
        seen = set()
        alias_seen = set()
        total = 0
        for key, value in mdict.items():
            total += 1
            if args.limit and total > args.limit:
                break
            headword = key.decode("utf-8", "replace").lstrip("\ufeff").strip()
            if not headword or len(headword) > 40:
                continue
            lookup = headword.lower()
            if lookup in seen or lookup in alias_seen:
                continue
            html_text = value.decode("utf-8", "replace")
            # 跳转条目：只在 aliases 里记一笔，正文后面统一展开
            stripped = html_text.lstrip("\ufeff").strip()
            if stripped.startswith(LINK_PREFIX):
                target = clean(stripped[len(LINK_PREFIX):]).lower()
                if target:
                    alias_seen.add(lookup)
                    aliases.append((lookup, target, label))
                continue
            phonetic, lines, audio_bre, audio_ame = extractor(html_text)
            if not lines:
                continue
            seen.add(lookup)
            rows.append((lookup, label, headword, phonetic, "\n".join(lines), audio_bre, audio_ame,
                         deflate(html_text)))

        conn.executemany(
            "INSERT OR REPLACE INTO entries(word, source, headword, phonetic, body, audio_bre, audio_ame, html)"
            " VALUES (?,?,?,?,?,?,?,?)",
            rows,
        )
        conn.executemany(
            "INSERT OR REPLACE INTO aliases(word, target, source) VALUES (?,?,?)",
            aliases,
        )
        meta = {
            f"count_{label}": str(len(rows)),
            f"label_{label}": labels.get(label, label),
            f"order_{label}": str(order),
            f"css_{label}": stylesheets.get(label, ""),
        }
        conn.executemany("INSERT OR REPLACE INTO meta VALUES (?,?)", meta.items())
        conn.commit()
        processed.append(label)
        print(f"{label}: 读入 {total} 条 → 落库 {len(rows)} 条，跳转 {len(aliases)} 条，"
              f"用时 {time.time() - started:.1f}s")

    expanded = expand_aliases(conn)
    conn.commit()
    if expanded:
        print(f"alias 展开：新增 {expanded} 条词条")

    conn.execute("CREATE INDEX IF NOT EXISTS idx_word ON entries(word)")
    conn.commit()

    for word in args.show:
        rows = conn.execute(
            "SELECT source, headword, phonetic, body, audio_bre FROM entries WHERE word=?",
            (word.lower(),),
        ).fetchall()
        print(f"\n########## {word} -> {len(rows)} hit(s)")
        for source, headword, phonetic, body, audio_bre in rows:
            phonetic_text = phonetic or "-"
            if not phonetic_text.startswith(("/", "[")):
                phonetic_text = "/" + phonetic_text.strip("/") + "/"
            print(f"[{source}] {headword} {phonetic_text} audio={audio_bre or '-'}")
            for line in body.splitlines()[:8]:
                print("   ", line)

    if args.verify:
        print("\n===== verify =====")
        for label in processed:
            count, with_html = conn.execute(
                "SELECT COUNT(*), COALESCE(SUM(html IS NOT NULL AND length(html) > 0), 0)"
                " FROM entries WHERE source = ?",
                (label,),
            ).fetchone()
            values = dict(conn.execute(
                "SELECT k, v FROM meta WHERE k IN (?,?,?)",
                (f"label_{label}", f"order_{label}", f"css_{label}"),
            ).fetchall())
            alias_count = conn.execute(
                "SELECT COUNT(*) FROM aliases WHERE source = ?", (label,)
            ).fetchone()[0]
            print(f"source={label} label={values.get('label_' + label) or '-'} "
                  f"order={values.get('order_' + label) or '-'} "
                  f"entries={count} html={with_html} aliases={alias_count} "
                  f"css={values.get('css_' + label) or '-'}")

    # 收尾切回普通日志模式并整理一遍，避免留下 -wal/-shm
    conn.execute("PRAGMA journal_mode=DELETE")
    conn.execute("VACUUM")
    conn.commit()

    counts = conn.execute("SELECT source, COUNT(*) FROM entries GROUP BY source").fetchall()
    print("\n合计：", counts)
    conn.close()


if __name__ == "__main__":
    main()
