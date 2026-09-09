class_name HttpJsonClient

## service/commerce-api や service/friend-api のような、独自のCloudflare Workers
## バックエンドへPOST+JSON往復する呼び出しの共通ヘルパー。stripe_purchase_provider.gd
## の _call_api() と同じ契約を持つ(ネットワーク層が成功しJSONとして解釈できた場合
## のみ api_ok=true を含めてレスポンスをそのまま返す)。
## HTTPRequest.timeout はデフォルト0(無制限)。ネットワーク到達性が無い/不安定な
## 環境(パケットが黙って落ちるファイアウォール等)ではOSレベルのTCPタイムアウト任せに
## なり、数分単位で無応答になりうる。特にRankingManagerの起動時ペナルティ確認のように
## ユーザー操作を介さず自動発火する呼び出しでは、これがそのままアプリ起動のフリーズに
## 直結するため、全呼び出し共通でタイムアウトを必ず設定する
const REQUEST_TIMEOUT_SEC := 10.0


static func post_json(host: Node, url: String, body: Dictionary, extra_headers: PackedStringArray = []) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT_SEC
	host.add_child(http)
	var headers := PackedStringArray(["Content-Type: application/json"])
	headers.append_array(extra_headers)
	var err := http.request(
		url,
		headers,
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
