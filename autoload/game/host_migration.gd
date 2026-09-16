extends Node

## GameManager の子ノード。切断時のCPU代行判定とそれに伴うレーティング・
## ペナルティ報告を持つ(EOSロビー自体のホスト引き継ぎはEosManager/NetworkManager側)。
## (v6でのGameManager分割時に切り出した。詳細はgame_manager.gdのバージョン履歴参照)。

## ⑦対戦中に切断した逃げる役をレーティング戦でだけCPU代行に切り替えるかどうか。
## world.gd._on_peer_disconnected()がノードを実際に破棄する前に判定するために
## GameManager経由で公開している
func should_cpu_takeover_runner(peer_id: int) -> bool:
	return multiplayer.is_server() and GameManager.state == GameManager.State.PLAYING \
		and peer_id == GameManager.runner_id and GameManager.round_is_ranked


## ⑦⑧切断した本人はその場で反映できないため、サーバー(friend-api)に敗北分の
## レート変動を記録し、本人が次回ログインした際に自分で適用する
## (RankingManager._on_eos_initialized()参照)。CPU AIは別途開発中のため、
## 「最強CPU」は既存のcpu_runner.gdをそのまま流用する暫定実装。
## was_runner=falseの場合(鬼切断)はcalculate_rating_delta内のis_runner==is_winner
## 正規化により survival が MAX_TIME 扱いになり、「逃げ切られた」前提の最大ペナルティになる
func _report_participant_disconnect_penalty(peer_id: int, was_runner: bool) -> void:
	var puid := String(GameManager.peer_profiles.get(peer_id, {}).get("puid", ""))
	if puid.is_empty():
		return
	var self_rating := int(GameManager.peer_profiles.get(peer_id, {}).get("rating", 1500))
	var survival := GameManager.ROUND_TIME - GameManager.time_left
	# 固定値1500ではなく実際の相手陣営レートを使う(apply_match_end()と同じ修正)。
	# ホストはこの時点でまだpeer_profilesが生きているため直接算出できる
	var opponent_rating := RankingManager.opponent_avg_rating(was_runner)
	var delta := RankingManager.calculate_rating_delta(
		was_runner, false, survival, GameManager.round_hunter_count, false, self_rating, opponent_rating)
	FriendManager.report_disconnect_penalty(puid, delta)


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
	GameManager.runner_id = GameManager.CPU_RUNNER_ID
