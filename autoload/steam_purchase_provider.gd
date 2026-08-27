class_name SteamPurchaseProvider
extends PurchaseProvider

## ⑥Steamworks Microtransactionsを使った実課金プロバイダ。
## InitTxn/FinalizeTxnの呼び出しはPublisherキーをクライアントに置かないため、
## 本リポジトリ内の別サービス(service/purchase-api/)経由で行う。
## PurchaseProviderはRefCountedでツリーに属さないため、HTTPRequestノードの
## 追加先としてPurchaseManager(Node)自身をコンストラクタで受け取る。
##
## 実機のSteamworks AppID/Item Definition/Publisherキーが未承認のうちは
## エンドツーエンドで検証できない(申請中)。承認後に実機で以下を確認すること:
##   - GodotSteamのISteamMicroTxnコールバック(MicroTxnAuthorizationResponse等)の
##     正確な関数名・シグネチャ(バイナリ同梱アドオンのためソースから確認できず、
##     Godotエディタの「ヘルプ検索」でSteamシングルトンを調べる必要がある)
##   - PURCHASE_API_BASE_URL を実サービスのURLに差し替える

const PURCHASE_API_BASE_URL := "https://YOUR-PURCHASE-API-HOST/"

var _host: Node


func _init(host_node: Node) -> void:
	_host = host_node


func buy_pack(pack_id: StringName) -> Dictionary:
	if not SteamManager.is_steam_available:
		return {"ok": false, "granted_gems": 0, "reason": "steam_unavailable"}

	var init_res := await _call_api("init-txn", {
		"steam_id": SteamManager.steam_id,
		"app_id": SteamManager.DEFAULT_APP_ID,
		"pack_id": String(pack_id),
		# TODO: Steam.getAuthSessionTicket()(正確な関数名・戻り値形状は実機の
		# Godotエディタ「ヘルプ検索」で要確認)から取得したチケットを16進文字列で渡す。
		# サービス側は未実装(空文字)のうちは fail-closed で auth_ticket_required を返す
		"ticket_hex": "",
	})
	if not init_res.get("api_ok", false):
		return {"ok": false, "granted_gems": 0, "reason": init_res.get("reason", "network_error")}

	# TODO: 実機実装時、ここでSteamオーバーレイのマイクロトランザクション承認
	# コールバックを待ち受け、ユーザーが決済を承認/キャンセルしたかを確認する

	var finalize_res := await _call_api("finalize-txn", {
		"orderid": init_res.get("orderid", ""),
		"transid": init_res.get("transid", ""),
		"app_id": SteamManager.DEFAULT_APP_ID,
	})
	if not finalize_res.get("api_ok", false) or not finalize_res.get("granted", false):
		return {"ok": false, "granted_gems": 0, "reason": finalize_res.get("reason", "network_error")}

	return {"ok": true, "granted_gems": int(finalize_res.get("granted_gems", 0)), "reason": ""}


## service/purchase-api/ の1エンドポイントをPOSTで呼ぶ。ネットワーク層が成功し
## JSONとして解釈できた場合のみ api_ok=true を含めてレスポンスをそのまま返す
func _call_api(endpoint: String, body: Dictionary) -> Dictionary:
	var http := HTTPRequest.new()
	_host.add_child(http)
	var err := http.request(
		PURCHASE_API_BASE_URL + endpoint,
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		JSON.stringify(body)
	)
	if err != OK:
		http.queue_free()
		return {"api_ok": false, "reason": "network_error"}

	var args: Array = await http.request_completed
	http.queue_free()
	var result_code: int = args[0]
	var response_code: int = args[1]
	var response_body: PackedByteArray = args[3]
	if result_code != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return {"api_ok": false, "reason": "network_error"}

	var json := JSON.new()
	if json.parse(response_body.get_string_from_utf8()) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return {"api_ok": false, "reason": "network_error"}
	var data: Dictionary = json.data
	data["api_ok"] = true
	return data
