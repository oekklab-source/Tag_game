# Tag_Game Rating API

レート(Elo)のサーバー権威化(C-03)用の新規バックエンド(Cloudflare Workers)。

**現状(R-1、基盤のみ): エンドポイント実装はまだ無い。** このディレクトリには
現時点で以下だけが揃っている:

- `src/rating_model.ts`: [autoload/ranking_manager.gd](../../autoload/ranking_manager.gd)
  の非対称Eloレーティング計算(`calculate_all_rating_changes()`/`calculate_rating_delta()`/
  `bonus_weight()`/`tier_index()`)を1:1移植した純粋関数群。数式の出典は
  [docs/RATING_SYSTEM.md](../../docs/RATING_SYSTEM.md)。
- `src/rating_model.test.ts`: [tests/rating_model.gd](../../tests/rating_model.gd)の
  9ケース + `docs/RATING_SYSTEM.md` §3の数値表をゴールデン値として直接assertするケース +
  GDScriptの`round()`(0から遠い方向)とJSの`Math.round()`(+∞方向)の丸め方式の差異を
  明示的にテストするケース。
- `schema.sql`: レート台帳(`ratings`)と試合ログ(`match_log`、二重計上防止)のD1スキーマ案。

`src/index.ts`(HTTPエンドポイント本体)・実際のD1データベース作成・デプロイは
次のセッション(R-2)で行う。そのため現時点で`wrangler dev`/`wrangler deploy`は
実行できない(想定通り)。

## なぜKVではなくD1か

`service/friend-api`/`service/commerce-api`は両方KVを使っているが、レートの
ランキング表示には「レート降順で上位N件を取る」というソート済みレンジクエリが
必要で、KV(完全一致lookupのみ)では自前でソート済み二次インデックスを維持する
必要があり複雑で壊れやすい。D1(SQLite)なら`ORDER BY rating DESC LIMIT ?`で済む。

## アーキテクチャの要点(詳細はC-03設計ドキュメント参照)

- 試合結果の報告はホスト単独(Option A)。README「マルチプレイの権威モデル」節が
  既に「タッチ判定はホストが一元的に行う」と定めており、その延長として結果報告の
  権威もホストに寄せる。
- ランキング表示はEOS Leaderboardではなくこのサービスの自前D1を既定にする(Plan B)。
  EOS Statsは「クライアントが自分のPUIDに書く」自己申告APIで、第三者(サーバー)が
  書き込むには別途EOS Portalでのサーバー用Confidential Client発行が必要になる
  可能性が高く、これは実際にdev.epicgames.comへログインできるユーザー本人にしか
  確認できない(EOS Portal側の可否判断がYesだった場合のみ、条件付きで追加対応する)。

## ローカルでの検証

```
npm install
npm test    # rating_model.ts の純粋関数の単体テスト(node:test)
npx tsc --noEmit   # 型チェック
```

## セットアップ(R-2で実施予定)

```
npx wrangler d1 create tag-game-rating-db
# 出力された database_id を wrangler.toml の d1_databases.database_id に設定する
npx wrangler d1 execute tag-game-rating-db --file=schema.sql
```

## 既知の制約・残存リスク

- **ホスト単独報告は複数アカウントの結託ねつ造を防げない**。サーバーは「その試合が
  実在したか」自体を検証する手段を持たない構造的限界。`docs/SECURITY_NOTES.md`の
  項目3(切断ペナルティの自己申告)と同種の信頼モデルであり、同ドキュメントに
  受容事項として追記する予定(R-8)。
- KV書き込み無料枠(1日1,000件、`service/friend-api`/`service/commerce-api`と
  同一Cloudflareアカウントで共有)への影響を避けるためD1を選んだが、D1にも
  無料枠の上限はあるため、本番投入後は[docs/DEPLOYMENT_CHECKLIST.md](../../docs/DEPLOYMENT_CHECKLIST.md)
  の実測手順に準じて監視すること。
