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

const FRIEND_API_BASE_URL := "https://tag-game-friend-api.oekklab.workers.dev/"
const COMMERCE_API_BASE_URL := "https://tag-game-commerce-api.oekklab.workers.dev/"

## デプロイ・動作確認が済むまでfalseにするロールアウト規約
## (friend_manager.gd/purchase_manager.gdのコメント参照)
const USE_LIVE_PURCHASES := true
const USE_LIVE_FRIEND_BACKEND := true
