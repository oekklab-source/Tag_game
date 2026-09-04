# Tag_Game Commerce API

Stripe Checkout の Session 作成・決済確認をサーバー間で呼び出す、ゲーム本体(P2Pホスティング)とは独立した軽量Webサービス(Cloudflare Workers)。

## 前提条件

- Stripeアカウントを作成し、まずテストモードのAPIキーを利用すること(本番鍵は動作確認完了まで使わない)。
- Stripe Dashboardで `small`/`medium`/`large` の3パックに対応する商品(Product)とPrice(JPY、ゼロ小数点通貨につき`unit_amount`はそのまま490/1220/2800)を事前に作成し、発行されたPrice ID(`price_...`)を `src/index.ts` の `PACKS` テーブルと `autoload/currency_pack_catalog.gd` の `stripe_price_id` へ設定すること。

## セットアップ

```
npm install
npx wrangler kv namespace create COMMERCE_TXNS
# 出力された id を wrangler.toml の kv_namespaces.id に設定する

npx wrangler secret put STRIPE_SECRET_KEY
# Stripeのsecret key(テストモードは sk_test_...)を入力する
```

## Webhookの設定

決済確定(ジェム付与の確定)は Stripe Webhook を唯一のソースオブトゥルースとする。デプロイ後、以下の手順で有効化すること:

1. `npm run deploy` でデプロイし、Workerのデプロイ先URLを控える。
2. Stripe Dashboard → 開発者 → Webhook で新しいエンドポイントを追加し、URLに `<デプロイ先URL>/stripe-webhook` を指定、イベントは `checkout.session.completed` と `checkout.session.expired` を選択する。
3. 発行されるsigning secret(`whsec_...`)を設定する:
```
npx wrangler secret put STRIPE_WEBHOOK_SECRET
```

## ローカル動作確認 / デプロイ

```
npm run dev      # ローカルでの動作確認 (wrangler dev)
npm run deploy    # Cloudflare Workersへデプロイ
```

デプロイ後のURLを `autoload/stripe_purchase_provider.gd` の `COMMERCE_API_BASE_URL` に設定し、動作確認後に `autoload/purchase_manager.gd` の `USE_LIVE_PURCHASES` を `true` にする。

## 既知の制約

- ジェム付与はサーバー権威のアカウントではなくクライアントローカルの `ProfileManager` が行う。決済成立(Webhook受信)後、クライアントが一度もそれを観測しないまま(アプリ終了・通信断など)放置されると、ゲームを次に起動した際の1回限りのリコンサイル処理(`StripePurchaseProvider.reconcile_pending()`)でのみ回収される。KVレコードのTTL(24時間)を超えて起動されなかった場合は回収できない。
- 本番切替時は、テストモードとは別に本番用のProduct/Priceを作成し直し、`PACKS`・`currency_pack_catalog.gd` のPrice IDおよびWebhookエンドポイントの再登録が必要。
