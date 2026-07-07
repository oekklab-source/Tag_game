extends Node

## ゲーム進行を管理する Autoload。
## 役割抽選・鬼の速度補正・タイマー・タッチ判定はすべてホスト側で実行し、
## 結果を RPC で全ピアへ配信する。

enum State { WAITING, PLAYING, RESULT }

const TAG_DISTANCE := 1.5
const ROUND_TIME := 180.0
const RESULT_TIME := 5.0
const SOLO_CPU_COUNT := 1
const RUNNER_SPAWN := Vector3(0, 1, 0)
const HUNTER_SPAWN_RADIUS := 12.0

var state: int = State.WAITING
var runner_id := -1
var hunter_mult := 1.0
var time_left := ROUND_TIME
var result_text := ""


func reset() -> void:
	state = State.WAITING
	runner_id = -1
	hunter_mult = 1.0
	time_left = ROUND_TIME
	result_text = ""


## 鬼の人数に応じた速度補正（1人=100% / 2人=90% / 3人以上=80%）
func hunter_mult_for(hunter_count: int) -> float:
	if hunter_count >= 3:
		return 0.8
	if hunter_count == 2:
		return 0.9
	return 1.0


func get_speed_mult(peer_id: int) -> float:
	if state == State.PLAYING and peer_id != runner_id:
		return hunter_mult
	return 1.0


func local_is_hunter() -> bool:
	return state == State.PLAYING and multiplayer.get_unique_id() != runner_id


func get_runner() -> Node:
	return _find_player(runner_id)


func _find_player(peer_id: int) -> Node:
	for p in get_tree().get_nodes_in_group("players"):
		if p.name == str(peer_id):
			return p
	return null


## --- ホスト側ロジック -------------------------------------------------

func request_start_round() -> void:
	if not multiplayer.is_server() or state == State.PLAYING:
		return
	var players := get_tree().get_nodes_in_group("players")
	if players.is_empty():
		return
	_clear_cpu_hunters()
	var ids: Array[int] = []
	for p in players:
		ids.append(String(p.name).to_int())
	# 1人だけならソロモード: 自分が Runner になり CPU 鬼が追う
	var solo := ids.size() == 1
	var new_runner: int
	var mult := 1.0
	if solo:
		new_runner = ids[0]
	else:
		new_runner = ids.pick_random()
		mult = hunter_mult_for(ids.size() - 1)
	# スポーン位置: Runner は中央、Hunter は半径12mの円周上に等間隔
	var spawns := {}
	spawns[new_runner] = RUNNER_SPAWN
	var hunter_count := maxi(ids.size() - 1, 1)
	var i := 0
	for id in ids:
		if id == new_runner:
			continue
		var angle := TAU * i / hunter_count
		spawns[id] = Vector3(cos(angle), 0, sin(angle)) * HUNTER_SPAWN_RADIUS + Vector3.UP
		i += 1
	_start_round.rpc(new_runner, mult, spawns)
	if solo:
		var world := get_tree().current_scene
		for n in SOLO_CPU_COUNT:
			var angle := TAU * n / SOLO_CPU_COUNT
			var pos := Vector3(cos(angle), 0, sin(angle)) * HUNTER_SPAWN_RADIUS + Vector3.UP
			if world.has_method("spawn_cpu_hunter"):
				world.spawn_cpu_hunter(pos)


func _clear_cpu_hunters() -> void:
	for cpu in get_tree().get_nodes_in_group("cpu_hunters"):
		cpu.queue_free()


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server() or state != State.PLAYING:
		return
	var prev_sec := ceili(time_left)
	time_left -= delta
	if time_left <= 0.0:
		_end_round.rpc("RUNNER WINS!  (survived 3 minutes)")
		return
	if ceili(time_left) != prev_sec:
		_sync_time.rpc(time_left)
	var runner := get_runner()
	if runner == null:
		return
	for p in get_tree().get_nodes_in_group("players"):
		if p == runner:
			continue
		if p.global_position.distance_to(runner.global_position) <= TAG_DISTANCE:
			_end_round.rpc("HUNTERS WIN!  (runner tagged)")
			return
	for cpu in get_tree().get_nodes_in_group("cpu_hunters"):
		if cpu.global_position.distance_to(runner.global_position) <= TAG_DISTANCE:
			_end_round.rpc("HUNTERS WIN!  (runner tagged)")
			return


func _process(delta: float) -> void:
	# クライアント側はローカルで滑らかに減算し、毎秒の同期で補正する
	if not multiplayer.is_server() and state == State.PLAYING:
		time_left = maxf(time_left - delta, 0.0)


## 途中参加者へ現在の状態を送る（ホストのみ呼ぶ）
func sync_to_peer(peer_id: int) -> void:
	if multiplayer.is_server():
		_sync_state.rpc_id(peer_id, state, runner_id, hunter_mult, time_left, result_text)


func on_player_left(peer_id: int) -> void:
	if multiplayer.is_server() and state == State.PLAYING and peer_id == runner_id:
		_end_round.rpc("Round ended (runner disconnected)")


func _schedule_next_round() -> void:
	await get_tree().create_timer(RESULT_TIME).timeout
	if state != State.RESULT:
		return
	_back_to_waiting.rpc()
	request_start_round()


## --- RPC（ホスト -> 全ピア） -------------------------------------------

@rpc("authority", "call_local", "reliable")
func _start_round(new_runner: int, mult: float, spawns: Dictionary) -> void:
	runner_id = new_runner
	hunter_mult = mult
	time_left = ROUND_TIME
	result_text = ""
	state = State.PLAYING
	# 位置の権威は各クライアントにあるため、自分のプレイヤーは自分で移動する
	var my_id := multiplayer.get_unique_id()
	if spawns.has(my_id):
		var me := _find_player(my_id)
		if me:
			me.teleport(spawns[my_id])


@rpc("authority", "call_local", "unreliable")
func _sync_time(t: float) -> void:
	time_left = t


@rpc("authority", "call_local", "reliable")
func _end_round(text: String) -> void:
	state = State.RESULT
	result_text = text
	if multiplayer.is_server():
		_schedule_next_round()


@rpc("authority", "call_local", "reliable")
func _back_to_waiting() -> void:
	state = State.WAITING
	runner_id = -1
	if multiplayer.is_server():
		_clear_cpu_hunters()


@rpc("authority", "call_remote", "reliable")
func _sync_state(s: int, r_id: int, mult: float, t: float, res: String) -> void:
	state = s
	runner_id = r_id
	hunter_mult = mult
	time_left = t
	result_text = res
