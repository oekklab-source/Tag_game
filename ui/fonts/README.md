# 同梱フォント

`MPLUSRounded1c-Bold.ttf` — M PLUS Rounded 1c Bold（SIL Open Font License 1.1、`OFL.txt`）

Godot の既定フォントは日本語のグリフを持たないため、UI が全て豆腐（□）になる。
丸ゴシックなのでポップな見た目（`ui/pop_theme.tres`）と相性が良い。

配布サイズを抑えるため **JIS X 0208 第一水準 + かな + 記号 + ASCII に
サブセット済み**（3.38 MB -> 1.62 MB）。常用漢字はすべて含まれるので
通常の日本語なら不足しない。

再生成する場合:

```bash
pip install fonttools
python tools/subset_font.py <元の MPLUSRounded1c-Bold.ttf> ui/fonts/MPLUSRounded1c-Bold.ttf
```

元ファイルの入手元:
https://github.com/google/fonts/raw/main/ofl/mplusrounded1c/MPLUSRounded1c-Bold.ttf
