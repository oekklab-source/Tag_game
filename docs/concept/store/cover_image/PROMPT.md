# カバー画像 生成プロンプトと記録(KAN-54)

[SPEC.md](SPEC.md) を画像生成ツールに渡す形に直したもの。生成したら下の「記録」を埋め、
画像を `docs/concept/store/cover_image/` に置く(生成AIの申告 KAN-47 の根拠になるので、
使ったツールとプロンプトは必ず残す)。

## 構図の考え方

アイコン([../app_icon/SPEC.md](../app_icon/SPEC.md))と同じ緑の逃走者・赤い鬼・黄色を使い、
ストア一覧でアイコンとカバーが同じゲームだと分かるようにする。主題は本作の核心ルール
「鬼は目で見たときしか逃走者の位置を知らない」で、**壁の陰に隠れた逃走者と、反対を向いて探している鬼**を
1枚に入れる。見る人が「鬼からは見えていない」と一目で分かる位置関係にする。

## プロンプト(英語。そのまま貼る)

```text
A bright, colorful, playful cover illustration for a casual 3D online game of tag.
Wide landscape image, 630x500 aspect ratio (5:4), clean flat 3D toy-like style with soft lighting.
Setting: a cheerful terraced playground map with candy-colored zones (lime green, sky blue, purple, pink),
a big slide and a glowing striped dash panel on the ground, under a sunny sky.
Left foreground: one cute round green (#22c55e) runner character hiding behind a low yellow (#facc15) wall,
peeking out with a sneaky smile.
Right background: two cute round red (#ef4444) chaser characters looking around in the opposite direction,
with big curious eyes, clearly not seeing the runner.
Simple shapes, big readable characters, lots of color but an uncluttered composition.
No text, no letters, no numbers, no logo, no weapons, no violence, no vehicles, no night or horror mood.
```

## 生成のコツ

- **文字は画像生成で焼き込まない**(生成ツールは日本語も英語も崩しやすい)。タイトル「Reverse Tag!」を入れた版が
  必要になったら、文字なしの画像を作ってから、画像編集ソフトでロゴ文字を重ねる。重ねる場所として、
  画面上部の空(そら)を空けておくとよい
- 630x500 ぴったりで出せないツールでは、1260x1000 など同じ比率(5:4)で作って縮小する。最小は 315x250
- itch.io の一覧では小さく表示されるので、縮小しても「隠れる緑・探す赤」が分かるものを選ぶ
- 他社のキャラクター(Fall Guys の豆型、マリオ)や他社ゲームの画面に似すぎたものは使わない(KAN-48)

## 記録(生成したら埋める)

| 項目 | 値 |
| --- | --- |
| 生成日 | 2026-11-01 |
| ツール名・モデル | Claude Code(Claude Opus 5.5)。画像生成ツールは使っていない。Blender のスクリプト `tools/blender/build_cover_art.py` でシーンを組み、Blender 5.2 の EEVEE で書き出した。キャラは `tools/blender/fallguy.blend` のゲーム内モデル |
| 使ったプロンプト | 上のプロンプトは画像生成ツールに渡さず、構図・配色の指示として使った |
| 採用したファイル | `cover_v1.png`(文字なし)、`cover_v1_title.png`(タイトル入り) |
| 文字入れ | `cover_v1_title.png` のみあり。ゲームのロゴ `ui/logo/reverse_tag_logo.png` を Python(Pillow)で重ねた |
| 生成した人 | Claude Code(ハマちゃんの依頼) |

## 2026-11-10 追記: 別案4つ（KAN-87）

| 項目 | 値 |
| --- | --- |
| 生成日 | 2026-11-10 |
| ツール名・モデル | Claude Code（Claude Opus 5.5）。画像生成ツールは使っていない。Blender のスクリプト `tools/blender/build_cover_concepts.py` でシーンを組み、Blender 5.2 の EEVEE で書き出した。キャラ・帽子・小物はゲームの `.blend` |
| 使ったプロンプト | なし（上のプロンプトは使っていない）。構図は itch.io の人気作のカバーから読み取った原則（[CONCEPTS.md](CONCEPTS.md)）と SPEC の配色で決めた |
| 作ったファイル | `cover_v2a_close_call.png`・`cover_v2b_reverse.png`・`cover_v2c_playground.png`・`cover_v2d_team_up.png`（どれもタイトル入り）、比較用の `cover_v2_sheet.png` |
| 文字入れ | 4案ともあり。ロゴの画像を重ねたのではなく、ロゴと同じ作り方（`build_ui_art.py` の立体文字とふち取り）で案ごとに描いた |
| 生成した人 | Claude Code（mpahap76 の依頼） |

## 2026-11-10 追記: 作風を変えた5案（KAN-89）

| 項目 | 値 |
| --- | --- |
| 生成日 | 2026-11-10 |
| ツール名・モデル | Claude Code（Claude Opus 5.5）。画像生成ツールは使っていない。`tools/blender/build_cover_concepts.py`（案 e〜i）でシーンを組み、Blender 5.2 の EEVEE で書き出した |
| 使ったプロンプト | なし。構図は itch.io の作品のカバーから読み取った原則（[CONCEPTS.md](CONCEPTS.md) の「2026-11-10 追記」）で決めた |
| 作ったファイル | `cover_v2e_pixel.png`・`cover_v2f_arcade.png`・`cover_v2g_minimal.png`・`cover_v2h_poster.png`・`cover_v2i_speed.png`、比較用の `cover_v2_sheet_2.png` |
| 文字入れ | 5案ともあり。作風に合わせた OFL フォント（`tools/blender/fonts/`）で描いた |
| 生成した人 | Claude Code（mpahap76 の依頼） |

## 2026-11-10 追記: 採用（KAN-88）

| 項目 | 値 |
| --- | --- |
| 採用したファイル | `cover_v2a_close_call.png`（案 A。タイトル入り）。v1 は不採用に変わった |
| 決めた人 | mpahap76 |
