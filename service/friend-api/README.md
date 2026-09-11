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

## 既知の制約(v2: 検索・オンライン状態・戦績公開を追加)

- **PUIDの一覧・列挙エンドポイントは意図的に存在しない。** `/search-user`はコード完全一致 or
  表示名完全一致のみ(KVの`get()`は完全一致lookupしかできないため、前方一致・部分一致・
  一覧列挙は構造的に実装できない)。かつPUIDそのものは返さない(コードと表示名のみ)。
  正確な表示名を知っている相手のコードは特定できてしまう点は
  [docs/SECURITY_NOTES.md](../../docs/SECURITY_NOTES.md)の5番に記載して受容している。
- **オンライン在席状況(presence)はハートビート方式。** クライアントが`/heartbeat`を
  一定間隔(既定120秒、`autoload/friend_manager.gd`の`HEARTBEAT_INTERVAL_SEC`)で呼び、
  `presence:<puid>`の`last_seen`をサーバー側の`ONLINE_THRESHOLD_MS`(5分)で判定する。
  **KV書き込み予算(無料枠1日1,000件、全ユーザー合計)を最も消費する要素**なので、
  デプロイ後は[docs/DEPLOYMENT_CHECKLIST.md](../../docs/DEPLOYMENT_CHECKLIST.md)の
  8番に従って実測し、必要なら間隔を伸ばすか有料プランへ移行すること。
- **戦績・レート・スキン(`stats:<puid>`)は自己申告・未検証。** `/sync`の`stats`フィールドを
  クライアントがそのまま送るだけで、サーバー側の検証は無い。フレンドにしか見えず実際の
  EOSリーダーボード/レーティングには影響しないため、実害は小さいと判断している
  ([docs/SECURITY_NOTES.md](../../docs/SECURITY_NOTES.md)の6番)。
- **pushでの招待配信は無い。** ロビー招待は「接続先アドレスをクリップボードにコピーし、相手がDirectConnectタブへ貼り付ける」形。配信確認もできない。
- **送信済みフレンドリクエストは受信側にのみ残る。** 送信側がアプリを再起動すると「送った」という状態は残らない(再送しても受信側では冪等に扱われるため実害は無いが、UX上の見え方には留意)。
- **新規4エンドポイントの業務エラーは200のまま`{ok:false, reason}`で返す。** 401(認証失敗)は
  例外的にHTTPステータスで返す(既存の挙動と同じ)。理由: `autoload/http_json_client.gd`の
  `post_json()`は200以外のレスポンスをボディごと`"network_error"`に潰してしまうため、
  クライアントへ実際に理由を届けたいエンドポイントではこの形を踏襲していない
  (既存の`/send-request`等の400/429応答は実質この制約に該当し、クライアントは理由を
  読めていない)。
- Cloudflare無料枠(Workers: 1日10万リクエスト、KV: 1日読み取り10万/書き込み1,000、容量1GB)を超えると、自動課金ではなくその日はエラーになる。有料プランへの移行は手動アップグレードが必要。
