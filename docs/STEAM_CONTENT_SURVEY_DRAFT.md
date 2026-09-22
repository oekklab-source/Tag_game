# Steam Content Survey(年齢レーティング調査) 回答案ドラフト

> [!WARNING]
> 本ドキュメントは実装コード・既存資料の調査に基づく回答案の叩き台であり、正式な法的助言
> (リーガルアドバイス)ではありません。Steamworksパートナーポータルでの実際の提出前に、
> 内容を必ず見直し、末尾の「プレースホルダ一覧」をすべて確定させたうえで使用してください。
> Valveは調査票の設問文をそのままの形で公開していないため、本ドラフトは
> [partner.steamgames.com/doc/gettingstarted/contentsurvey](https://partner.steamgames.com/doc/gettingstarted/contentsurvey)
> が示す区分(一般コンテンツ/Mature Content/生成AIコンテンツ)に沿って整理した回答案であり、
> 実際のフォーム上の設問文言とは一致しない可能性があります。

- ゲーム名: **3D Chase Game**(`project.godot`上の暫定名称。正式名称確定後に差し替え)
- 最終改定日: `[YYYY-MM-DD]`
- 対象: UXロードマップ Phase 4 P1-4(ロードマップ本体はリポジトリ外の作業用プランファイルに
  あるため、ここではリンクを張らない)

---

## A. 一般コンテンツ / Mature Content 区分ごとの回答案

各区分について、アップロードするビルドに実際に含まれる内容(通常プレイで到達不能な内容も含む)
を基準に、正直に回答することが前提([docs/EOS_LEGAL_REVIEW.md](EOS_LEGAL_REVIEW.md)と同じく、
「正式な公開前に事実を裏取りしてから記載する」方針をここでも踏襲)。

| 区分 | 回答案 | 根拠 |
| --- | --- | --- |
| 暴力・流血表現 | **該当なし** | 逃走者/鬼の勝敗は接触判定のみで、攻撃・武器・ダメージ演出は一切実装されていない([docs/concept/store/cover_image/SPEC.md](concept/store/cover_image/SPEC.md)「禁止事項: 戦闘・暴力表現は含まない」、README.mdの「## ルール」参照)。 |
| ヌード・性的表現 | **該当なし** | カートゥーン調キャラクター。コスチューム/帽子の着せ替え以外の表現要素なし。 |
| ギャンブル(ランダム型課金等) | **該当なし** | `autoload/purchase_manager.gd`を実読し、`buy_currency_pack()`/アイテム購入とも固定価格・固定内容の直接購入のみで、`randi()`等の乱数によるランダム報酬付与コードが存在しないことを確認済み。 |
| 薬物・アルコール描写 | **該当なし** | ゲーム内に該当する描写・アイテムなし。 |
| 下品な言葉遣い・差別的表現 | **該当なし** | テキストチャット・ボイスチャット機能自体が実装されていない(意思疎通手段は「カモン」エモート3種のみ、README.mdの「## エモート」参照)。プレイヤー表示名は`profile_manager.gd`の`sanitize_name()`/`name_error()`により運営・管理者への成りすまし等のNGワードを最小限フィルタしている。 |
| 光過敏性(フラッシュ・強い明滅) | **未検証・要確認** | 今回のセッションではギミック(マンホールワープ・ダッシュパネル等)のVFX/シェーダーを光過敏性の観点で個別確認していない。実機での目視確認が必要(下記プレースホルダ参照)。 |
| ホラー表現 | **該当なし** | マリオ風のカラフル・ポップなビジュアル(README.mdの「## マップ」参照)。ホラー演出は存在しない。 |

## B. 生成AIコンテンツ(Generative AI Content)の開示

**該当あり。**

- `assets/audio/bgm/title_bgm.ogg`(タイトル/ロビー画面BGM)は、生成AIツール(Web版Gemini)を
  用いて制作された音源である。`docs/concept/audio/title_bgm/REVIEW.md`の「2026-09-14
  レビュー(Web版Gemini・第4版)」で**PASS**判定を受けた後、ゲームに組み込み・コミット済み
  (現在`res://assets/audio/bgm/title_bgm.ogg`としてビルドに同梱されている)。
- この音源は**事前生成・ビルド同梱**のコンテンツであり、プレイ中にリアルタイムで生成される
  ものではない(Valveの区分でいう「pre-shipped AI-generated content」に該当し、
  「live-generated-at-runtime content」ではない)。
- 将来、[docs/concept/store/app_icon/SPEC.md](concept/store/app_icon/SPEC.md)等の画像素材が
  生成AIツールで制作され実際に`res://icon.ico`等としてゲーム/ストア素材に組み込まれた場合、
  同様の開示が追加で必要になる(本ドラフト作成時点では未制作のため対象外)。

## C. ドイツ/USK(年齢レーティング必須化)への対応

2024-11-15以降、有効な年齢レーティングを持たないゲームはドイツのSteamストアで非表示になる
(出典: [Age Ratings Mandatory in Germany](https://partner.steamgames.com/doc/gettingstarted/contentsurvey/germany)、
確認日2026-09-22)。対応経路は以下の2つ:

1. **USKによる実審査レーティング**: ドイツの公的レーティング機関USKへ実際に審査を申請し、
   取得したレーティングを登録する経路。
2. **Valve自己レーティング**: 上記A/Bの調査票へ正直に回答することで、Valveの審査チームと
   コミュニティフィードバックにより自動的に算出される経路。追加の申請作業は不要。

本作の内容(上記A表のとおり暴力・性的表現・ギャンブル等に該当なし)であれば、**経路2(Valve
自己レーティング)が既定・推奨**であり、USKへの実審査申請は不要と考えられる。ただし、
実際にUSK審査を経ていない場合はUSKレーティングを自称・入力してはならない(虚偽表示となる)。

## D. プレースホルダ一覧(提出前に確定させること)

- [ ] 光過敏性(フラッシュ・強い明滅)の実機確認(上記A表、未検証のまま残っている)
- [ ] 事業者名([docs/TOKUSHOHO_DRAFT.md](TOKUSHOHO_DRAFT.md)・[docs/EULA_DRAFT.md](EULA_DRAFT.md)と一致させること)
- [ ] ゲームの正式名称(現状「3D Chase Game」は`project.godot`上の暫定名)
- [ ] 提出直前に、実際にSteamworksパートナーポータルの調査票フォームを開き、設問文言・区分が
      本ドラフトの想定と一致しているか再確認すること(Valveがフォーム内容を変更する可能性がある)
- [ ] app_icon等の画像素材が生成AIツールで制作・組み込まれた場合、B節への追記

## 出典

- [Content Survey](https://partner.steamgames.com/doc/gettingstarted/contentsurvey)(確認日2026-09-22)
- [Age Ratings Mandatory in Germany](https://partner.steamgames.com/doc/gettingstarted/contentsurvey/germany)(確認日2026-09-22)
