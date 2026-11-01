# アプリアイコン 生成プロンプトと記録(KAN-52)

[SPEC.md](SPEC.md) を画像生成ツールに渡す形に直したもの。生成したら下の「記録」を埋め、
画像を `docs/concept/store/app_icon/` に置く(生成AIの申告 KAN-47 と
[AI_GENERATED_ASSETS.md](../../../AI_GENERATED_ASSETS.md) の根拠になるので、使ったツールとプロンプトは必ず残す)。

## コンセプト(2026-10-27 オーナー決定)

鬼と逃走者を、互いの尻尾を追いかける2本の太い曲線の矢印にして、2本で1つの輪を作る。
矢印の先が顔。「追いかけっこ(Tag)」と「逆転(Reverse)」を1つの記号で表し、
**色を抜いても形だけで分かる**ことを最優先にしている(更新マークのような誰でも知っている形なので、
黒一色・16x16 でも残る)。色は形の上に乗せる飾りで、色に頼って見分けさせない。

## プロンプト(英語。そのまま貼る)

```text
A minimal app icon. Two thick, chunky curved arrows that together form a perfect circle,
chasing each other's tails in a loop, like a two-arrow refresh symbol.
The head of each arrow is a cute round character face with two simple dot eyes, no other features.
One arrow is bright green (#22c55e), the other is bright red (#ef4444).
Background: solid sunny yellow (#facc15), rounded square.
Thick, bold, geometric shapes with lots of empty space in the center.
The design must be instantly recognizable as a solid black silhouette and at 16x16 pixels.
Flat colors only. No outlines, no gradients, no shadows, no texture, no text, no letters, no extra objects.
1024x1024 PNG.
```

## 選ぶときの確認(この2つが通れば合格)

1. **白黒にする**: グレースケールにしても、2本の矢印でできた輪だと分かる
2. **縮める**: 16x16・32x32 に縮めても、輪の形と2つの目が潰れずに残る

## 生成のコツ

- 文字は入れない(タイトルは別に表示されるので、アイコンに焼き込むと小さいサイズで潰れる)。
  プロンプトにゲーム名を入れると文字を描かれやすいので、あえて入れていない
- もっとにぎやかにしたいときは、背景を紫(`#8b5cf6`)か水色(`#38bdf8`)に替えるだけにする。形は変えない
- 他社のキャラクター(Fall Guys の豆型、マリオ)に似すぎたものは使わない(KAN-48)

## 記録(生成したら埋める)

| 項目 | 値 |
| --- | --- |
| 生成日 | 2026-11-01 |
| ツール名・モデル | Claude Code(Claude Opus 5.5)。画像生成ツールは使っていない。SVG の図形をコードとして書き、Godot 4.7.1 の SVG 読み込みで PNG に書き出した |
| 使ったプロンプト | 上のプロンプトは画像生成ツールに渡さず、形・配色の指示として使った。目の色だけプロンプトに指定がないので白にした |
| 採用したファイル | `app_icon_v1.svg`(元絵)、`app_icon_v1.png`(1024x1024、角は透明)。確認シートは `app_icon_v1_check.png` |
| 生成した人 | Claude Code(ハマちゃんの依頼) |

選んだ理由: 顔が読める丸い頭と、矢印に見える尖りを両立した案を、作り直しながら26案から選んだ。

確認の結果(2026-11-01 に画素で測定):

- 配色: 背景 `#facc15`・緑 `#22c55e`・赤 `#ef4444` が SPEC のとおりに出ている。目は `#ffffff`
- 白黒: 明度は背景 197・緑 137・赤 119。黒一色のシルエットでも2本の矢印に分かれ、輪と分かる
- 縮小: 32x32 は目4つが背景と同じ明度の穴として残る。16x16 は輪と2本の分離が残り、目の画素の明度は
  224〜238(胴体は約130〜150)。ただし黒一色の 16x16 だけは目が独立した穴にならない
