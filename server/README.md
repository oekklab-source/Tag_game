# Stripe backend (solpinto.jp)

Payments / Billing / Invoicing 用の最小構成バックエンド。シークレットキーはここ（サーバー）にのみ置き、ゲームクライアントや他のフロントエンドには一切渡さない。

## セットアップ

```bash
cd server
npm install
cp .env.example .env   # .env は既に用意済みなら不要
```

`.env` に Stripe のテストキーを設定する（`.env` は git 管理外）。

```bash
npm run dev
```

Webhook をローカルで受け取るには [Stripe CLI](https://docs.stripe.com/cli.md) を使う。

```bash
stripe listen --forward-to localhost:4242/api/webhook
```

表示された `whsec_...` を `.env` の `STRIPE_WEBHOOK_SECRET` に設定する。

## エンドポイント

| メソッド | パス | 用途 |
| --- | --- | --- |
| POST | `/api/checkout/session` | 単発決済（Payments）の Checkout Session 作成 |
| POST | `/api/billing/checkout-session` | サブスクリプション（Billing）の Checkout Session 作成 |
| POST | `/api/billing/portal-session` | 顧客がプラン変更・解約を行う Customer Portal セッション作成 |
| POST | `/api/invoices` | 請求書（Invoicing）の作成・メール送信 |
| POST | `/api/webhook` | Stripe からの Webhook 受信（署名検証あり） |

## 未実装・要対応（本番前に必須）

- Products / Prices を Dashboard または API で作成し、Price ID を各リクエストに渡す
- Webhook ハンドラ内のフルフィルメント処理（DB へのアクセス権付与など）の実装
- Stripe Tax（消費税等）の設定。日本国内向けのみなら現時点では不要だが、越境販売を行うなら要検討
- シークレットキー（`sk_test_...`）から制限付きAPIキー（`rk_...`、必要な権限のみ付与）への切り替え
- 本番移行時は `sk_test_` / `pk_test_` を本番用キーに差し替え、`.env` はコミットしない
