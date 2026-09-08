class_name FriendBackendClient

## service/friend-api/ の各エンドポイントを呼ぶ薄いラッパー。Worker URLの知識は
## このファイルだけに閉じ込める(stripe_purchase_provider.gdがcommerce-api/の
## URLを一手に引き受けるのと同じ方針)。

const FRIEND_API_BASE_URL := "https://tag-game-friend-api.oekklab.workers.dev/"


static func sync(host: Node, puid: String, display_name: String) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "sync", {
		"puid": puid,
		"display_name": display_name,
	})


static func send_request(host: Node, puid: String, code: String) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "send-request", {
		"puid": puid,
		"code": code,
	})


static func list_requests(host: Node, puid: String) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "list-requests", {
		"puid": puid,
	})


static func respond_request(host: Node, puid: String, request_id: String, accept: bool) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "respond-request", {
		"puid": puid,
		"request_id": request_id,
		"action": "accept" if accept else "decline",
	})


static func list_friends(host: Node, puid: String) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "list-friends", {
		"puid": puid,
	})


static func remove_friend(host: Node, puid: String, friend_puid: String) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "remove-friend", {
		"puid": puid,
		"friend_puid": friend_puid,
	})


## ⑦レーティング戦の逃走者切断時のCPU代行(暫定実装)用。ホストが切断検知時に呼ぶ
static func report_penalty(host: Node, puid: String, rating_delta: int) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "report-penalty", {
		"puid": puid,
		"rating_delta": rating_delta,
	})


## ⑦本人クライアントが起動時に一度だけ呼ぶ。取得と同時にサーバー側で削除される
static func consume_penalty(host: Node, puid: String) -> Dictionary:
	return await HttpJsonClient.post_json(host, FRIEND_API_BASE_URL + "consume-penalty", {
		"puid": puid,
	})
