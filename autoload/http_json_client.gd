class_name HttpJsonClient

## service/commerce-api や service/friend-api のような、独自のCloudflare Workers
## バックエンドへPOST+JSON往復する呼び出しの共通ヘルパー。stripe_purchase_provider.gd
## の _call_api() と同じ契約を持つ(ネットワーク層が成功しJSONとして解釈できた場合
## のみ api_ok=true を含めてレスポンスをそのまま返す)。
static func post_json(host: Node, url: String, body: Dictionary) -> Dictionary:
	var http := HTTPRequest.new()
	host.add_child(http)
	var err := http.request(
		url,
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
