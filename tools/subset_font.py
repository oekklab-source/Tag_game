"""日本語フォントを JIS X 0208 第一水準へサブセットする。

Godot の既定フォントは日本語グリフを持たないので UI 用に同梱する必要があるが、
M PLUS Rounded 1c は全部入りで 3.4 MB あり、Web 公開だと無視できない。
常用漢字を全部含む第一水準まで削ると半分以下になり、それでも
「普通の日本語を書いていて字が出ない」ことは起きない。

    python tools/subset_font.py <入力.ttf> <出力.ttf>
"""

import subprocess
import sys
import tempfile
from pathlib import Path


def wanted_chars() -> str:
    """Shift_JIS の2バイト領域を総当たりして第一水準・かな・記号を集める。"""
    chars = set()
    for hi in range(0x81, 0x99):
        for lo in list(range(0x40, 0x7F)) + list(range(0x80, 0xFD)):
            try:
                chars.add(bytes([hi, lo]).decode("shift_jis"))
            except UnicodeDecodeError:
                pass
    chars.update(chr(c) for c in range(0x20, 0x7F))  # ASCII
    chars.update("→←↑↓★☆●○◆■□▲▼※─│┌┐└┘")
    return "".join(sorted(chars))


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    with tempfile.NamedTemporaryFile("w", suffix=".txt", encoding="utf-8",
                                     delete=False) as f:
        f.write(wanted_chars())
        listing = f.name
    subprocess.run([
        sys.executable, "-m", "fontTools.subset", str(src),
        f"--text-file={listing}", "--layout-features=", "--no-hinting",
        "--desubroutinize", f"--output-file={dst}",
    ], check=True)
    print("%.2f MB -> %.2f MB" % (src.stat().st_size / 1048576,
                                  dst.stat().st_size / 1048576))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
