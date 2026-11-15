# ストア画像用のフォント（製品には入らない）

カバー画像の別案（`tools/blender/build_cover_concepts.py` の案 E〜I、KAN-89）で、作風に合わせたタイトルの文字を描くためだけに使う。
`tools/blender/` は `.gdignore` で Godot から見えないので、**ゲームの書き出し（pck）には入らない**。
ゲームの画面の文字は今までどおり `ui/fonts/MPLUSRounded1c-Bold.ttf`。

どれも SIL Open Font License 1.1。フォントで描いた画像（カバー画像）には、OFL の表示義務はかからない。
フォントそのものを配るときは、同じフォルダの OFL 本文を一緒に配ること（`Limelight` と `Press Start 2P` は Reserved Font Name 付き。
改変したらその名前では配れない）。

| ファイル | 使う案 | ライセンス本文 | 入手元（2026-11-10 に取得） |
|---|---|---|---|
| `PressStart2P-Regular.ttf` | E ドット絵 | `OFL_pressstart2p.txt` | https://github.com/google/fonts/raw/main/ofl/pressstart2p/PressStart2P-Regular.ttf |
| `Poppins-Light.ttf` | G 今風ミニマル | `OFL_poppins.txt` | https://github.com/google/fonts/raw/main/ofl/poppins/Poppins-Light.ttf |
| `Poppins-ExtraBoldItalic.ttf` | F 80年代アーケード（REVERSE） | `OFL_poppins.txt` | https://github.com/google/fonts/raw/main/ofl/poppins/Poppins-ExtraBoldItalic.ttf |
| `Poppins-BlackItalic.ttf` | F（TAG!）・I 疾走感 | `OFL_poppins.txt` | https://github.com/google/fonts/raw/main/ofl/poppins/Poppins-BlackItalic.ttf |
| `Limelight-Regular.ttf` | H 近代の広告ポスター | `OFL_limelight.txt` | https://github.com/google/fonts/raw/main/ofl/limelight/Limelight-Regular.ttf |
