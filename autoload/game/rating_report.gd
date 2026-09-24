extends Node

## GameManager の子ノード。ランクマッチのホストが試合結果を rating-api の
## /report-match へ報告し、成功時に全ピアへレート補正RPCを配る(C-03 R-3)。
## (host_migration.gd / version_gate.gd と同じ子ノードパターン。
## _ready() で add_child され、全ピアで同一の NodePath になる)。
##
## CPU鬼の扱い(C-03 R-11で解決済み。R-3時点の「既知の制約」はもう無い):
## 人間の鬼が3人未満のランクマッチはCPU鬼が残り枠を埋める
## (game_manager.gd の request_start_round() 参照)。ここには2つの論点があり、
## どちらもR-11で対応した。
##  1. **人数(N)の整合**: hunter_puids は人間だけなので、CPU鬼の人数を
##     cpu_hunter_count として別に送り、サーバー側で人間鬼の平均レートの
##     プレースホルダを N に足して揃える。送らないとクライアント N=3 /
##     サーバー N=人間数 になり、期待値・分配・低レート帯ボーナスが全部ずれて、
##     R-4の補正トーストが毎試合出る(RV-04)。
##  2. **CPUがトドメを刺した試合**: report_touch() が tagger_id == -1 のまま
##     _end_round.rpc() するため有効な toucher_puid が無い。R-3では報告自体を
##     スキップしていたが(小規模ランクマッチでは普通に起こるため「負けても
##     レートが動かない試合」が発生していた)、R-11からは toucher_puid = null で
##     報告する。サーバーは toucher が null なら §2.5 のトドメ再分配を行わない
##     ——つまり「誰も30%の上乗せを受け取らない捕獲試合」として正しく処理される。

const USE_LIVE_RATING_BACKEND := BackendConfig.USE_LIVE_RATING_BACKEND

## class_name(RatingBackendClient)ではなくpreloadで参照するのは、class_nameの
## グローバル登録がheadless単体実行だと(特に新規ファイルは)更新されておらず
## "not declared in the current scope"になるケースがあったため。game_manager.gdの
## _SightSystemScript等と同じ理由・同じ対処(CIやheadlessテストでの再現性を優先)
const _RatingBackendClientScript := preload("res://autoload/rating_backend_client.gd")


# --- 純粋関数(ネットワーク・GameManager状態を読み書きしない。tests/test_rating_report.gdで直接検証) ---

## 報告すべきか。RUNNER_LEFTはhost_migration.gd/network_manager.gdの切断ペナルティ経路
## (rating-apiの/report-disconnect-penalty、C-03 R-5)が既に処理しているため対象外
## (二重処理を避けるためここでは触らない)
static func should_report(round_is_ranked: bool, reason: int, tagger_id: int) -> bool:
	if not round_is_ranked:
		return false
	if reason == GameManager.EndReason.RUNNER_LEFT:
		return false
	# C-03 R-11: TAGGED かつ tagger_id == -1(CPU鬼がトドメ)も報告する。
	# toucher_puid = null で送ればサーバーはトドメ再分配なしで計算する(ヘッダ参照)
	return true


## 人間の鬼(CPU除く)のPUID一覧をpeer_id昇順で構築する。1人でも自己申告PUIDが
## 空(EOS未接続)ならnullを返し、呼び出し側は報告全体を諦める(不完全な参加者集合で
## 報告するとサーバー側の人数計算が狂うため、部分報告は行わない)
static func build_hunter_puids(peer_profiles: Dictionary, human_hunter_ids: Array) -> Variant:
	var ids := human_hunter_ids.duplicate()
	ids.sort()
	var out: Array[String] = []
	for id in ids:
		var puid := String(peer_profiles.get(id, {}).get("puid", ""))
		if puid.is_empty():
			return null
		out.append(puid)
	return out


## CPUが埋めた鬼の人数(C-03 R-11)。GameManager.round_hunter_count はCPU込みの値
## (game_manager.gd の _start_round() 参照)なので、人間の鬼の人数を引けば求まる。
## 0未満にはならないようにクランプする(round_hunter_count が 0 のまま=ラウンド外で
## 呼ばれた場合に負数を送らないため)
static func cpu_hunter_count(round_hunter_count: int, human_hunter_count: int) -> int:
	return maxi(round_hunter_count - human_hunter_count, 0)


static func _generate_match_id() -> String:
	return "m-" + Crypto.new().generate_random_bytes(16).hex_encode()


# --- I/O(実際のHTTP・RPC。GameManager._end_round()からawaitなしで呼ぶfire-and-forget) ---

## GameManager._end_round()のホスト分岐から呼ぶ。ブロックしない(呼び出し側はawaitしないこと、
## _schedule_next_round()の発火を遅延させてはいけない)。失敗時(ネットワークエラー・
## not_claimed含む全業務エラー・タイムアウト)は何もしない==既存のローカル自己計算フロー
## (RankingManager.apply_match_end())がそのまま最終結果になる、という既定のフォールバック
func report_match_result(runner_won: bool, reason: int, tagger_id: int) -> void:
	if not (USE_LIVE_RATING_BACKEND and EosManager.is_eos_available):
		return
	if not should_report(GameManager.round_is_ranked, reason, tagger_id):
		return
	# ↓ここから先で使う値は全てawaitより前に同期的に確定させること。
	# await中に次ラウンドが始まるとGameManager.time_left等が_start_round()で
	# リセットされうる
	var survival_time := GameManager.ROUND_TIME - GameManager.time_left
	var runner_puid := String(GameManager.peer_profiles.get(GameManager.runner_id, {}).get("puid", ""))
	if runner_puid.is_empty():
		return
	var human_hunter_ids: Array = []
	for id in GameManager.player_ids():
		if id != GameManager.runner_id:
			human_hunter_ids.append(id)
	var hunter_puids = build_hunter_puids(GameManager.peer_profiles, human_hunter_ids)
	if hunter_puids == null:
		return
	var cpu_hunters := cpu_hunter_count(GameManager.round_hunter_count, human_hunter_ids.size())
	var runner_escaped := runner_won
	var toucher_puid = null
	if not runner_escaped and tagger_id != -1:
		# C-03 R-11: tagger_id == -1 はCPU鬼がトドメを刺した試合。その場合は
		# toucher_puid を null のままにして報告する(スキップしない)
		toucher_puid = String(GameManager.peer_profiles.get(tagger_id, {}).get("puid", ""))
		if toucher_puid.is_empty():
			return
	var match_id := _generate_match_id()

	var res := await _RatingBackendClientScript.report_match(
		self, match_id, runner_puid, hunter_puids, runner_escaped, toucher_puid,
		survival_time, cpu_hunters)
	if not res.get("api_ok", false) or not res.get("ok", false):
		return

	var entries := {}
	var runner_r: Dictionary = res.get("runner", {})
	if runner_r.has("puid"):
		entries[String(runner_r["puid"])] = {
			"rating_after": int(runner_r.get("rating_after", 0)),
			"delta": int(runner_r.get("delta", 0)),
		}
	for h in res.get("hunters", []):
		var hd: Dictionary = h
		entries[String(hd.get("puid", ""))] = {
			"rating_after": int(hd.get("rating_after", 0)),
			"delta": int(hd.get("delta", 0)),
		}
	_apply_rating_correction.rpc(entries)


## ホスト -> 全ピア。puidをキーにした補正値(peer_idではなくpuidにしたのは、RPC到達までの
## タイムラグの間にpeer_idの寿命(再接続等)を気にしなくて済むため)。自分のpuidが
## entriesに無ければ何もしない(報告対象外だった、または自分がEOS未接続)
@rpc("authority", "call_local", "reliable")
func _apply_rating_correction(entries: Dictionary) -> void:
	var my_puid := EosManager.product_user_id
	if my_puid.is_empty() or not entries.has(my_puid):
		return
	var e: Dictionary = entries[my_puid]
	RankingManager.apply_server_rating_correction(int(e.get("rating_after", ProfileManager.rating)))
