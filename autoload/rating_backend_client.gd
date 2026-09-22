class_name RatingBackendClient

## service/rating-api/ の /report-match /claim-initial-rating /rating を呼ぶ薄いラッパー
## (C-03 R-3/R-4)。autoload/friend_backend_client.gd と同じ型
## (static func + HttpJsonClient.post_json())。

const RATING_API_BASE_URL := BackendConfig.RATING_API_BASE_URL


static func _auth_headers() -> PackedStringArray:
	return PackedStringArray(["Authorization: Bearer " + EosManager.get_id_token()])


## toucher_puidはrunner_escaped=falseの時のみ有効な文字列、=trueの時は必ずnullで渡すこと
## (呼び出し側=rating_report.gdの責務。ここではそのまま転送するだけで検証しない)
static func report_match(host: Node, match_id: String, runner_puid: String,
		hunter_puids: Array, runner_escaped: bool, toucher_puid,
		survival_time: float) -> Dictionary:
	return await HttpJsonClient.post_json(host, RATING_API_BASE_URL + "report-match", {
		"match_id": match_id,
		"runner_puid": runner_puid,
		"hunter_puids": hunter_puids,
		"runner_escaped": runner_escaped,
		"toucher_puid": toucher_puid,
		"survival_time": survival_time,
	}, _auth_headers())


## C-03 R-4: 起動時、初回のみ呼ぶ。既にサーバー側に行がある場合はalready_claimedで拒否される
## (呼び出し側=ranking_manager.gdはProfileManager.initial_rating_claimedで再送を防ぐのが主ガード、
## これはあくまで安全網)
static func claim_initial_rating(host: Node, rating: int) -> Dictionary:
	return await HttpJsonClient.post_json(host, RATING_API_BASE_URL + "claim-initial-rating", {
		"rating": rating,
	}, _auth_headers())


## C-03 R-4: 起動時、サーバー権威のレートを取得する(ボディ無し)。行が無ければ
## claimed=falseで返る(エラーではない、呼び出し側の判定条件)
static func get_rating(host: Node) -> Dictionary:
	return await HttpJsonClient.post_json(host, RATING_API_BASE_URL + "rating", {}, _auth_headers())
