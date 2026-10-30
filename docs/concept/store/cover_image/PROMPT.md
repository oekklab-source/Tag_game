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
| 生成日 | |
| ツール名・モデル | |
| 使ったプロンプト | 上のまま / 変えた場合はここに全文 |
| 採用したファイル | `docs/concept/store/cover_image/` 配下のファイル名 |
| 文字入れ | なし / あり(使ったソフト) |
| 生成した人 | |
