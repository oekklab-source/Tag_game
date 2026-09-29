# Steam キャプセル/ライブラリ画像 制作仕様書

## 概要

Steamストアページ・ライブラリ・おすすめ欄等に使われる画像アセット一式。Valveは用途ごとに
サイズの異なる画像を要求するため、[cover_image/SPEC.md](../cover_image/SPEC.md)(itch.io向け)
とは別に本書で一括して仕様化する。8種類あるが、キービジュアル(構図・配色)の元ネタは共通のため、
あえて1つの仕様書にまとめている(ファイルを8分割すると同じ構図説明を8回重複させることになるため)。

## 規格

出典: [Store Graphical Assets](https://partner.steamgames.com/doc/store/assets/standard)、
[Library Assets](https://partner.steamgames.com/doc/store/assets/libraryassets)
(いずれも確認日2026-09-22)。

| アセット | 寸法 | 用途・備考 |
|---|---|---|
| Header Capsule | 920 x 430 | ストアページ上部・「あなたへのおすすめ」等 |
| Small Capsule | 462 x 174 | 120x45・184x69へ自動縮小される。最小サイズでもロゴが読めること |
| Main Capsule | 1232 x 706 | ストアトップページのカルーセル |
| Vertical Capsule | 748 x 896 | セール・季節特集ページ |
| Page Background | 1438 x 810 | 省略可(省略時は最後のスクリーンショットから自動生成) |
| Library Capsule | 600 x 900 | Steamクライアントのライブラリ表示。300x450が自動生成される |
| Library Header | 920 x 430 | クライアントの「最近プレイしたゲーム」欄。Header Capsuleと近い構図でよい |
| Library Hero | 3840 x 1240 | セーフエリアは中央860x380(1920x620版へも自動縮小されるため、その範囲外に重要要素を置かない)。**文字を入れない** |
| Library Logo | 幅1280pxまたは高さ720px、透過PNG | タイトルロゴのみ。余分な文字・装飾を入れない |

全アセット共通のルール: 商品ロゴ/タイトルが視認できること、レビュースコア・受賞ロゴ・
セール割引率等をあらかじめ画像に焼き込まないこと。

## 構図

[cover_image/SPEC.md](../cover_image/SPEC.md)と同じ核となるテーマ——鬼(赤)と逃走者(緑)の
**非対称な対比**(「見えている側/見えていない側」「追う側/隠れる側」、README.mdの「## ルール」
参照)——をキーアート系のアセット(Header Capsule / Main Capsule / Vertical Capsule /
Library Header / Library Hero)に用いる。マップの雰囲気はマリオ風のカラフル・ポップ
(160×160mの段丘状マップ、ゾーンごとのテーマ色、滑り台・マンホール・ダッシュパネル等の
ギミック。詳細はREADME.mdの「## マップ」「## ギミック」参照)。

Small Capsule と Library Logo は上記のキーアートではなく、**ロゴのみ**の別処理とする
(前者は120x45まで縮小されるため絵柄では判別できず、後者はロゴ専用アセットのため)。

## 配色(正本)

[icon.svg](../../../../icon.svg)の実ファイルから確定した既存の記号を、cover_image/SPEC.mdと
同じく踏襲する:

- 背景: `#2b3a67`(紺)
- 逃走者: `#4ade80`(緑)
- 鬼: `#ef4444`(赤)
- 連結線・アクセント: `#ffffff`(白)

## 文字の扱い(重要・cover_image/SPEC.mdより強い制約)

itch.io向けのカバー画像は「文字なしで成立する構図」を許容していたが、Steamのキャプセル/
ライブラリ画像の多くは**ロゴ/タイトルが視認できることが要件そのもの**である(上記「規格」表の
共通ルール参照)。ただし、仮タイトル「3D Chase Game」は`project.godot`上の暫定名称で確定名
ではないため、**現時点ではロゴ入り版を本制作しない**。正式タイトル確定後、ロゴ入り版を別途
制作する(`tag-game-ux-fix-roadmap.md`のPhase 5「ユーザーのみが行える操作」I5-6と同じ
プレースホルダ運用)。それまでの間は、ロゴを必要としない構図(背景・キャラクターのみの
プレースホルダ)に留めるか、制作自体を正式タイトル確定後まで待つ。

## 禁止事項

実装や既存資料に無い要素を描かない(銃器・車両・ホラー調の夜景など)。このゲームは非対称の
鬼ごっこであり、戦闘・暴力表現は含まない。

## 出力先とレビューゲート

生成物は`docs/concept/store/steam_capsules/`配下に置く。`REVIEW.md`でPASSと判定されるまで、
Claude Codeはこれらの画像をSteamパートナーポータルへのアップロード手順に載せない
(`docs/concept/store/README.md`・`.agents/rules/audio-pipeline-rules.md`と同じ組み込みゲートの
考え方)。画像そのものの生成は外部の画像生成ツールへ委譲する(`docs/concept/store/README.md`の
既定方針、cover_image/app_iconと同様)。
