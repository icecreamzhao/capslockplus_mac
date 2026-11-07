#!/usr/bin/env python3
"""从 mdd 里抽出单词读音 mp3（只要 \\hwd\\ 下的，不含例句音频）。

用法：
    python3 scripts/mdd-to-audio.py \
        --mdd "$HOME/Documents/dict/LDOCE/LongmanDictionaryOfContemporaryEnglish6thEnEn.mdd" \
        --out "$HOME/.config/capslock-plus-mac/audio" [--dry-run]

输出目录结构和字典里的路径一致：hwd/bre/7/abandon_v0205.mp3
"""

import argparse
import os
import sys
import time
import types

if "lzo" not in sys.modules:
    stub = types.ModuleType("lzo")

    def _no_lzo(*_args, **_kwargs):
        raise RuntimeError("该词库使用 LZO 压缩，请先安装 python-lzo")

    stub.decompress = _no_lzo
    sys.modules["lzo"] = stub

from readmdict import MDD  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mdd", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--prefix", default="hwd/")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    started = time.time()
    mdd = MDD(args.mdd)
    written = 0
    skipped = 0
    total_bytes = 0

    for key, data in mdd.items():
        name = key.decode("utf-8", "replace").lstrip("\\/").replace("\\", "/")
        if not name.lower().startswith(args.prefix) or not name.lower().endswith(".mp3"):
            skipped += 1
            continue
        written += 1
        total_bytes += len(data)
        if args.dry_run:
            continue
        destination = os.path.join(args.out, name)
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        with open(destination, "wb") as handle:
            handle.write(data)

    print(
        f"{'dry-run ' if args.dry_run else ''}抽出 {written} 个 mp3，"
        f"跳过 {skipped} 个，共 {total_bytes / 1024 / 1024:.1f} MB，"
        f"用时 {time.time() - started:.1f}s"
    )


if __name__ == "__main__":
    main()
