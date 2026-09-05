extends Node

## ⑤フレンド機能 Autoload。EOS Product User ID(PUID)をキーにした自前の
## フレンドリストシステム(service/friend-api/、Cloudflare Workers)を使う。
##
## EOS純正のFriends APIは使わない: Epic Account Services(EAS)ログインが必須で、
## Steam/itch.io経由でプレイする大多数のプレイヤーはEpicアカウントを持っていない
## ため。代わりにサーバー側生成の不透明なフレンドコードで1:1追加する方式にし、
## PUID自体は列挙・検索できないようにしてある(詳細はfriend-api/README.md)。
##
## EosManagerと同じ方針(バックエンド無効時はモックデータで
## フォールバックし、クラッシュを防ぐ)に倣う。USE_LIVE_FRIEND_BACKENDは
## PurchaseManager.USE_LIVE_PURCHASESと同じ「デプロイ・動作確認が済むまでfalse」
## のロールアウト規約。

const USE_LIVE_FRIEND_BACKEND := false


## ⑤自分のフレンドコードを取得/生成する。フレンド画面が開いた際に呼ぶ。
## 失敗時は空文字列を返す(クラッシュしない)
func sync_with_backend() -> String:
	if USE_LIVE_FRIEND_BACKEND and EosManager.is_eos_available:
		var res := await FriendBackendClient.sync(self, EosManager.product_user_id, ProfileManager.player_name)
		if not res.get("api_ok", false):
			return ""
		return String(res.get("friend_code", ""))
	return "DEV12345"


## ⑤フレンド一覧を返す。各要素: {id: String(PUID), name, online}
## online は現時点では常にfalse(v1では在席状況を追跡しない、friend-api/README.md参照)
func get_friends() -> Array[Dictionary]:
	if USE_LIVE_FRIEND_BACKEND and EosManager.is_eos_available:
		var res := await FriendBackendClient.list_friends(self, EosManager.product_user_id)
		if not res.get("api_ok", false):
			return []
		var out: Array[Dictionary] = []
		for f in res.get("friends", []):
			out.append({"id": String(f.get("puid", "")), "name": String(f.get("name", "Friend")), "online": false})
		return out
	return _mock_friends()


## ⑤自分に届いている保留中のフレンドリクエスト一覧
func get_pending_requests() -> Array[Dictionary]:
	if USE_LIVE_FRIEND_BACKEND and EosManager.is_eos_available:
		var res := await FriendBackendClient.list_requests(self, EosManager.product_user_id)
		if not res.get("api_ok", false):
			return []
		var out: Array[Dictionary] = []
		for r in res.get("requests", []):
			out.append({
				"request_id": String(r.get("request_id", "")),
				"from_puid": String(r.get("from_puid", "")),
				"from_name": String(r.get("from_name", "Friend")),
			})
		return out
	return [{"request_id": "mock-request-1", "from_puid": "mock-puid-9", "from_name": "MockRequester"}]


## ⑤フレンドコードを使ってリクエストを送る。戻り値: {ok, target_name, reason}
func send_friend_request(code: String) -> Dictionary:
	if code.is_empty():
		return {"ok": false, "target_name": "", "reason": "invalid_code"}
	if USE_LIVE_FRIEND_BACKEND and EosManager.is_eos_available:
		var res := await FriendBackendClient.send_request(self, EosManager.product_user_id, code)
		if not res.get("api_ok", false):
			return {"ok": false, "target_name": "", "reason": String(res.get("reason", "network_error"))}
		return {"ok": true, "target_name": String(res.get("target_name", "")), "reason": ""}
	return {"ok": true, "target_name": "MockFriend", "reason": ""}


## ⑤フレンドリクエストに応答する(承諾/拒否)
func respond_to_request(request_id: String, accept: bool) -> bool:
	if USE_LIVE_FRIEND_BACKEND and EosManager.is_eos_available:
		var res := await FriendBackendClient.respond_request(self, EosManager.product_user_id, request_id, accept)
		return res.get("api_ok", false) and res.get("ok", false)
	return true


## ⑤フレンドを解除する(双方向)
func remove_friend(friend_puid: String) -> bool:
	if USE_LIVE_FRIEND_BACKEND and EosManager.is_eos_available:
		var res := await FriendBackendClient.remove_friend(self, EosManager.product_user_id, friend_puid)
		return res.get("api_ok", false) and res.get("ok", false)
	return true


## ⑤自分がロビー中の場合のみ、接続先アドレスをクリップボードにコピーする。
## EOS Lobbiesにはpushでの招待APIが無いため、既存のDirectConnect導線に
## 相手が貼り付けられるようにする代替手段(配信確認はできない)
func invite_to_lobby() -> bool:
	if EosManager.current_lobby_id.is_empty():
		return false
	if EosManager.is_eos_available:
		var addr := await EosManager.await_host_addr(EosManager.current_lobby_id)
		if addr.is_empty():
			return false
		DisplayServer.clipboard_set(addr)
		return true
	DisplayServer.clipboard_set("127.0.0.1")
	return true


## バックエンド無効時、⑤のUIをオフラインでも確認できるようにするモックフレンド一覧
func _mock_friends() -> Array[Dictionary]:
	return [
		{"id": "mock-puid-1", "name": "SpeedMaster", "online": true},
		{"id": "mock-puid-2", "name": "Ninja_Shadow", "online": false},
		{"id": "mock-puid-3", "name": "ChillRunner", "online": true},
	]
