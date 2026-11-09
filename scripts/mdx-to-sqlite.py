#!/usr/bin/env python3
"""把 mdx 词库转成 sqlite，供 CapslockPlusMac 离线查词。

用法：
    python3 scripts/mdx-to-sqlite.py --out dict.sqlite \
        --dict oalecd9="$HOME/Documents/dict/牛津高阶英汉/牛津高阶英汉双解词典（第9版）.mdx" \
        --dict ldoce6="$HOME/Documents/dict/LDOCE/LongmanDictionaryOfContemporaryEnglish6thEnEn.mdx" \
        [--limit 3000] [--show abandon hello 你好]

要点：
- readmdict 会 import lzo，缺 python-lzo 直接 SystemExit；这里先塞一个占位模块，
  只有真遇到 LZO 压缩块才会报错（这两本都是 zlib）。
- mdx 里同一词条常有重复（牛津 205k 条对应约 100k 词），按小写 key 去重，保留第一条。
- 正文抽成纯文本行，形如 "verb\t（不顾责任等）离弃，遗弃，抛弃"，
  App 里直接按行渲染，不需要再解析 HTML。
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--dict", action="append", required=True, help="label=path.mdx")
    parser.add_argument("--limit", type=int, default=0, help="只处理前 N 条，用于试跑")
    parser.add_argument("--show", nargs="*", default=[], help="转换后打印这些词的解析结果")
    args = parser.parse_args()

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
    conn.execute("CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)")

    for spec in args.dict:
        label, _, path = spec.partition("=")
        extractor = EXTRACTORS.get(label)
        if extractor is None:
            sys.exit(f"没有为 {label} 写解析器（可选：{', '.join(EXTRACTORS)}）")

        started = time.time()
        mdict = MDX(path)
        rows = []
        seen = set()
        total = 0
        for key, value in mdict.items():
            total += 1
            if args.limit and total > args.limit:
                break
            headword = key.decode("utf-8", "replace").lstrip("\ufeff").strip()
            if not headword or len(headword) > 40:
                continue
            lookup = headword.lower()
            if lookup in seen:
                continue
            html_text = value.decode("utf-8", "replace")
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
        conn.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", (f"count_{label}", str(len(rows))))
        conn.commit()
        print(f"{label}: 读入 {total} 条 → 落库 {len(rows)} 条，用时 {time.time() - started:.1f}s")

    conn.execute("CREATE INDEX IF NOT EXISTS idx_word ON entries(word)")
    conn.commit()

    for word in args.show:
        rows = conn.execute(
            "SELECT source, headword, phonetic, body, audio_bre FROM entries WHERE word=?",
            (word.lower(),),
        ).fetchall()
        print(f"\n########## {word} -> {len(rows)} hit(s)")
        for source, headword, phonetic, body, audio_bre in rows:
            print(f"[{source}] {headword} /{phonetic or '-'}/ audio={audio_bre or '-'}")
            for line in body.splitlines()[:8]:
                print("   ", line)

    # 收尾切回普通日志模式并整理一遍，避免留下 -wal/-shm
    conn.execute("PRAGMA journal_mode=DELETE")
    conn.execute("VACUUM")
    conn.commit()

    counts = conn.execute("SELECT source, COUNT(*) FROM entries GROUP BY source").fetchall()
    print("\n合计：", counts)
    conn.close()


if __name__ == "__main__":
    main()
