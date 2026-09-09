# Tag_Game Friend API

EOS Product User ID(PUID)をキーにした自前フレンドリスト用の軽量Webサービス(Cloudflare Workers)。EOS Friends API(Epic Account Servicesログイン必須)は使わず、Steam/itch.io経由も含め全プレイヤーが同じ方式でフレンドを管理できるようにするための恒久的な正(source of truth)。

## 前提条件

- Cloudflareアカウント(`service/commerce-api/`と同じアカウントでよい)。
- secretsは不要だが、EpicのJWKS(`https://api.epicgames.dev/auth/v1/oauth/jwks`)への外部fetchに依存する。

## 認証

全エンドポイントは`Authorization: Bearer <EOS Connect ID Token>`ヘッダを必須とする。クライアントはbodyで
PUIDを名乗らず、`EosManager.get_id_token()`が返すJWTを送る。Workerは`verifyIdToken()`でEpicの公開鍵
(JWKS)を使い署名・`exp`・`iss`・`aud`を検証し、トークンの`sub`クレームを本人のPUIDとして採用する
(bodyの`puid`は信用しない)。`/report-penalty`の対象PUID(`body.puid`、切断した相手)だけは例外的に
ホストの自己申告のままーーサーバーは対戦の存在自体を知らないため検証しようがなく、既知の制約として
受容している。

## セットアップ

```
npm install
npx wrangler kv namespace create FRIEND_KV
# 出力された id を wrangler.toml の kv_namespaces.id に設定する
```

## ローカル動作確認 / デプロイ

```
npm run dev      # ローカルでの動作確認 (wrangler dev)
npm run deploy    # Cloudflare Workersへデプロイ
```

デプロイ後のURLを `autoload/friend_backend_client.gd` の `FRIEND_API_BASE_URL` に設定し、動作確認後に `autoload/friend_manager.gd` の `USE_LIVE_FRIEND_BACKEND` を `true` にする。

## 既知の制約(v1)

- **オンライン在席状況(presence)は追跡しない。** `get_friends()`の`online`は常に`false`。ゲーム内のリアルタイム対戦接続(WebSocket/Cloudflare Tunnel)とこのAPIの間に経路が無く、ハートビート方式はKV書き込み回数(無料枠1日1,000件)をすぐに消費してしまうため。
- **pushでの招待配信は無い。** ロビー招待は「接続先アドレスをクリップボードにコピーし、相手がDirectConnectタブへ貼り付ける」形。配信確認もできない。
- **送信済みフレンドリクエストは受信側にのみ残る。** 送信側がアプリを再起動すると「送った」という状態は残らない(再送しても受信側では冪等に扱われるため実害は無いが、UX上の見え方には留意)。
- **PUID/フレンドコードの一覧・検索エンドポイントは意図的に存在しない。** フレンドコードを直接知っている相手としか繋がれない。
- Cloudflare無料枠(Workers: 1日10万リクエスト、KV: 1日読み取り10万/書き込み1,000、容量1GB)を超えると、自動課金ではなくその日はエラーになる。有料プランへの移行は手動アップグレードが必要。
