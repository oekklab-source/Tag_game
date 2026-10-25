# アプリアイコン 生成プロンプトと記録(KAN-52)

[SPEC.md](SPEC.md) を画像生成ツールに渡す形に直したもの。生成したら下の「記録」を埋め、
画像を `docs/concept/store/app_icon/` に置く(生成AIの申告 KAN-47 と
[AI_GENERATED_ASSETS.md](../../../AI_GENERATED_ASSETS.md) の根拠になるので、使ったツールとプロンプトは必ず残す)。

## プロンプト(英語。そのまま貼る)

```text
A square app icon for a casual 3D online game of tag (one runner chased by several chasers).
Flat, bold, high-contrast vector style with thick shapes and no fine details,
so the silhouette is still readable at 16x16 pixels.
Background: solid navy #2b3a67, rounded square.
Center: one cute round green (#4ade80) runner character, leaning forward as if dashing away,
with a single big white (#ffffff) motion swoosh behind it.
Behind the runner, peeking in from one edge, the top of one red (#ef4444) chaser character
with a simple surprised eye, much smaller than the runner.
Only these three colors plus white. No text, no letters, no numbers, no logo,
no weapons, no violence, no gradients, no drop shadows, no thin outlines.
1024x1024 PNG.
```

## 生成のコツ

- 文字は入れない(タイトルは別に表示されるので、アイコンに焼き込むと小さいサイズで潰れる)。
  プロンプトにゲーム名を入れると文字を描かれやすいので、あえて入れていない
- 生成したら 16x16・32x32 に縮小して見比べ、緑と赤の形が見分けられるものを選ぶ
- 他社のキャラクター(Fall Guys の豆型、マリオ)に似すぎたものは使わない(KAN-48)

## 記録(生成したら埋める)

| 項目 | 値 |
|---|---|
| 生成日 | |
| ツール名・モデル | |
| 使ったプロンプト | 上のまま / 変えた場合はここに全文 |
| 採用したファイル | `docs/concept/store/app_icon/` 配下のファイル名 |
| 生成した人 | |
