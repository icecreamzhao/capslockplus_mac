#!/usr/bin/env python3
"""从 mdd 里抽出词典排版资源（css / 图片 / 字体），供 App 用原版 HTML 渲染词条。

用法：
    python3 scripts/extract-dict-assets.py \
        --mdd "$HOME/Documents/dict/牛津高阶英汉/牛津高阶英汉双解词典（第9版）.mdd" --dict oalecd9 \
        --mdd "$HOME/Documents/dict/LDOCE/LongmanDictionaryOfContemporaryEnglish6thEnEn.mdd" --dict ldoce6 \
        --out "$HOME/.config/capslock-plus-mac/dict-assets"

只抽非音频文件（mp3 由 scripts/mdd-to-audio.py 负责），按 mdd 内路径落盘：
    \\accordion_concertina.jpg  ->  <out>/oalecd9/accordion_concertina.jpg
"""
import argparse
import os
import sys
import types

# readmdict 在 import 阶段硬依赖 lzo；这两本词典都是 zlib，塞个占位模块即可
if "lzo" not in sys.modules:
    _lzo = types.ModuleType("lzo")
    _lzo.LZO_VERSION_STRING = "stub"

    class _LzoError(Exception):
        pass

    _lzo.error = _LzoError
    sys.modules["lzo"] = _lzo

from readmdict import MDD  # noqa: E402

SKIP_EXT = {".mp3", ".wav", ".ogg", ".m4a"}


def normalize(key: bytes) -> str:
    name = key.decode("utf-8", "ignore")
    name = name.replace("\\", "/").lstrip("/")
    return name


def extract(mdd_path: str, dict_name: str, out_root: str, dry_run: bool) -> None:
    out_dir = os.path.join(out_root, dict_name)
    if not dry_run:
        os.makedirs(out_dir, exist_ok=True)

    total = 0
    written = 0
    bytes_written = 0
    by_ext = {}

    for key, data in MDD(mdd_path).items():
        total += 1
        rel = normalize(key)
        ext = os.path.splitext(rel)[1].lower()
        if ext in SKIP_EXT or not rel:
            continue
        by_ext[ext] = by_ext.get(ext, 0) + 1
        if dry_run:
            continue
        dest = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as handle:
            handle.write(data)
        written += 1
        bytes_written += len(data)

    summary = ", ".join("%s=%d" % (k or "(none)", v) for k, v in sorted(by_ext.items(), key=lambda kv: -kv[1]))
    print("[%s] scanned=%d written=%d size=%.1fMB ext(%s)" % (
        dict_name, total, written, bytes_written / 1024 / 1024, summary))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mdd", action="append", required=True, help="可重复：mdd 路径")
    parser.add_argument("--dict", action="append", required=True, help="可重复：对应的词典短名（与 --mdd 顺序一致）")
    parser.add_argument("--out", required=True, help="输出根目录")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if len(args.mdd) != len(args.dict):
        print("--mdd 与 --dict 数量必须一致", file=sys.stderr)
        return 2

    for mdd_path, dict_name in zip(args.mdd, args.dict):
        if not os.path.exists(mdd_path):
            print("找不到 %s" % mdd_path, file=sys.stderr)
            return 2
        extract(mdd_path, dict_name, args.out, args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
