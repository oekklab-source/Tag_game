# Tag_Game Purchase API

Steamworks Microtransactions の `InitTxn`/`FinalizeTxn` をサーバー間で呼び出す、ゲーム本体(P2Pホスティング)とは独立した軽量Webサービス(Cloudflare Workers)。

## 前提条件

- Steamworksパートナーで Microtransactions が有効化され、実AppID・Item Definition・Publisher Web APIキーが発行されていること(現状申請中)。
- `src/index.ts` の `PACKS` テーブルの `itemDefId` を、Steamworksパートナーサイトで実際に作成したItem Definition IDに置き換えること。

## セットアップ

```
npm install
npx wrangler kv namespace create PURCHASE_TXNS
# 出力された id を wrangler.toml の kv_namespaces.id に設定する

npx wrangler secret put STEAM_WEB_API_KEY
# Steamworksパートナーサイトで発行されたPublisher Web APIキーを入力する
```

## ローカル動作確認 / デプロイ

```
npm run dev      # ローカルでの動作確認 (wrangler dev)
npm run deploy    # Cloudflare Workersへデプロイ
```

デプロイ後のURLを `autoload/steam_purchase_provider.gd` の `PURCHASE_API_BASE_URL` に設定する。

## 既知の未実装点(実機確認待ち)

- `/init-txn` のなりすまし対策(`AuthenticateUserTicket`)は、クライアント側で `Steam.getAuthSessionTicket()` 相当の実装が未着手のため、常に `ticket_hex` が空文字で送られ fail-closed で拒否される。クライアント側実装完了後に有効化される。
- Steamworks Web API のパラメータ名/レスポンス形式は実装時点の一般的な仕様に基づく。実AppID取得後、Steamworks公式ドキュメントで最新仕様と突き合わせて確認すること。
