# 生成AIを使った素材・成果物の一覧

itch.io の Generative AI disclosure（2024-11〜。Graphics / Sound / Text & Dialog / Code の別に申告する）と
Steam の Content Survey（`docs/STEAM_CONTENT_SURVEY_DRAFT.md` B 節）に答えるための元データ。
2026-10-16 時点の棚卸し（KAN-46）。**どう申告するかはオーナーが KAN-47（5.4）で決める**。ここは事実だけを書く。

**オーナー申告（2026-10-19、KAN-46）**: リポジトリの画像・音楽・3D モデル・コード・文書は、外部から取り込んだ第三者素材（§2）を除き、
**すべて生成AIで作ったもの**。記録からツール名が分かるものは表に書き、分からないものは「ツール名の記録なし」とした。

**この一覧を更新するとき**: 生成AIで作った素材をリポジトリに足したら、この表に1行足す。
特に、設定画を元に Blender で3D化した衣装・店員さんは「製品に残っているか」が「元絵は残らないが、形は元絵に由来する」
になる点に注意（§1 の Graphics の行）。

## 1. 一覧

| 素材 | 用途 | 生成ツール | 出典ファイル・記録 | 製品に残っているか | itch.io の区分 |
|---|---|---|---|---|---|
| `assets/audio/bgm/title_bgm.ogg` | タイトル・ロビー画面の BGM | Web 版 Gemini | `docs/concept/audio/title_bgm/SPEC.md`・`REVIEW.md`（2026-09-14 第4版で PASS） | **残る**（pck に同梱。KAN-30 の一覧で確認） | Sound |
| `tools/blender/references/overalls_turnaround_v1.png` | オーバーオール衣装の設定画（Blender で3D化する設計図） | 画像生成（`.prompt.txt` の記載は「built-in image_gen」。どのサービスかは記録が無い） | 同名の `overalls_turnaround_v1.prompt.txt`（プロンプト全文）、`overalls_review/REVIEW.md` | 画像そのものは**残らない**（`tools/blender/` は pck に入らない）。ただし製品の `assets/character/outfits/overalls.glb` は、この設定画を見て Blender スクリプトで作った | Graphics（間接） |
| `tools/blender/references/shadow_ninja_turnaround_v1.png` | 黒影忍者衣装の設定画 | 同上 | 同名の `.prompt.txt`、`shadow_ninja_review/REVIEW.md` | 同上（`shadow_ninja.glb` の元） | Graphics（間接） |
| `tools/blender/references/basketball_turnaround.png` | バスケ衣装の設定画。ショップ用プロンプトでは「ターンアラウンド資料の体裁の基準」として毎回添付する | 生成AI（オーナー申告 2026-10-19。ツール名の記録なし） | 2026-09-15 の 2c1d2b1 で追加（コミットメッセージは「参考画像」とだけ書いている） | 画像は残らない。`basketball_prototype.glb` の元 | Graphics（間接） |
| `tools/blender/reference.png` | 主人公（恐竜きぐるみ）のデザインの元絵。質感・配色・顔の基準で、ショップ用プロンプトにも毎回添付する | 生成AI（オーナー申告 2026-10-19。ツール名の記録なし） | 2026-08-21 の c0f961b で追加。README の構成表に「デザインの参考画像」とだけある | 画像は残らない。主人公モデル（`assets/character/fallguy.glb`）の見た目の基準 | Graphics（間接） |
| （予定）店員さんの設定画 `shopkeeper_turnaround.png` と、ショップ奥の壁の絵 | ショップの店員さんの専用モデル、壁の絵 | Gemini（予定） | `tools/blender/references/SHOP_ART_PROMPTS.md`、`scenes/shop_stage.gd` 冒頭のコメント | 未制作。壁の絵は `assets/` にコピーして**製品に入る**予定。店員さんは設定画から3D化する予定 | Graphics |
| （予定）カバー画像・アプリアイコン | itch.io のカバー画像（630×500）・exe とホーム画面のアイコン | 画像生成ツールに委譲する方針（ツールは未定） | `docs/concept/store/cover_image/SPEC.md`・`app_icon/SPEC.md` | 未制作。アイコンは**製品に入る**予定、カバー画像はストアページだけ | Graphics |
| ゲームのコード（GDScript・Workers・ツール類） | ゲーム本体・サーバー・ビルドとテストの道具 | Claude Code | git の履歴（2026-10-16 時点で全195コミット中151件に `Co-Authored-By: Claude`） | **残る** | Code |
| `icon.svg`（現在の仮アイコン）と、そこから書き出した `web/apple-touch-icon.png`・`icon-192.png`・`icon-512.png` | exe・Web 版のホーム画面のアイコン（正式なアイコンができるまでの仮） | Claude Code（SVG の図形をコードとして書いた。2026-07-07 の 43db939 ほか） | git の履歴、`web/README.md` | **残る**（正式なアイコンに差し替えるまで） | Graphics（Code の出力物とみなすかを 5.4 で判断） |
| 3D モデル・テクスチャを作る Blender スクリプト（`tools/blender/build_*.py`） | 製品の `.glb` と衣装のテクスチャを、スクリプトで一から組み立てる | Claude Code | 同上 | スクリプトは残らないが、出力の `.glb`・`.png` は**残る** | Code（出力物は Graphics とみなすかを 5.4 で判断） |
| ゲーム内の文言（日本語の UI 文言・`locale/en.po` の英訳） | 画面の表示 | Claude Code | 同上 | **残る** | Text & Dialog |
| 文書・ストア文面・法務文書の下書き | README・`docs/`・ストアページ（`docs/concept/store/*_page_ja.md`）・EULA 等の下書き | Claude Code | 各ファイルの冒頭（例: `itchio_page_ja.md` の「執筆: Claude Code」） | ストア文面はストアページに**残る**。法務文書は専門家の確認を経て確定する前提 | Text & Dialog |

## 2. 生成AIを使っていないもの

生成AIを使っていないのは、外部から取り込んだ第三者素材だけ。一覧とライセンスは `docs/THIRD_PARTY_LICENSES.md` を正とする
（フォント `ui/fonts/MPLUSRounded1c-Bold.ttf`、Godot エンジン、`addons/` のプラグイン等）。

- 3D モデル・テクスチャを外部から取り込んだものは無い（`docs/THIRD_PARTY_LICENSES.md` §4）。`assets/` の `.glb`・`.png` は
  すべて §1 の Blender スクリプトの出力
- 効果音は無い（BGM 1曲だけ）

## 3. 申告を決めるときの論点（KAN-47 向け）

- **Graphics**: 製品に生成画像そのものは入っていない（2026-10-16 時点）。ただし衣装2種は生成した設定画を見て3D化しており、
  予定の店員さん・壁の絵・アイコンが入ると直接の生成物も製品に入る
- **Sound**: タイトル BGM が生成物で、製品に入っている
- **Text & Dialog / Code**: 大半が Claude Code による
- `reference.png` と `basketball_turnaround.png` も生成AI製と確認できた（2026-10-19 オーナー申告）ので、Graphics の事実はこれで揃った。
  残る判断は、生成した設定画を見て作った 3D モデルや、コードとして書いた `icon.svg` を「Graphics に生成AIを使った」と申告するか
