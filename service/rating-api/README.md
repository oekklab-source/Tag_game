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
- `src/index.ts`: HTTPエンドポイント本体(`/report-match` `/report-disconnect-penalty`
  `/claim-initial-rating` `/rating` `/leaderboard-top`)。認証(`verifyIdToken`)は
  [service/friend-api/src/index.ts](../friend-api/src/index.ts)から移植し、
  JWKSキャッシュ・レート制限のみKVではなくD1へ書き換えている。`/report-disconnect-penalty`は
  C-03 R-5で追加した、旧`service/friend-api`の`/report-penalty`・`/consume-penalty`
  (「本人が次回ログイン時に自分で適用する預かり金」方式)の後継。対戦中の切断(鬼/逃走者/
  ホスト自身)1件につき、対象1名の敗北分をこのサービスのD1へ直接・権威的に反映する。
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

# 7. report-disconnect-penalty(同一ボディを異なる報告者から2回送り、複数生存者が
#    独立に同じ切断イベントを報告するレースを模擬。match_idはサーバーが
#    target_puid/was_runner/hunter_count/self_ratingから決定的に導出するため、
#    2回目はreplayed:trueになりratingは1回分しか変動しない)
BODY3='{"target_puid":"p-h2","was_runner":false,"hunter_count":2,"self_rating":1500,"rating_delta":-10}'
curl -s -X POST $BASE/report-disconnect-penalty -H "X-Debug-Puid: p-survivor-a" -d "$BODY3"
curl -s -X POST $BASE/report-disconnect-penalty -H "X-Debug-Puid: p-survivor-b" -d "$BODY3"
curl -s -X POST $BASE/rating -H "X-Debug-Puid: p-h2"   # rating変動が1回分のみ反映されていることを確認

# 8. 4値(target_puid/was_runner/hunter_count/self_rating)のいずれかが違えば
#    別のmatch_id(=別イベント)として処理される
BODY4='{"target_puid":"p-h2","was_runner":false,"hunter_count":3,"self_rating":1500,"rating_delta":-8}'
curl -s -X POST $BASE/report-disconnect-penalty -H "X-Debug-Puid: p-survivor-a" -d "$BODY4"
```

## デプロイ手順(実施はユーザー自身が行う)

1. `npx wrangler d1 create tag-game-rating-db`
   → 出力された `database_id` を `wrangler.toml` の `[[d1_databases]].database_id` に設定する
2. `npx wrangler d1 execute tag-game-rating-db --remote --file=schema.sql`
   (上記のローカル検証とは別に、本番D1にもスキーマを適用する必要がある)
3. `npx wrangler deploy`
4. デプロイ後、実機のEOS Connect ID Tokenを使って5エンドポイントを一通り手動で叩き、
   401/200双方の応答を確認する(手順は上記のローカル検証と同じ、`X-Debug-Puid`の代わりに
   `Authorization: Bearer <実トークン>`を使う)
5. `wrangler.toml`の`[vars]`に`ALLOW_DEBUG_AUTH`を絶対に書かないこと(`.dev.vars`限定)
6. **(C-03 R-5固有の注意)** `autoload/backend_config.gd`の`USE_LIVE_RATING_BACKEND`を
   `true`に切り替えるタイミングと、旧`service/friend-api`の`/report-penalty`・
   `/consume-penalty`経路を削除したクライアントビルドを配布するタイミングを必ず同時に行う
   こと。現状(`USE_LIVE_FRIEND_BACKEND=true`・`USE_LIVE_RATING_BACKEND=false`)では
   旧friend-api経由の切断ペナルティが実際に機能している唯一の経路であり、新旧の切り替えが
   ずれると切断ペナルティが一時的に完全に無効化される空白期間が生まれる。

## 既知の制約・残存リスク

- **ホスト単独報告は複数アカウントの結託ねつ造を防げない**。サーバーは「その試合が
  実在したか」自体を検証する手段を持たない構造的限界。`docs/SECURITY_NOTES.md`の
  項目3(切断ペナルティの自己申告)と同種の信頼モデルであり、同ドキュメントの
  項目7に受容事項として記載済み(R-8)。
- **`/leaderboard-top`はPUIDを認証不要で列挙可能な形で返す**。
  `service/friend-api/src/index.ts`は「PUIDそのものは公開しない」ことを設計原則としているが、
  このエンドポイントは公開ランキングという性質上、上位N件のPUIDを一括列挙できてしまい
  この原則と衝突する。それでもPUIDを含めている(自分の順位ハイライトには同率レート下での
  本人特定にPUIDが要る。将来のランキング画面切替セッションでの名前解決join keyとしても
  必要)。ただしPUID単体を知っているだけではフレンド追加も接触もできない
  (friend-apiのフレンド追加は8桁コード経由のみ)ため実害は小さいと判断した。
  `docs/SECURITY_NOTES.md`の項目8に記載済み(R-8)。
- KV書き込み無料枠(1日1,000件、`service/friend-api`/`service/commerce-api`と
  同一Cloudflareアカウントで共有)への影響を避けるためD1を選んだが、D1にも
  無料枠の上限はあるため、本番投入後は[docs/DEPLOYMENT_CHECKLIST.md](../../docs/DEPLOYMENT_CHECKLIST.md)
  の実測手順に準じて監視すること。
- D1の`batch()`が「いずれかの文が失敗したら全体ロールバック」という原子性を持つ前提で
  `/report-match`・`/claim-initial-rating`の冪等性を設計している(UNIQUE制約違反での
  ロールバックをローカル検証手順3で実際に確認すること)。
- **`/report-disconnect-penalty`のdedupは決定的ID(SHA-256)方式**(C-03 R-5)。対象PUID・
  役割(runner/hunter)・hunter数・自己申告ratingの4値から`match_id`をサーバー側で導出するため、
  ホスト引き継ぎ失敗時に生存者全員が独立に(調整なしで)送信しても`match_log`のUNIQUE制約で
  1回だけ反映される。代償として、同一マッチ内で同一人物が同じ役割・同じhunter数・同じ
  ratingのまま複数回切断した場合は2回目以降が黙って重複排除される(実質1マッチ1回に収束、
  意図的な仕様)。また極めて低確率だが、別の試合で偶然この4値が完全一致した場合に新しい
  正当なペナルティがdedupで失われうる(fail-safe、実害は「稀にペナルティが漏れる」方向のみ
  で公平性を損なわない。`docs/SECURITY_NOTES.md`項目3に追記予定)。
- **`rating_delta`は引き続きクライアント(報告者)の自己申告・自己計算**
  (`autoload/ranking_manager.gd`の`calculate_rating_delta()`、`-64〜-1`にクランプするのみ)。
  `rating_before`はD1の権威値を使うため結果自体は改ざんできないが、「何点減点するか」の
  計算自体は`/report-match`ほど厳密なサーバー側再計算になっていない(旧friend-api
  `/report-penalty`と同じ信頼モデルを引き継いだだけで、今回はそこまで強化していない)。
