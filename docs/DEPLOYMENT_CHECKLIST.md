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

**完了条件**: ゲーム内のランキング画面（[scenes/ranking_dialog.gd](../scenes/ranking_dialog.gd)）に
実際のスコアが表示される。

## 2. Stripe 決済（Phase 1・`service/commerce-api`）

詳細手順: [service/commerce-api/README.md](../service/commerce-api/README.md)

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

**完了条件**: 別マシンから `curl` で `Authorization` ヘッダ無し・不正トークンでのリクエストが
両 Worker とも 401 で弾かれることを確認できる。`wrangler tail` にエラーが出ない。

## 6. EOS Client Policy の確認（Epic Developer Portal）

exe に同梱される `client_id`（`eos_credentials.cfg`）の Client Policy が、Connect / Lobbies / P2P / PDS /
Leaderboards など**必要最小限の権限のみ**になっているかを、Epic Developer Portal の画面で目視確認する。
過剰な権限（例: 他プロダクトの管理系スコープ）が付いていないことを確認する。

**完了条件**: Developer Portal のスクリーンショットで Client Policy の権限一覧を確認済み。
