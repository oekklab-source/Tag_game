# ストア素材の置き場(itch.io配信準備、Phase 5)

`docs/concept/audio/`(音楽制作パイプライン)と同じ規約を画像・掲載文にも適用する。

## 対象素材と方針

| 成果物 | 生成手段 | 置き場 |
|---|---|---|
| カバー画像(630x500) | 画像生成ツールへ委譲 | `cover_image/` |
| アプリアイコン | 画像生成ツールへ委譲 | `app_icon/` |
| 公開用スクリーンショット | Claude Codeが既存`tests/uishot.tscn`で自給 | `screenshots/` |
| ストアページ掲載文(日本語) | Claude Codeが執筆 | `itchio_page_ja.md` |

## 守ること

- `assets/`には置かない(ストア素材はゲームに組み込まないため。アイコンだけは例外で、
  最終的にリポジトリルートの`icon.svg`/`icon.ico`へ入る)。
- `docs/`直下は正式文書のみなので、作業ファイルは必ず`docs/concept/store/`以下に置く。
- 既存ファイルは上書きせず、日付見出しで末尾に追記する(`docs/concept/audio/title_bgm/SPEC.md`
  の「2026-09-14 追記」方式を踏襲)。
- **`REVIEW.md`がPASSでない画像は、Claude CodeがitchIoへのアップロード手順に載せない**
  (`.agents/rules/audio-pipeline-rules.md`の組み込みゲートと同じ考え方)。

## 委譲の器(`.agents/workflows/tag-art.md`等)について

今回は新設しない。委譲先ツールがまだ決まっておらず、音楽パイプラインも実地で
Antigravity→Web版Geminiへ委譲先を移管した経緯があるため、先に器だけ作ると無駄になる。
将来必要になったときの叩き台は`tag-game-ux-fix-roadmap.md`のPhase 5セクション(I4-1)を参照。

## Steam向け素材(Phase 4 P1-3/P1-4、2026-09-22追記)

itch.io向け素材と同じ方針をSteam向けにも適用する。P1-1/P1-2(パートナー登録・$100支払い)は
ユーザー自身のアカウント/金銭操作が必須なため、Claude Codeが下書きできる範囲のみ先行して用意した。

| 成果物 | 生成手段 | 置き場 |
|---|---|---|
| ストアページ掲載文(日本語) | Claude Codeが執筆(`itchio_page_ja.md`を土台にSteam固有フィールドへ組み替え) | `steam_page_ja.md` |
| キャプセル/ライブラリ画像8種の仕様書 | Claude Codeが執筆、画像本体の生成は画像生成ツールへ委譲 | `steam_capsules/SPEC.md` |
| Content Survey(年齢レーティング調査)回答案 | Claude Codeが実装コード調査に基づき執筆 | `../STEAM_CONTENT_SURVEY_DRAFT.md`(`docs/`直下、EULA/TOKUSHOHOと同格) |

既存のスクリーンショット5枚(`screenshots/`)はSteamの要件(最低5枚・最低1920×1080・16:9)を
実測で満たすため、Steam向けに撮り直していない(`steam_page_ja.md`参照)。
