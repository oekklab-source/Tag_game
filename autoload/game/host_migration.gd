extends Node

## GameManager の子ノード。切断時のCPU代行判定とそれに伴うレーティング・
## ペナルティ報告を持つ(EOSロビー自体のホスト引き継ぎはEosManager/NetworkManager側)。
## (v6でのGameManager分割時に切り出した。詳細はgame_manager.gdのバージョン履歴参照)。
##
## v13で「ホスト引き継ぎ後に進行中のラウンドを再開する」役割も持つようになった
## (snapshot_for_resume / begin_resume / _resume_round)。切断検知時に各生存者が取った
## スナップショットを、新ホストが全員の再接続(report_profileのpuid)を待って全ピアへ配り直す。
## peer_idは再接続で変わるため、役割はpuidで持ち、再開時に新しいpeer_idへ引き直す。

## rating_report.gdと同じ理由(headless単体実行でclass_nameのグローバル登録が
## 更新されていないケースへの対処)でpreloadを使う
const _RatingBackendClientScript := preload("res://autoload/rating_backend_client.gd")

## ⑦対戦中に切断した逃げる役をレーティング戦でだけCPU代行に切り替えるかどうか。
## world.gd._on_peer_disconnected()がノードを実際に破棄する前に判定するために
## GameManager経由で公開している
func should_cpu_takeover_runner(peer_id: int) -> bool:
	return multiplayer.is_server() and GameManager.state == GameManager.State.PLAYING \
		and peer_id == GameManager.runner_id and GameManager.round_is_ranked


## ⑦⑧切断した本人はその場で反映できないため、サーバー(rating-api)に敗北分の
## レート変動を直接・権威的に反映させる(C-03 R-5。旧friend-apiの「本人が次回ログイン時に
## 自分で適用する預かり金」方式は廃止した。対象者本人への通知は、次回ログイン時の
## RankingManager._reconcile_server_rating()が/ratingを叩けば自動的に反映される)。
## CPU AIは別途開発中のため、「最強CPU」は既存のcpu_runner.gdをそのまま流用する暫定実装。
## was_runner=falseの場合(鬼切断)はcalculate_rating_delta内のis_runner==is_winner
## 正規化により survival が MAX_TIME 扱いになり、「逃げ切られた」前提の最大ペナルティになる
func _report_participant_disconnect_penalty(peer_id: int, was_runner: bool) -> void:
	var puid := String(GameManager.peer_profiles.get(peer_id, {}).get("puid", ""))
	if puid.is_empty():
		return
	# C-03 R-5: rating_report.gd.report_match_result()と同じ位置(ネットワーク呼び出し
	# 直前)にゲートを置く
	if not (BackendConfig.USE_LIVE_RATING_BACKEND and EosManager.is_eos_available):
		return
	var self_rating := int(GameManager.peer_profiles.get(peer_id, {}).get("rating", 1500))
	var survival := GameManager.ROUND_TIME - GameManager.time_left
	# 固定値1500ではなく実際の相手陣営レートを使う(apply_match_end()と同じ修正)。
	# ホストはこの時点でまだpeer_profilesが生きているため直接算出できる
	var opponent_rating := RankingManager.opponent_avg_rating(was_runner)
	var delta := RankingManager.calculate_rating_delta(
		was_runner, false, survival, GameManager.round_hunter_count, false, self_rating, opponent_rating)
	_RatingBackendClientScript.report_disconnect_penalty(
		self, puid, was_runner, GameManager.round_hunter_count, self_rating, delta,
		survival, opponent_rating)


## ⑨ホスト(peer_id==1)自身がPLAYING中に切断した場合の敗北精算に使うスナップショットを取る。
## NetworkManagerがserver_disconnected検知直後、まだローカルのレプリケート済み状態
## (peer_profiles/runner_id/time_left等)が生きている間に呼ぶ。呼び出し元は死んだ
## ホストではなく生存クライアント自身なので、on_player_left系と違いis_server()は問わない
func snapshot_for_host_disconnect_penalty() -> Dictionary:
	const HOST_PEER_ID := 1
	if GameManager.state != GameManager.State.PLAYING or not GameManager.round_is_ranked:
		return {}
	var puid := String(GameManager.peer_profiles.get(HOST_PEER_ID, {}).get("puid", ""))
	if puid.is_empty():
		return {}
	var was_runner := GameManager.runner_id == HOST_PEER_ID
	return {
		"puid": puid,
		"was_runner": was_runner,
		"self_rating": int(GameManager.peer_profiles.get(HOST_PEER_ID, {}).get("rating", 1500)),
		# GameManager.reset()でpeer_profilesが消える前に、相手陣営の実レートもここで確保しておく
		"opponent_avg_rating": RankingManager.opponent_avg_rating(was_runner),
		"survival": GameManager.ROUND_TIME - GameManager.time_left,
		"hunter_count": GameManager.round_hunter_count,
	}


## ⑦レーティング戦で逃げる役が切断した際、既存の(暫定)cpu_runner.gdへ操作を
## 引き継がせる。CPU_RUNNER_IDは元々ソロ練習のデバッグモード用に使われている
## 「鬼が人間、逃げる役がCPU」のセンチネル値で、get_runner()がそのまま流用できる
@rpc("authority", "call_local", "reliable")
func _set_runner_cpu() -> void:
	# H-02: 呼び出し元(GameManager.on_player_left())がプロフィール消去より前にこのRPCを送るため、
	# 代入前ならまだ切断した本人の表示名をpeer_profilesから引ける
	var peer_name := String(GameManager.peer_profiles.get(GameManager.runner_id, {}).get("name", "?"))
	GameManager.runner_cpu_takeover.emit(peer_name)
	GameManager.runner_id = GameManager.CPU_RUNNER_ID


## --- ホスト引き継ぎ後のラウンド再開 -------------------------------------------

## 新ホストが生存者の再接続を待つ上限。これを過ぎたら、戻ってきた人だけで再開する
const RESUME_WAIT_SEC := 60.0

## ホスト専用。再開待ちの間はtrue。GameManager.request_start_round()がこれを見て、
## 再開前に新しいラウンドを始めてしまわないようにする
var resume_pending := false
var _resume_snap := {}
## 再開前に戻ってきてほしい人のpuid(新ホスト自身を除く)
var _resume_wait_puids: Array = []
## SceneTreeTimerは止められないため、世代が変わったタイマーは無視する(NetworkManager._migration_tokenと同じ方式)
var _resume_gen := 0


## server_disconnected検知直後(GameManager.reset()より前)に、各生存者が自分のローカルの
## レプリケート済み状態から取る。PLAYING以外は空 = 従来どおり準備中へ戻す
func snapshot_for_resume() -> Dictionary:
	if GameManager.state != GameManager.State.PLAYING:
		return {}
	var runner_id := GameManager.runner_id
	var runner_profile: Dictionary = GameManager.peer_profiles.get(runner_id, {})
	var runner := GameManager.get_runner()
	var survivor_puids: Array = []
	for p in get_tree().get_nodes_in_group("players"):
		var id := String(p.name).to_int()
		if id == 1:
			continue  # 旧ホストは戻らない
		var puid := String(GameManager.peer_profiles.get(id, {}).get("puid", ""))
		if not puid.is_empty():
			survivor_puids.append(puid)
	var cpu_hunters: Array = []
	for c in get_tree().get_nodes_in_group("cpu_hunters"):
		cpu_hunters.append(c.global_position)
	return {
		"time_left": GameManager.time_left,
		"head_start_left": GameManager.head_start_left,
		"hunter_mult": GameManager.hunter_mult,
		"hunter_count": GameManager.hunter_count,
		"round_hunter_count": GameManager.round_hunter_count,
		"round_is_ranked": GameManager.round_is_ranked,
		"spotted_zone": GameManager.spotted_zone,
		"intel_left": GameManager.intel_left,
		"world_time": GameManager.world_time,
		"runner_is_cpu": runner_id == GameManager.CPU_RUNNER_ID,
		"runner_puid": String(runner_profile.get("puid", "")),
		"runner_name": String(runner_profile.get("name", "?")),
		"runner_pos": runner.global_position if runner != null else Vector3.ZERO,
		"survivor_puids": survivor_puids,
		"cpu_hunters": cpu_hunters,
		"me": _my_state_for_resume(),
	}


## 自分のプレイヤーの状態。切断直後はmultiplayer.get_unique_id()が信用できない可能性があるので、
## 変わらないpuidでpeer_profilesを引くのを優先し、見つからなければunique_idで探す
func _my_state_for_resume() -> Dictionary:
	var my_id := -1
	var my_puid := EosManager.product_user_id
	if not my_puid.is_empty():
		for pid in GameManager.peer_profiles:
			if String(GameManager.peer_profiles[pid].get("puid", "")) == my_puid:
				my_id = int(pid)
				break
	var me: Node = GameManager._find_player(my_id) if my_id != -1 else null
	if me == null:
		me = GameManager._find_player(multiplayer.get_unique_id())
	if me == null:
		return {}
	# yawはsync_yawと同じrotation.y(ボディのヨー)。restore_after_migration()が同じ値を書き戻す
	return {"pos": me.global_position, "yaw": me.rotation.y, "stamina": me.stamina, "item": me.item}


## 再開時の逃走者。puid_to_peer は新ホストから見た puid -> 新しい peer_id。
## 元からCPUだった場合と、逃走者が戻らなかった場合(旧ホストが逃走者だった場合を含む)はCPU
static func resolve_resume_runner(snap: Dictionary, puid_to_peer: Dictionary) -> int:
	if bool(snap.get("runner_is_cpu", false)):
		return GameManager.CPU_RUNNER_ID
	var puid := String(snap.get("runner_puid", ""))
	if not puid.is_empty() and puid_to_peer.has(puid):
		return int(puid_to_peer[puid])
	return GameManager.CPU_RUNNER_ID


## ホストのみ。world起動後に呼ぶ。生存者の再接続が揃う(または RESUME_WAIT_SEC 経過する)まで待つ
func begin_resume(snap: Dictionary) -> void:
	if snap.is_empty():
		return
	_resume_snap = snap
	resume_pending = true
	_resume_gen += 1
	var my_puid := EosManager.product_user_id
	_resume_wait_puids = []
	for puid in snap.get("survivor_puids", []):
		if puid != my_puid:
			_resume_wait_puids.append(puid)
	if _resume_wait_puids.is_empty():
		_resume_now.call_deferred()
		return
	var gen := _resume_gen
	get_tree().create_timer(RESUME_WAIT_SEC).timeout.connect(
		func() -> void:
			if resume_pending and gen == _resume_gen:
				_resume_now()
	)


## ホストのみ。GameManager.report_profile()が peer_profiles を更新するたびに呼ばれる
func on_profile_reported() -> void:
	if not resume_pending:
		return
	var present := {}
	for pid in GameManager.peer_profiles:
		present[String(GameManager.peer_profiles[pid].get("puid", ""))] = true
	for puid in _resume_wait_puids:
		if not present.has(puid):
			return
	_resume_now()


## 接続してきた本人へ、再開待ちかどうかを伝える(待ちでなければ暗転を解いてよい)
func notify_peer(peer_id: int) -> void:
	_resume_pending.rpc_id(peer_id, resume_pending)


func cancel_resume() -> void:
	resume_pending = false
	_resume_snap = {}
	_resume_wait_puids = []
	_resume_gen += 1


func _resume_now() -> void:
	if not resume_pending:
		return
	resume_pending = false
	_resume_gen += 1
	var snap := _resume_snap
	_resume_snap = {}
	_resume_wait_puids = []
	var puid_to_peer := {}
	for pid in GameManager.peer_profiles:
		var puid := String(GameManager.peer_profiles[pid].get("puid", ""))
		if not puid.is_empty():
			puid_to_peer[puid] = int(pid)
	var new_runner := resolve_resume_runner(snap, puid_to_peer)
	var world := get_tree().current_scene
	if world != null:
		# 逃走者が戻らなかった場合は⑦の切断時代行と同じく、最後の位置にCPU逃走者を出す
		if new_runner == GameManager.CPU_RUNNER_ID and world.has_method("spawn_cpu_runner"):
			world.spawn_cpu_runner(snap.get("runner_pos", Vector3.ZERO))
		if world.has_method("spawn_cpu_hunter"):
			for pos in snap.get("cpu_hunters", []):
				world.spawn_cpu_hunter(pos)
	_resume_round.rpc(new_runner, float(snap.get("hunter_mult", 1.0)),
		int(snap.get("hunter_count", 1)), float(snap.get("time_left", GameManager.ROUND_TIME)),
		float(snap.get("head_start_left", 0.0)), bool(snap.get("round_is_ranked", false)),
		float(snap.get("world_time", 0.0)), int(snap.get("spotted_zone", -1)),
		float(snap.get("intel_left", 0.0)))


## ホスト -> 再接続してきた本人。falseなら再開は無いので、スナップショットを捨てて暗転を消す
@rpc("authority", "call_remote", "reliable")
func _resume_pending(pending: bool) -> void:
	if not pending:
		NetworkManager.finish_resume()


## ホスト -> 全ピア。_start_roundと違い、残り時間・ranked・world_time等を引き継いだまま
## PLAYINGへ入る(_sync_stateはround_is_rankedとworld_timeを運べないので流用しない)。
## 位置の権威は各クライアントにあるため、自分の位置・向き・スタミナ・アイテムは
## 各ピアが自分のスナップショットから戻す
@rpc("authority", "call_local", "reliable")
func _resume_round(new_runner: int, mult: float, hunters_n: int, t: float, head: float,
		is_ranked: bool, w_time: float, zone: int, intel: float) -> void:
	GameManager.runner_id = new_runner
	GameManager.hunter_mult = mult
	GameManager.hunter_count = hunters_n
	GameManager.round_hunter_count = hunters_n
	GameManager.time_left = t
	GameManager.head_start_left = head
	GameManager.tagger_peer_id = -1
	GameManager.round_is_ranked = is_ranked
	GameManager.world_time = w_time
	GameManager.squad.begin_round()
	GameManager._clear_intel()
	GameManager.spotted_zone = zone
	GameManager.intel_left = intel
	GameManager.state = GameManager.State.PLAYING
	GameManager.state_changed.emit(GameManager.state)
	var snap := NetworkManager.resume_snapshot()
	if new_runner == GameManager.CPU_RUNNER_ID and not bool(snap.get("runner_is_cpu", true)):
		GameManager.runner_cpu_takeover.emit(String(snap.get("runner_name", "?")))
	var me: Dictionary = snap.get("me", {})
	NetworkManager.finish_resume()
	if me.is_empty():
		return
	# place_playerと同じ理由: 自分のプレイヤーのスポーン通知より先にこのRPCが着くことがある
	var my_id := multiplayer.get_unique_id()
	var player := GameManager._find_player(my_id)
	var waited := 0
	while player == null and waited < 60:
		await get_tree().process_frame
		waited += 1
		player = GameManager._find_player(my_id)
	if player:
		player.restore_after_migration(me.get("pos", Vector3.ZERO), float(me.get("yaw", 0.0)),
			float(me.get("stamina", 0.0)), int(me.get("item", 0)))
