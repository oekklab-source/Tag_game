# 本番デプロイ・チェックリスト（人手作業）

Steamworks → EOS 移行はコード上は全フェーズ完了しているが、以下は**人手でしかできない作業**
（各社ダッシュボード上の操作、実機での複数端末確認）で、ここが終わるまで各機能はモック/オフライン
フォールバックのまま動く（クラッシュはしない）。

上から順に進めることを推奨（依存が少ない順）。各項目の詳しい手順は既存の README にあるので、
ここでは「次に何をするか」と「完了条件」だけをまとめる。

## 1. EOS Developer Portal — リーダーボード定義（Phase 3）

1. [Epic Developer Portal](https://dev.epicgames.com/portal) で Stat 定義 `PlayerRating` を作成する
   （aggregation: **Latest**）。
2. その Stat に紐づく Leaderboard 定義を作成する（aggregation も **Latest**）。
3. 対象 Client の Client Policy で Stats / Leaderboards 機能が有効になっているか確認する
   （既定の `GameClient` ポリシーで足りるか未確認。Phase 0 で Connect 機能が
   Custom Policy では有効化できなかった前例があるので、ここでも要注意）。

**2026-09-12 実施済み（ステップ1・2・3、スクリーンショットで確認）**: Stat `PlayerRating`
（aggregation LATEST）、Leaderboard `GlobalRankings`（`PlayerRating` に紐づき aggregation LATEST、
ステータス「アクティブ」）を作成済み。Client Policy `GameClient_Default` にも Stats/Leaderboards
は有効（項目6参照）。

**2026-09-12 完了条件を実機2台で確認済み**: ルームマッチ経由のランク対戦を完了させ、
ゲーム内のランキング画面（[scenes/ranking_dialog.gd](../scenes/ranking_dialog.gd)）に
実際のスコアが表示されることを確認（自分の順位・レートが正しく反映、更新のたびに
最新スコアへ更新される）。**新たに判明した既知の制限（バグではない）**: 自分以外の
プレイヤーは名前が汎用の「Player」表示になる。EOS Leaderboards の `user_display_name` が
常に空文字で返るため、EOS Connect の ProductUserId 逆引き
（`QueryProductUserIdMappings`→`CopyProductUserInfo`）による解決を試したが、面識のない
（フレンド/同ロビー実績のない）相手には `CopyProductUserInfo` が `result_code=NotFound` を
返すことを実機ログで確認した（[autoload/eos_manager.gd](../autoload/eos_manager.gd) の
リーダーボード節コメント参照）。EOS 側の意図的なプライバシー制限とみられ、クライアント側での
回避手段はない。スコア自体は正しく表示されるため、この項目は完了とする。

**完了条件**: ゲーム内のランキング画面（[scenes/ranking_dialog.gd](../scenes/ranking_dialog.gd)）に
実際のスコアが表示される。（達成。他プレイヤー名の「Player」表示は上記の理由により仕様として受容）

## 2. Stripe 決済（Phase 1・`service/commerce-api`）

詳細手順: [service/commerce-api/README.md](../service/commerce-api/README.md)

**2026-09-10 時点の状況**: 1〜6・8 は完了済み（Price ID は test モードの実値が
`currency_pack_catalog.gd`/`service/commerce-api/src/index.ts` に設定済み、KV namespace
`COMMERCE_TXNS` 作成済み、`STRIPE_SECRET_KEY`/`STRIPE_WEBHOOK_SECRET` とも設定済み、
`USE_LIVE_PURCHASES = true`、二重付与防止＋レート制限入りの現行コードで
`npx wrangler deploy` 実施済み）。**未実施は 7 のみ**（テストカードでの実際の
購入フロー確認）— Phase 4 の実機検証項目6・7で行う。

**2026-09-10 実施済み（Phase 4 実機検証項目6・7）**: テストカード
`4242 4242 4242 4242` での通常購入（ジェム付与を確認）と、購入完了直後に
キャンセルする競合ケース（`27498ae` の再チェック修正でジェム付与が正しく行われることを
確認）を実機で確認済み。あわせて `pending_purchase.json` のバックアップ/リストアによる
`reconcile_pending()` の二重付与防止（5分猶予ウィンドウ内の1回限りの再付与に限定される
ことを `service/commerce-api` 側の `claimed` 状態遷移で確認）も実機検証済み。項目7は完了。

1. Stripe（テストモード）で3商品（small / medium / large）の Price を作成する。
2. 発行された Price ID を以下2箇所の `price_REPLACE_WITH_REAL_*` に上書きする:
   - [autoload/currency_pack_catalog.gd](../autoload/currency_pack_catalog.gd)（`PACKS` 内3箇所）
   - [service/commerce-api/src/index.ts](../service/commerce-api/src/index.ts)（`PACKS` 内3箇所）
3. ```sh
   cd service/commerce-api
   npm install
   npx wrangler kv namespace create COMMERCE_TXNS
   ```

   発行された `id` を [wrangler.toml](../service/commerce-api/wrangler.toml) の
   `REPLACE_WITH_REAL_KV_NAMESPACE_ID` に設定する。
4. ```sh
   npx wrangler secret put STRIPE_SECRET_KEY   # sk_test_... （まずテストモード）
   npx wrangler deploy
   ```

5. Stripe Dashboard で Webhook エンドポイントを登録する
   （URL: `<デプロイされたWorkerのURL>/stripe-webhook`、イベント:
   `checkout.session.completed` + `checkout.session.expired`）。
   発行された `whsec_...` を設定する:

   ```sh
   npx wrangler secret put STRIPE_WEBHOOK_SECRET
   ```
6. [autoload/stripe_purchase_provider.gd](../autoload/stripe_purchase_provider.gd) の
   `COMMERCE_API_BASE_URL` をデプロイ後の Worker URL に書き換える。
7. テストカードで動作確認する:
   - 成功: `4242 4242 4242 4242`
   - 失敗: `4000 0000 0000 0002`
   - **購入処理の途中でアプリを強制終了**し、次回起動時に `reconcile_pending()` が
     未受領分を正しく復旧することも確認する。
8. 確認後、[autoload/purchase_manager.gd](../autoload/purchase_manager.gd) の
   `USE_LIVE_PURCHASES` を `true` にする（本番鍵 `sk_live_...` への切替はさらに別途）。

**完了条件**: テストモードの決済がショップ画面から実行でき、ジェムが正しく付与される。

## 3. フレンド機能（Phase 5・`service/friend-api`）

詳細手順: [service/friend-api/README.md](../service/friend-api/README.md)

**2026-09-10 時点の状況**: 1〜3・5 は完了済み（KV namespace `FRIEND_KV` 作成済み、
EOS Connect ID Token 認証（`verifyIdToken()`）入りの現行コードで `npx wrangler deploy`
実施済み、`Authorization` ヘッダ無し／不正トークンで 401 になることを curl で確認済み、
`USE_LIVE_FRIEND_BACKEND = true`）。**未実施は 4 のみ**（2アカウントでの実機確認）—
Phase 4 の実機検証項目8で行う。

1. ```sh
   cd service/friend-api
   npm install
   npx wrangler kv namespace create FRIEND_KV
   ```

   発行された `id` を [wrangler.toml](../service/friend-api/wrangler.toml) の
   `REPLACE_WITH_REAL_KV_NAMESPACE_ID` に設定する。
2. ```sh
   npx wrangler deploy
   ```
3. [autoload/friend_backend_client.gd](../autoload/friend_backend_client.gd) の
   `FRIEND_API_BASE_URL` をデプロイ後の Worker URL に書き換える。
4. 2アカウントでフレンドコードの交換・申請・承認・削除を実機で確認する。
5. 確認後、[autoload/friend_manager.gd](../autoload/friend_manager.gd) の
   `USE_LIVE_FRIEND_BACKEND` を `true` にする。

**完了条件**: 2アカウント間でフレンド申請〜承認〜ギフト送信までが実際に通る。

## 4. EOS ロビーの実機2セッション確認（Phase 2）

コードは完了済みだが、実際に見知らぬ相手同士のマッチングが通るかは未検証。
手順は [README.md](../README.md) の「EOSロビーによる自動マッチメイキング」節の
「動作確認」を参照。
2台（または `user://` を分離した2インスタンス）でクイックマッチ／ルームマッチが
実際に成立し、そのままゲーム対戦まで繋がることを確認する。

**完了条件**: 見ず知らずの2セッション間でロビーマッチング→ゲーム開始までが通る。

## 5. friend-api / commerce-api の認証つきデプロイ（Phase 1・両 Worker）

`service/friend-api` に EOS Connect ID Token 検証（`verifyIdToken()`）、`service/commerce-api` に
購入の二重付与防止とレート制限を実装済み。ローカル `wrangler dev`（Miniflare）での動作確認は完了しているが、
**本番デプロイはまだ行っていない**。

認証付き Worker をデプロイした瞬間、旧バージョンの exe（`Authorization` ヘッダを送らないクライアント）は
全リクエストが 401 で弾かれる。**Worker のデプロイと、新しい exe のビルド・配布は必ずセットで行う**
（この2項目より前にある1〜4のデプロイ作業を先に済ませ、最後にこの2本を deploy する）。

```sh
cd service/friend-api && npx wrangler deploy
cd ../commerce-api && npx wrangler deploy
```

**2026-09-10 実施済み**: 両 Worker を現行コード（Phase 1 の認証・レート制限・二重付与防止入り）で
デプロイ済み（friend-api Version ID `e9672fee-175f-42b1-8bab-5f408d33c948`、commerce-api
`5b9aa8ae-aa77-443c-88bd-ab5e7a269128`）。同時に `export/windows/TagGame.exe` も現行 HEAD
（`3be4c5c`、EOSネイティブ層使用後のプロセス残留=Critical修正込み）から再ビルド済み。
`curl` で friend-api がトークン無し／不正トークンとも 401 を返すことを確認済み
（デプロイ前は旧コードのため 400 だった）。commerce-api も不正リクエストで 500 にならず
適切な 400 を返すことを確認済み（Stripe secrets 設定済み）。

**完了条件**: 別マシンから `curl` で `Authorization` ヘッダ無し・不正トークンでのリクエストが
両 Worker とも 401 で弾かれることを確認できる。`wrangler tail` にエラーが出ない。

## 6. EOS Client Policy の確認（Epic Developer Portal）

exe に同梱される `client_id`（`eos_credentials.cfg`）の Client Policy が、Connect / Lobbies / P2P / PDS /
Leaderboards など**必要最小限の権限のみ**になっているかを、Epic Developer Portal の画面で目視確認する。
過剰な権限（例: 他プロダクトの管理系スコープ）が付いていないことを確認する。

**完了条件**: Developer Portal のスクリーンショットで Client Policy の権限一覧を確認済み。

**2026-09-12 実施済み（スクリーンショットで確認、現状維持を採用）**: 製品設定 → クライアント
（`https://dev.epicgames.com/portal/solpinto/products/taggame-a0f2f993/settings/clients`）で確認。
クライアントは `Godot_Client` の1つのみ、ポリシーは既定の `GameClient_Default`（GameClient型）。
付与されている14項目（Achievements, Anti-Cheat, Leaderboards, Lobbies, Metrics, Notifications,
Player Data Storage, Player Reports, Progression Snapshot, Sanctions, Sessions, Stats,
Title Storage, Voice）のうち、コード側（`autoload/`・`scenes/` 全体を grep、SDKラッパー本体
`addons/epic-online-services-godot/` 自体は除く）で実際に呼んでいるのは **Leaderboards / Lobbies /
Player Data Storage / Stats の4項目のみ**。残り10項目は未使用（特に Sessions はこのゲームが使う
EOS Lobbies とは別インターフェースで無関係、Player Reports/Sanctions は EOS ネイティブ機能ではなく
`report_profile` RPC・rating-api の `/report-disconnect-penalty` で自前実装済み）。なお「P2P」という項目自体が
Client Policy の権限一覧に存在しないことも確認した（このゲームは EOS の P2P Interface を使わず、
ENet/WebSocket + Cloudflare トンネルで通信しているため、そもそも懸念不要）。
**判断**: 単一プロダクトのポリシーであり他プロダクトへの権限漏洩リスクがないため、
過剰な10項目は残したまま許容することをユーザーが選択（最小権限へ絞る対応は見送り）。
今後 EOS 機能を追加する際に絞り込みを再検討してよい。

## 7. Cloudflare Workers Builds（Git連携）のチェック失敗 — 原因確定・対応済み（2026-09-12）

GitHub PR上の「Workers Builds: tag-game」チェックは、2026-08-27の初回導入コミット以降
一度も成功していなかった。**マージのブロッカーではなかった**（`main` に必須チェック設定なし、
PRは常に `MERGEABLE`）。本番デプロイは本チェックリストの手動 `npx wrangler deploy`
経由で完結しており、このCI連携とは無関係だった。

**根本原因（Cloudflare API で直接確認済み、推測ではない）**: 「tag-game」という Worker は
本リポジトリの実サービス（`tag-game-friend-api`/`tag-game-commerce-api`）のどちらとも
無関係で、Cloudflareダッシュボードの「Hello World」テンプレートから **2026-08-01**
（本リポジトリの初期コミットより前）に作成されたまま一度も更新されていない放置スクリプト
だった（`source: dash_template`、workers.dev公開オフ、cronトリガーなし、bindings空）。
それにGitHub連携（Workers Builds）だけが本リポジトリに紐付いており、対応する
`wrangler.toml`が存在しないため毎回ビルドに失敗していた。

**対応**: 上記の安全性（未使用・無関係と確認済み）に基づき、`DELETE
/accounts/{account}/workers/scripts/tag-game` をCloudflare APIで実行し、2026-09-12に
このWorkerを削除済み。`tag-game-friend-api`/`tag-game-commerce-api`は削除対象に含めておらず、
既存の友達機能/決済機能への影響はない。

**完了条件**: 削除直後に `GET /accounts/{account}/workers/scripts` で `tag-game` が
一覧から消えたことを確認済み。次回このブランチにコミットした際、GitHub側の
「Workers Builds: tag-game」チェック自体が発生しなくなることを確認する（未確認、次回
コミット時に確認）。

## 8. フレンド検索・オンライン状態・戦績公開の追加エンドポイント（未デプロイ）

実機テストで見つかった要望への対応として、`service/friend-api/src/index.ts` に
`/search-user`・`/heartbeat`・`/friend-profile` を新規追加し、`/sync`・`/list-friends`
を拡張した（このセッションの作業）。**このセッションでは `npx wrangler deploy` を
実行していない**。ローカル `wrangler dev`(Miniflare)で全シナリオ(検索/申請/承諾/
ハートビート/一覧のオンライン状態/詳細取得/フレンド外からのアクセス拒否)を確認済み。

デプロイする際の手順:

1. ```sh
   cd service/friend-api
   npx tsc --noEmit   # 型チェック(このセッションで実施済み、変更を追加した場合は再実行)
   npx wrangler deploy
   ```

2. 本番URL(`autoload/backend_config.gd` の `FRIEND_API_BASE_URL`)は変更不要
   （既存Workerへのコード追加のみで、URLも `USE_LIVE_FRIEND_BACKEND` も変わらない）。
3. **KV書き込み予算の実測**: ハートビート(既定120秒間隔、`autoload/friend_manager.gd`
   の `HEARTBEAT_INTERVAL_SEC`)は無料枠(1日1,000件書き込み、全ユーザー合計)を
   最も消費する新規要素。デプロイ後、Cloudflareダッシュボードの
   Workers & Pages → `tag-game-friend-api` → Metrics → KV書き込み数を数日分観測し、
   同時プレイ人数に対して余裕があるか確認する。厳しければ
   `HEARTBEAT_INTERVAL_SEC` を伸ばす、または有料プラン($5/月、KV書き込み上限が
   大幅に緩和)への移行を検討する。
4. 検索(`/search-user`)・詳細情報(`/friend-profile`)の実機確認: 2アカウントで
   フレンド未成立の状態から検索→追加→承諾→フレンド一覧のオンライン表示→詳細ダイアログ、
   の一連の流れを実際にクリックして確認する（`service/friend-api/README.md`参照）。

**完了条件**: 本番デプロイ後、2アカウント間で検索→追加→オンライン状態表示→詳細情報表示が
実際に動作し、KV書き込み量が無料枠に対して余裕があることを確認する。

**2026-09-12 実施**: 手順1(`npx tsc --noEmit`)をエラー無しで確認後、`npx wrangler deploy`
実施済み(Version ID `83d3c5fe-7477-4338-b07c-8072aafb75df`)。`curl`で`/search-user`・
`/heartbeat`・`/friend-profile`の3エンドポイントとも、`Authorization`ヘッダ無し・不正トークンの
両方で401を返すことを確認済み(既存エンドポイントと同じ挙動)。

**手順4(2アカウントでの実機確認)はユーザーの意向により今回は省略する。**

**2026-09-12 追加実施(KV書き込み削減)**: KV無料枠(1日1,000件、`service/commerce-api`とも
アカウント単位で共有)への懸念から、ハートビートの書き込みを2件削減する2つの対応を実装・
デプロイした: (1) `/heartbeat`のレート制限カウンタ(旧`rlheartbeat:<puid>:<date>`)を
`presence:<puid>`自体に統合し、1呼び出しあたりのKV書き込みを2件→1件に削減
([service/friend-api/src/index.ts](../service/friend-api/src/index.ts)の`handleHeartbeat()`)。
(2) クライアント側(`autoload/friend_manager.gd`)で、フレンドが1人もいない間はハートビート
自体を送らないようにした(`_update_heartbeat_state()`、`get_friends()`呼び出しのたびに再評価)。
手順3(KV書き込み量の数日観測)は引き続き未実施 — デプロイから数日経ってから
Cloudflareダッシュボードで確認すること。


## 9. レートのサーバー権威化（C-03・`service/rating-api`）— 未デプロイ

詳細手順: [service/rating-api/README.md](../service/rating-api/README.md)

**状況**: コードは R-1〜R-12 まで完了しているが、**D1 の作成・デプロイはまだ行っていない**。
[autoload/backend_config.gd](../autoload/backend_config.gd) の `USE_LIVE_RATING_BACKEND` は
`false` のままで、レートはクライアントのローカル自己計算が最終値になっている。
切り替えを阻んでいた穴（`/report-match` の報告者検証・切断ペナルティの累積・
`/claim-initial-rating` の自己申告上限）は R-10 で塞ぎ済み。

### 9-1. デプロイ

```sh
cd service/rating-api
npx wrangler d1 create tag-game-rating-db
# 出力された database_id を wrangler.toml の [[d1_databases]].database_id に設定する
npx wrangler d1 execute tag-game-rating-db --remote --file=schema.sql
npx wrangler deploy
```

デプロイ後、実機の EOS Connect ID Token で5エンドポイント（`/report-match`
`/report-disconnect-penalty` `/claim-initial-rating` `/rating` `/leaderboard-top`）を
手動で叩き、401/200 双方の応答を確認する。`wrangler.toml` の `[vars]` に
`ALLOW_DEBUG_AUTH` を**絶対に書かないこと**（`.dev.vars` 限定）。

### 9-2. 旧 friend-api の `penalty:*` キーの掃除

C-03 R-5 で `service/friend-api` の `/report-penalty`・`/consume-penalty` を廃止し、
`service/rating-api` の `/report-disconnect-penalty` へ統合した。コード側の削除は完了して
いるが、**本番 KV（`FRIEND_KV`）に残っている `penalty:<puid>` キーは誰も読まなくなった**
（＝適用されないまま残るゴミキー）。`USE_LIVE_FRIEND_BACKEND` は既に `true` ＝本番稼働中
なので、実データが存在する可能性がある。

```sh
cd service/friend-api
# 1) 残存確認（0件ならこの手順は不要。--local を付けなければ本番KVを見る）
npx wrangler kv key list --binding FRIEND_KV --prefix "penalty:"

# 2) 上のリストを見て消してよいことを確認したら、その出力をそのまま
#    kv bulk delete へ渡す（[{"name":"penalty:xxx"}, ...] 形式をそのまま受け付ける）
npx wrangler kv key list --binding FRIEND_KV --prefix "penalty:" > penalty-keys.json
npx wrangler kv bulk delete --binding FRIEND_KV penalty-keys.json
rm penalty-keys.json
```

（コマンドの形は wrangler 3.114.17 で `--help` を実際に引いて確認済み。
`kv key list` / `kv bulk delete` とも `--local` を付けなければ本番KVを対象にする。）

**注意**: この掃除は「適用されずに消える未適用ペナルティ」を確定させる操作である。
残っている件数が多い場合は、消す前に一覧を保存しておくとよい（レートに反映されなかった
切断ペナルティの実数がわかる）。急ぐ必要は無いので、9-1 の後で構わない。

**完了条件**: `npx wrangler kv key list --binding FRIEND_KV --prefix "penalty:"` が空になる。

### 9-3. クライアント配布と `USE_LIVE_RATING_BACKEND` 切替の順序

**この節が C-03 で最も事故りやすい。** 2つの独立した注意点がある。

**(a) 切断ペナルティの空白期間を作らないこと（C-03 R-5）**

`USE_LIVE_RATING_BACKEND` の `false→true` と、旧 friend-api 経路を削除した
クライアントビルドの配布は**必ず同時に行う**。現状
（`USE_LIVE_FRIEND_BACKEND=true` / `USE_LIVE_RATING_BACKEND=false`）では旧 friend-api
経由の切断ペナルティが実際に機能している唯一の経路であり、新旧の切り替えがずれると
切断ペナルティが完全に無効化される空白期間が生まれる。
また、配布済みの旧クライアントが `/report-penalty` を叩くと **404** になる
（エンドポイントごと削除済みのため）。クライアント側は失敗時に何もしない設計なので
クラッシュはしないが、そのビルドのペナルティは記録されない。

**(b) 同じ `PROTOCOL_VERSION` のまま挙動が変わるビルドがあること（C-03 R-11 / R-12）**

R-11（`cpu_hunter_count` の送信・CPU鬼トドメの報告）と R-12（補正RPCの受信側検証）は
**RPC のメソッド名・シグネチャ・ノードパスを変えていない**ため
`PROTOCOL_VERSION` を上げていない（CLAUDE.md の鉄則どおり、上げる必要が無い）。
つまり **v11 の新旧ビルドが同じ試合に同居しうる**。影響は次のとおりで、いずれも
収束するので版数を上げる必要は無いが、把握しておくこと:

- ホストが旧 v11 ビルドだと `cpu_hunter_count` が送られない。サーバーは未指定を 0 と
  みなすので、CPU鬼を含む試合では R-11 以前と同じズレ（補正トーストが出る）が残る。
  ホストが新ビルドなら参加者が旧ビルドでも正しく揃う（Nを決めるのはホストの報告だけ）。
- 参加者が旧 v11 ビルドだと補正RPCの値域検証が無い。ただし正しい値を配るのはサーバー
  なので、正常系では違いが出ない。

**完了条件**: 9-1 のデプロイと `USE_LIVE_RATING_BACKEND=true` のクライアントビルド配布が
同日中に完了し、ランクマッチ1試合の結果が D1 の `ratings` テーブルへ実際に反映されること。
