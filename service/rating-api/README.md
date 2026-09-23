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

# 1. claim(1500超は invalid_rating、初回成功→2回目はalready_claimed)
curl -s -X POST $BASE/claim-initial-rating -H "X-Debug-Puid: p-runner" -d '{"rating":1650}'
curl -s -X POST $BASE/claim-initial-rating -H "X-Debug-Puid: p-runner" -d '{"rating":1500}'
curl -s -X POST $BASE/claim-initial-rating -H "X-Debug-Puid: p-h1" -d '{"rating":1500}'
curl -s -X POST $BASE/claim-initial-rating -H "X-Debug-Puid: p-h2" -d '{"rating":1500}'
curl -s -X POST $BASE/claim-initial-rating -H "X-Debug-Puid: p-h1" -d '{"rating":1500}'

# 2. rating(未claim=claimed:false、claim済み=実値)
curl -s -X POST $BASE/rating -H "X-Debug-Puid: p-unclaimed"
curl -s -X POST $BASE/rating -H "X-Debug-Puid: p-runner"

# 3. report-match(報告者は参加者でなければならない。同じmatch_idを2回送って
#    replayed:trueとレート非2重変動を確認)
BODY='{"match_id":"test-match-0001","runner_puid":"p-runner","hunter_puids":["p-h1","p-h2"],"runner_escaped":false,"toucher_puid":"p-h1","survival_time":120}'
curl -s -X POST $BASE/report-match -H "X-Debug-Puid: p-h1" -d "$BODY"
curl -s -X POST $BASE/report-match -H "X-Debug-Puid: p-h1" -d "$BODY"
curl -s -X POST $BASE/rating -H "X-Debug-Puid: p-runner"

# 4. 未claim参加者を含む試合 → not_claimed
BODY2='{"match_id":"test-match-0002","runner_puid":"p-runner","hunter_puids":["p-unclaimed"],"runner_escaped":true,"toucher_puid":null,"survival_time":180}'
curl -s -X POST $BASE/report-match -H "X-Debug-Puid: p-runner" -d "$BODY2"

# 5. leaderboard(認証不要・GET)
curl -s "$BASE/leaderboard-top?limit=10"

# 6. 認証失敗(X-Debug-Puidヘッダ無し)→ 401
curl -s -i -X POST $BASE/rating

# 7. report-disconnect-penalty(同一ボディを異なる報告者から2回送り、複数生存者が
#    独立に同じ切断イベントを報告するレースを模擬。match_idはサーバーが
#    target_puid/was_runner/時間バケツ(5分)から決定的に導出するため(v2)、
#    2回目はreplayed:trueになりratingは1回分しか変動しない)
BODY3='{"target_puid":"p-h2","was_runner":false,"hunter_count":2,"self_rating":1500,"rating_delta":-10}'
curl -s -X POST $BASE/report-disconnect-penalty -H "X-Debug-Puid: p-survivor-a" -d "$BODY3"
curl -s -X POST $BASE/report-disconnect-penalty -H "X-Debug-Puid: p-survivor-b" -d "$BODY3"
curl -s -X POST $BASE/rating -H "X-Debug-Puid: p-h2"   # rating変動が1回分のみ反映されていることを確認

# 8. (v2) hunter_count/self_rating を変えても同一バケツ内なら同一イベント扱い(replayed:true)。
#    役割(was_runner)か被害者(target_puid)が違えば別イベントになる
BODY4='{"target_puid":"p-h2","was_runner":false,"hunter_count":3,"self_rating":1501,"rating_delta":-8}'
curl -s -X POST $BASE/report-disconnect-penalty -H "X-Debug-Puid: p-survivor-a" -d "$BODY4"

# 9. C-03 R-10: 攻撃が実際に塞がっていることの確認(この4本は必ず通すこと)
# 9-1 非参加者による試合報告 -> reporter_not_participant
curl -s -X POST $BASE/report-match -H "X-Debug-Puid: p-outsider" -d "$BODY"
# 9-2 hunter_count/self_rating/役割を変えながら-64Ptを20回送りつけても、
#     被害者のratingは1日あたり合計-64Ptまでしか減らない(以降は target_daily_cap)
for i in $(seq 1 20); do
  curl -s -X POST $BASE/report-disconnect-penalty -H "X-Debug-Puid: p-attacker"     -d "{\"target_puid\":\"p-victim\",\"was_runner\":false,\"hunter_count\":$(( (i % 7) + 1 )),\"self_rating\":$(( 1400 + i )),\"rating_delta\":-64}"
done
curl -s -X POST $BASE/rating -H "X-Debug-Puid: p-victim"
# 9-3 自己申告レートは1500まで。claim直後(seeded_from_client=1)は5試合こなすまでランキングに載らない
curl -s -X POST $BASE/claim-initial-rating -H "X-Debug-Puid: p-new" -d '{"rating":2500}'  # invalid_rating
curl -s "$BASE/leaderboard-top?limit=10"
# 9-4 レート制限の原子性: 上限10/日のclaimへ15本を並列投入しても通過は10本で止まる
seq 1 15 | xargs -P 15 -I{} curl -s -X POST $BASE/claim-initial-rating -H "X-Debug-Puid: p-rl-test" -d '{"rating":1200}'
npx wrangler d1 execute tag-game-rating-db --local --command   "SELECT rl_key, count FROM rate_limit_counters WHERE rl_key LIKE 'claim:p-rl-test%'"
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

- **ホスト単独報告は「自分が参加した架空の試合」のねつ造を防げない**。C-03 R-10で
  「報告者が申告した参加者一覧に自分が含まれること」(`isReporterParticipant()`)を必須にしたため、
  **第三者が全く無関係の2人の試合をでっち上げる経路は塞がった**が、報告者自身を参加者に
  含めた架空の試合は依然として作れる(サーバーは「その試合が実在したか」自体を検証する
  手段を持たない構造的限界)。被害上限は`MATCH_REPORT_LIMIT_PER_DAY`(150件/日・報告者PUID単位)
  だけで、完全に塞ぐにはEOSロビーのメンバー実在検証(ロードマップC-03 R-0)が要る。
  `docs/SECURITY_NOTES.md`の項目7に受容事項として記載済み。
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
- **`/report-disconnect-penalty`のdedupは決定的ID(SHA-256)方式**(C-03 R-5、R-10でv2へ更新)。
  `match_id`は対象PUID・役割(runner/hunter)・**時間バケツ(5分)**の3値からサーバー側で導出するため、
  ホスト引き継ぎ失敗時に生存者全員が独立に(調整なしで)送信しても`match_log`のUNIQUE制約で
  1回だけ反映される(バケツ境界をまたいだ報告を取りこぼさないよう、現バケツと1つ前の
  バケツの2点で照合している)。v1は`hunter_count`/`self_rating`もmaterialに含めていたが、
  これらは改造クライアントが自由に変えられる値でペナルティの累積に使えたため、R-10で外した。
  代償として、同一人物が同じ役割のまま5分以内に複数回切断した場合は2回目以降が黙って
  重複排除される(1ラウンド180秒なので実害は小さい、意図的な仕様)。
- **切断ペナルティには被害者PUID単位の1日上限(-64Pt)がある**(C-03 R-10)。報告者単位の
  20件/日とは別枠のカウンタ(`disconnect_penalty_target:<puid>:<日付>`)で、上限に達した
  報告は`{ok:false, reason:"target_daily_cap"}`になる。攻撃被害の実質的な上限を決めているのは
  この予算で、決定的IDは「同じ実イベントを二重計上しない」冪等性ガードという役割分担。
  正当な切断も1日-64Ptまでしか累積しない(旧friend-apiの「penalty:<puid>キー上書き」と同等)。
- **`/claim-initial-rating`は1500(既定値)までしか受け付けない**(C-03 R-10)。自己申告で
  既定値より上は名乗れず、加えて`seeded_from_client=1`の行は`matches_played`が5件に達するまで
  `/leaderboard-top`から除外される。ratings行はすべてclaim経由で作られるため、実質
  「ランクイン前に5試合が必要」という配置マッチ相当の仕様になる(`/rating`は除外しないので
  本人のプロフィール表示には影響しない)。
- **`rating_delta`は引き続きクライアント(報告者)の自己申告・自己計算**
  (`autoload/ranking_manager.gd`の`calculate_rating_delta()`、`-64〜-1`にクランプするのみ)。
  `rating_before`はD1の権威値を使うため結果自体は改ざんできないが、「何点減点するか」の
  計算自体は`/report-match`ほど厳密なサーバー側再計算になっていない(旧friend-api
  `/report-penalty`と同じ信頼モデルを引き継いだだけで、今回はそこまで強化していない)。
