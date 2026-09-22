# Tag_Game Rating API

レート(Elo)のサーバー権威化(C-03)用の新規バックエンド(Cloudflare Workers)。

**現状(R-2完了: エンドポイント実装済み、未デプロイ)。** このディレクトリには
以下が揃っている:

- `src/rating_model.ts`: [autoload/ranking_manager.gd](../../autoload/ranking_manager.gd)
  の非対称Eloレーティング計算(`calculate_all_rating_changes()`/`calculate_rating_delta()`/
  `bonus_weight()`/`tier_index()`)を1:1移植した純粋関数群。数式の出典は
  [docs/RATING_SYSTEM.md](../../docs/RATING_SYSTEM.md)。
- `src/rating_model.test.ts`: [tests/rating_model.gd](../../tests/rating_model.gd)の
  9ケース + `docs/RATING_SYSTEM.md` §3の数値表をゴールデン値として直接assertするケース +
  GDScriptの`round()`(0から遠い方向)とJSの`Math.round()`(+∞方向)の丸め方式の差異を
  明示的にテストするケース。
- `schema.sql`: レート台帳(`ratings`)・試合ログ(`match_log`、二重計上防止)・
  JWKSキャッシュ(`jwks_cache`)・レート制限カウンタ(`rate_limit_counters`)のD1スキーマ。
- `src/index.ts`: HTTPエンドポイント本体(`/report-match` `/claim-initial-rating`
  `/rating` `/leaderboard-top`)。認証(`verifyIdToken`)は
  [service/friend-api/src/index.ts](../friend-api/src/index.ts)から移植し、
  JWKSキャッシュ・レート制限のみKVではなくD1へ書き換えている。
- `src/index.test.ts`: バリデーション・レート制限キー生成など、D1やWorkers runtimeを
  起動せずに検証できる純粋関数の単体テスト。

**実際のD1データベース作成(`wrangler d1 create`)・`wrangler deploy`はまだ実施していない**
(ユーザー自身のCloudflareアカウント操作が必要なため、次のステップとして残っている)。

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

## ローカルでの単体テスト・型チェック

```bash
npm install
npm test          # rating_model.ts / index.ts の純粋関数の単体テスト(node:test)
npx tsc --noEmit   # 型チェック
```

## ローカルでのエンドポイント動作確認(wrangler dev --local)

D1・Workers runtimeを実際に動かしたスモークテスト。実アカウントへのログインや
`database_id`の確定は不要(`wrangler dev`は既定でローカルSQLiteを使う)。

```bash
# ローカルD1へスキーマ適用
npx wrangler d1 execute tag-game-rating-db --local --file=schema.sql

# .dev.vars(gitignore対象)を作成。実EOSトークン無しに X-Debug-Puid で任意のPUIDを名乗れる
echo "ALLOW_DEBUG_AUTH=1" > .dev.vars

npm run dev   # wrangler dev
```

別ターミナルから:

```bash
BASE=http://localhost:8787

# 1. claim(初回成功→2回目はalready_claimed)
curl -s -X POST $BASE/claim-initial-rating -H "X-Debug-Puid: p-runner" -d '{"rating":1650}'
curl -s -X POST $BASE/claim-initial-rating -H "X-Debug-Puid: p-h1" -d '{"rating":1500}'
curl -s -X POST $BASE/claim-initial-rating -H "X-Debug-Puid: p-h2" -d '{"rating":1500}'
curl -s -X POST $BASE/claim-initial-rating -H "X-Debug-Puid: p-h1" -d '{"rating":1500}'

# 2. rating(未claim=claimed:false、claim済み=実値)
curl -s -X POST $BASE/rating -H "X-Debug-Puid: p-unclaimed"
curl -s -X POST $BASE/rating -H "X-Debug-Puid: p-runner"

# 3. report-match(同じmatch_idを2回送ってreplayed:trueとレート非2重変動を確認)
BODY='{"match_id":"test-match-0001","runner_puid":"p-runner","hunter_puids":["p-h1","p-h2"],"runner_escaped":false,"toucher_puid":"p-h1","survival_time":120}'
curl -s -X POST $BASE/report-match -H "X-Debug-Puid: p-host" -d "$BODY"
curl -s -X POST $BASE/report-match -H "X-Debug-Puid: p-host" -d "$BODY"
curl -s -X POST $BASE/rating -H "X-Debug-Puid: p-runner"

# 4. 未claim参加者を含む試合 → not_claimed
BODY2='{"match_id":"test-match-0002","runner_puid":"p-runner","hunter_puids":["p-unclaimed"],"runner_escaped":true,"toucher_puid":null,"survival_time":180}'
curl -s -X POST $BASE/report-match -H "X-Debug-Puid: p-host" -d "$BODY2"

# 5. leaderboard(認証不要・GET)
curl -s "$BASE/leaderboard-top?limit=10"

# 6. 認証失敗(X-Debug-Puidヘッダ無し)→ 401
curl -s -i -X POST $BASE/rating
```

## デプロイ手順(実施はユーザー自身が行う)

1. `npx wrangler d1 create tag-game-rating-db`
   → 出力された `database_id` を `wrangler.toml` の `[[d1_databases]].database_id` に設定する
2. `npx wrangler d1 execute tag-game-rating-db --remote --file=schema.sql`
   (上記のローカル検証とは別に、本番D1にもスキーマを適用する必要がある)
3. `npx wrangler deploy`
4. デプロイ後、実機のEOS Connect ID Tokenを使って4エンドポイントを一通り手動で叩き、
   401/200双方の応答を確認する(手順は上記のローカル検証と同じ、`X-Debug-Puid`の代わりに
   `Authorization: Bearer <実トークン>`を使う)
5. `wrangler.toml`の`[vars]`に`ALLOW_DEBUG_AUTH`を絶対に書かないこと(`.dev.vars`限定)

## 既知の制約・残存リスク

- **ホスト単独報告は複数アカウントの結託ねつ造を防げない**。サーバーは「その試合が
  実在したか」自体を検証する手段を持たない構造的限界。`docs/SECURITY_NOTES.md`の
  項目3(切断ペナルティの自己申告)と同種の信頼モデルであり、同ドキュメントに
  受容事項として追記する予定(R-8)。
- **`/leaderboard-top`はPUIDを認証不要で列挙可能な形で返す**。
  `service/friend-api/src/index.ts`は「PUIDそのものは公開しない」ことを設計原則としているが、
  このエンドポイントは公開ランキングという性質上、上位N件のPUIDを一括列挙できてしまい
  この原則と衝突する。それでもPUIDを含めている(自分の順位ハイライトには同率レート下での
  本人特定にPUIDが要る。将来のランキング画面切替セッションでの名前解決join keyとしても
  必要)。ただしPUID単体を知っているだけではフレンド追加も接触もできない
  (friend-apiのフレンド追加は8桁コード経由のみ)ため実害は小さいと判断した。
  正式な`docs/SECURITY_NOTES.md`への追記はR-8にまとめる。
- KV書き込み無料枠(1日1,000件、`service/friend-api`/`service/commerce-api`と
  同一Cloudflareアカウントで共有)への影響を避けるためD1を選んだが、D1にも
  無料枠の上限はあるため、本番投入後は[docs/DEPLOYMENT_CHECKLIST.md](../../docs/DEPLOYMENT_CHECKLIST.md)
  の実測手順に準じて監視すること。
- D1の`batch()`が「いずれかの文が失敗したら全体ロールバック」という原子性を持つ前提で
  `/report-match`・`/claim-initial-rating`の冪等性を設計している(UNIQUE制約違反での
  ロールバックをローカル検証手順3で実際に確認すること)。
