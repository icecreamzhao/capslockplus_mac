#!/usr/bin/env python3
"""把 mdx 里的原始词条 HTML 拼成一个能在浏览器里打开的预览页。

用途：确认「还原本地词库的颜色/表格/图片」到底长什么样，再决定要不要让 App 用
WKWebView 渲染原版 HTML。

用法：
    python3 scripts/dict-html-preview.py \
        --mdx "$HOME/Documents/dict/牛津高阶英汉/牛津高阶英汉双解词典（第9版）.mdx" \
        --dict oalecd9 \
        --assets "$HOME/.config/capslock-plus-mac/dict-assets/oalecd9" \
        --words hello abandon serendipity

依赖：pip3 install --user readmdict（离线的 lzo 用占位模块绕过，库里是 zlib）
输出：<assets>/preview-<dict>.html，并把每个词条单独写成 <assets>/__preview_<word>.html
"""
import argparse
import os
import re
import sys
import types
import zlib

if "lzo" not in sys.modules:
    _lzo = types.ModuleType("lzo")
    _lzo.LZO_VERSION_STRING = "stub"

    class _LzoError(Exception):
        pass

    _lzo.error = _LzoError
    sys.modules["lzo"] = _lzo

from readmdict import MDX  # noqa: E402

HEAD_RE = re.compile(r"^<head>(.*?)</head>", re.I | re.S)


def split_head(html: str):
    match = HEAD_RE.match(html)
    if not match:
        return "", html
    return match.group(1), html[match.end():]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mdx", required=True)
    parser.add_argument("--dict", required=True)
    parser.add_argument("--assets", required=True)
    parser.add_argument("--words", nargs="+", required=True)
    parser.add_argument("--size-sample", type=int, default=0, help="顺便统计 N 条词条 HTML 的压缩后体积")
    parser.add_argument("--css", default="", help="词条自己没有 <head> 时用它注入样式表（相对 assets 目录）")
    parser.add_argument("--js", default="", help="同上，注入脚本")
    args = parser.parse_args()

    wanted = {w.strip().lower(): w.strip() for w in args.words}
    found = {}
    head = ""
    samples = 0
    raw_bytes = 0
    zlib_bytes = 0

    for key, data in MDX(args.mdx).items():
        word = key.decode("utf-8", "ignore")
        lowered = word.strip().lower()
        if lowered in wanted and lowered not in found:
            html = data.decode("utf-8", "ignore")
            entry_head, body = split_head(html)
            if not head:
                head = entry_head
            found[lowered] = body
            if len(found) == len(wanted):
                if args.size_sample == 0:
                    break
        if args.size_sample and samples < args.size_sample:
            samples += 1
            raw_bytes += len(data)
            zlib_bytes += len(zlib.compress(data, 6))

    if not found:
        print("一个都没找到：%s" % ", ".join(sorted(wanted)), file=sys.stderr)
        return 1

    style = """
    <style>
      body { margin: 0; padding: 24px; background: #ffffff; font-family: -apple-system, "Helvetica Neue", sans-serif; }
      .card { max-width: 860px; margin: 0 auto 28px; padding: 20px 24px; border: 1px solid #e3e3e3; border-radius: 12px; }
      .card > .label { font: 600 11px/1 -apple-system; letter-spacing: .08em; color: #9a9a9a; text-transform: uppercase; margin-bottom: 12px; }
    </style>
    """

    if not head and args.css:
        head = '<link rel="stylesheet" type="text/css" href="%s" />' % args.css
        if args.js:
            head += '<script src="%s" charset="utf-8"></script>' % args.js

    cards = []
    for lowered, body in found.items():
        cards.append('<div class="card"><div class="label">%s · %s</div>%s</div>' % (args.dict, lowered, body))

    document = """<!doctype html><html><head><meta charset="utf-8"><title>%s 词条排版预览</title>%s%s</head>
<body>%s</body></html>""" % (args.dict, head, style, "\n".join(cards))

    os.makedirs(args.assets, exist_ok=True)
    out_path = os.path.join(args.assets, "preview-%s.html" % args.dict)
    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write(document)

    print("written=%s entries=%d" % (out_path, len(found)))
    if args.size_sample and samples:
        print("size sample: n=%d raw=%.1fKB avg=%.1fKB zlib=%.1fKB avg=%.1fKB" % (
            samples,
            raw_bytes / 1024,
            raw_bytes / 1024 / samples,
            zlib_bytes / 1024,
            zlib_bytes / 1024 / samples,
        ))
    return 0


if __name__ == "__main__":
    sys.exit(main())
