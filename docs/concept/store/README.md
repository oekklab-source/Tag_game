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


## `docs/concept/` にバイナリを置くときのルール（Phase 3 L-11、2026-09-25）

`docs/` 直下には**空の `.gdignore` を置いてある**。Godot はこのファイルがあるフォルダを
リソース系から丸ごと無視するので、ここに置いた PNG / OGG / MP3 は
`.import` が作られず、書き出しビルド(`export_presets.cfg` は Web / Windows とも
`export_filter="all_resources"`)にも入らない。`tools/blender/.gdignore` と同じ手法。

**この仕組みが効いていることを前提に、以下を守ること:**

1. **`docs/concept/` に置いたバイナリの `.import` を git に追加しない。**
   `.gdignore` がある限り生成されないが、`.gdignore` を消したり別の場所へ移したりすると
   復活する。`.import` が git に入っている = 書き出しに同梱されている、と考えてよい。
2. **既に `assets/` にあるものを `docs/concept/` へコピーしない。**
   2026-09-25 時点で `docs/concept/audio/title_bgm/title_bgm_concept.ogg` は
   `assets/audio/bgm/title_bgm.ogg` と MD5 が完全一致している(`F87494BC...`)。
   git 履歴からは消えないので残しているが、**これ以上増やさない**。
   参考音源を残したい場合は、実装に使ったファイルへのパスを SPEC.md に書くだけにする。
3. 新しくバイナリを足したら、`godot --headless --export-release "Web" <出力先>` を回して
   `index.pck` のサイズが増えていないことを確認する。Web版はこれをブラウザに
   ダウンロードさせるので、C-07(スマホのブラウザで遊ぶ)の狙いに直接効く。

### 経緯

2026-09-24 の差分レビュー(RV-07)で、`docs/concept/` 配下の約 11.7 MiB
(スクリーンショット5枚 ≈ 4.7 MiB + `.ogg` 3.5 MiB + `.mp3` 3.6 MiB)が
**Web / Windows 両方の書き出しに同梱されている**ことが判明した。
`.import` サイドカーが git 管理下にあったため、`export_filter="all_resources"` が
そのまま拾っていた。L-11 で `docs/.gdignore` を置き、`.import` 7個を削除して解消した。
