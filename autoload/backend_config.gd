extends Node

## Cloudflare Workers(friend-api / commerce-api)のURLと、
## 実バックエンドを使うかのフラグを1ファイルに集約する。
## 「本番に出す前に見る場所が1ファイルで済む」のが狙い。
##
## 各値の元の定義場所には後方互換の転送用 const を残してある
## (テスト等が既存のパス、例: PurchaseManager.USE_LIVE_PURCHASES で参照しているため):
##   FRIEND_API_BASE_URL   -> autoload/friend_backend_client.gd
##   COMMERCE_API_BASE_URL -> autoload/stripe_purchase_provider.gd
##   USE_LIVE_PURCHASES    -> autoload/purchase_manager.gd
##   USE_LIVE_FRIEND_BACKEND -> autoload/friend_manager.gd
##   RATING_API_BASE_URL   -> autoload/rating_backend_client.gd
##   USE_LIVE_RATING_BACKEND -> autoload/game/rating_report.gd

const FRIEND_API_BASE_URL := "https://tag-game-friend-api.oekklab.workers.dev/"
const COMMERCE_API_BASE_URL := "https://tag-game-commerce-api.oekklab.workers.dev/"
## C-03: レートのサーバー権威化(R-1/R-2実装済み)。ワーカー名"tag-game-rating-api"から
## 他2サービスと同じ命名規則で類推した値。wrangler deploy実施後、実際の出力URLと
## 一致するか必ず確認すること(食い違っていればここを直すだけでよい)
const RATING_API_BASE_URL := "https://tag-game-rating-api.oekklab.workers.dev/"

## デプロイ・動作確認が済むまでfalseにするロールアウト規約
## (friend_manager.gd/purchase_manager.gdのコメント参照)
const USE_LIVE_PURCHASES := true
const USE_LIVE_FRIEND_BACKEND := true
## R-2でエンドポイント実装済みだが、wrangler d1 create/wrangler deployが未実施
## (service/rating-api/README.md参照)。デプロイ・動作確認が済むまでfalseにする。
## trueにする前に必ず: ①wrangler d1 create ②schema.sql適用 ③wrangler deploy
## ④実EOSトークンでの手動疎通確認、の順で行うこと
const USE_LIVE_RATING_BACKEND := false
