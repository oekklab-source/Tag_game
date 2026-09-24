class_name RatingBackendClient

## service/rating-api/ の /report-match /claim-initial-rating /rating を呼ぶ薄いラッパー
## (C-03 R-3/R-4)。autoload/friend_backend_client.gd と同じ型
## (static func + HttpJsonClient.post_json())。

const RATING_API_BASE_URL := BackendConfig.RATING_API_BASE_URL


static func _auth_headers() -> PackedStringArray:
	return PackedStringArray(["Authorization: Bearer " + EosManager.get_id_token()])


## toucher_puidはrunner_escaped=falseの時のみ有効な文字列、=trueの時は必ずnullで渡すこと。
## CPU鬼がトドメを刺した試合もnullで渡す(C-03 R-11。サーバーは toucher が null なら
## §2.5のトドメ再分配を行わない)。
## (どちらも呼び出し側=rating_report.gdの責務。ここではそのまま転送するだけで検証しない)
##
## cpu_hunter_countはCPUが埋めた鬼の人数(C-03 R-11)。hunter_puidsは人間だけなので、
## これを送らないとサーバーの N が人間数になり、クライアントの楽観計算(CPU込みの
## round_hunter_count)と必ず食い違う
static func report_match(host: Node, match_id: String, runner_puid: String,
		hunter_puids: Array, runner_escaped: bool, toucher_puid,
		survival_time: float, cpu_hunter_count: int) -> Dictionary:
	return await HttpJsonClient.post_json(host, RATING_API_BASE_URL + "report-match", {
		"match_id": match_id,
		"runner_puid": runner_puid,
		"hunter_puids": hunter_puids,
		"runner_escaped": runner_escaped,
		"toucher_puid": toucher_puid,
		"survival_time": survival_time,
		"cpu_hunter_count": cpu_hunter_count,
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


## C-03 R-5: 対戦中の切断(鬼/逃走者/ホスト自身)1件につき、対象1名の敗北分をサーバーへ
## 直接・権威的に反映させる(旧service/friend-apiの/report-penalty・/consume-penaltyの後継)。
## match_idはこちらから送らない――rating-api側がtarget_puid/was_runner/hunter_count/
## self_ratingから決定的に導出する(host_migration.gd/network_manager.gdの両呼び出し元の
## コメント参照。ホスト自身の切断時は生存者全員が独立にこの関数を呼びうるため、
## dedupをサーバー側の決定的ID導出に委ねる設計)
static func report_disconnect_penalty(host: Node, target_puid: String, was_runner: bool,
		hunter_count: int, self_rating: int, rating_delta: int,
		survival_time: float = -1.0, opponent_avg_rating: int = -1) -> Dictionary:
	var body := {
		"target_puid": target_puid,
		"was_runner": was_runner,
		"hunter_count": hunter_count,
		"self_rating": self_rating,
		"rating_delta": rating_delta,
	}
	if survival_time >= 0.0:
		body["survival_time"] = survival_time
	if opponent_avg_rating >= 0:
		body["opponent_avg_rating"] = opponent_avg_rating
	return await HttpJsonClient.post_json(
		host, RATING_API_BASE_URL + "report-disconnect-penalty", body, _auth_headers())


## C-03 R-6: ランキング画面表示用。/leaderboard-top は verifyIdToken() を経由しない
## 公開エンドポイントのため、他メソッドと違い認証ヘッダを付けない
static func get_leaderboard_top(host: Node, limit: int = 20) -> Dictionary:
	return await HttpJsonClient.get_json(host, RATING_API_BASE_URL + ("leaderboard-top?limit=%d" % limit))
