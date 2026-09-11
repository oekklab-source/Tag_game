class_name FriendBackendClient

## service/friend-api/ の各エンドポイントを呼ぶ薄いラッパー。Worker URLの知識は
## このファイルだけに閉じ込める(stripe_purchase_provider.gdがcommerce-api/の
## URLを一手に引き受けるのと同じ方針)。
##
## 認証: 呼び出し元の身元はbodyのpuidではなく、EosManager.get_id_token()が返す
## EOS Connect ID Token(JWT)をAuthorizationヘッダで送って証明する。Workerは
## トークンを検証し、そこに含まれるPUID(subクレーム)だけを本人のPUIDとして扱う
## (詳細はservice/friend-api/src/index.tsのverifyIdToken())。

## 値の実体は autoload/backend_config.gd に集約してある(設定を一元化するため)。
## ここに残すのは既存の参照箇所(このファイル内)を書き換えないための転送のみ
const FRIEND_API_BASE_URL := BackendConfig.FRIEND_API_BASE_URL


static func _auth_headers() -> PackedStringArray:
	return PackedStringArray(["Authorization: Bearer " + EosManager.get_id_token()])


## statsは任意(空辞書なら送らない)。フレンドにのみ公開する戦績/レート/スキンの
## 自己申告アップロード(autoload/friend_manager.gd._upload_my_stats_now()から渡される)
static func sync(host: Node, display_name: String, stats: Dictionary = {}) -> Dictionary:
	var body := {"display_name": display_name}
	if not stats.is_empty():
		body["stats"] = stats
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "sync", body, _auth_headers())


## コード完全一致 or 表示名完全一致でユーザーを検索する(mode: "code" | "name")
static func search_user(host: Node, query: String, mode: String) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "search-user", {
		"query": query,
		"mode": mode,
	}, _auth_headers())


## オンライン在席の生存通知。autoload/friend_manager.gdが一定間隔で呼ぶ
static func heartbeat(host: Node) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "heartbeat", {}, _auth_headers())


## フレンド1人の詳細(オンライン状態・戦績・レート・最終ログイン・スキン)
static func friend_profile(host: Node, friend_puid: String) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "friend-profile", {
		"friend_puid": friend_puid,
	}, _auth_headers())


static func send_request(host: Node, code: String) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "send-request", {
		"code": code,
	}, _auth_headers())


static func list_requests(host: Node) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "list-requests", {}, _auth_headers())


static func respond_request(host: Node, request_id: String, accept: bool) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "respond-request", {
		"request_id": request_id,
		"action": "accept" if accept else "decline",
	}, _auth_headers())


static func list_friends(host: Node) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "list-friends", {}, _auth_headers())


static func remove_friend(host: Node, friend_puid: String) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "remove-friend", {
		"friend_puid": friend_puid,
	}, _auth_headers())


## ⑦レーティング戦の逃走者切断時のCPU代行(暫定実装)用。ホストが切断検知時に呼ぶ。
## target_puidは切断した相手の自己申告PUID(peer_profiles由来、未検証)ーー
## 呼び出し元自身の身元はAuthorizationヘッダのトークンで証明する
static func report_penalty(host: Node, target_puid: String, rating_delta: int) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "report-penalty", {
		"puid": target_puid,
		"rating_delta": rating_delta,
	}, _auth_headers())


## ⑦本人クライアントが起動時に一度だけ呼ぶ。取得と同時にサーバー側で削除される
static func consume_penalty(host: Node) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "consume-penalty", {}, _auth_headers())
