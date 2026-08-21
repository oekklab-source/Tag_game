extends Node

## 2ピアをつないで「準備中の役割選択」を実際に確かめる。
##
##   ホスト:     godot --headless --path . res://tests/net_roles.tscn -- host
##   クライアント: godot --headless --path . res://tests/net_roles.tscn -- client 127.0.0.1
##
## 見るところ:
##   1. 2人が離れた位置に湧く（重なると押し合えず楔状に固まる）
##   2. クライアントが自分で逃走者に立候補できる
##   3. ホストが立候補すると枠を奪う（同時に2人が逃走者にならない）
##   4. ホストの順送りで誰にでも付け替えられ、一巡すると未定に戻る
##   5. 指名した人が実際に逃走者になってラウンドが始まる
##   6. ラウンド終了後は WAITING で**止まる**（自動で次が始まらない）
##
## 進行はホスト・クライアントとも「接続確立からの経過秒」で揃える。
## 判定に使う wanted_runner / runner_id は両側で同じ値になるはずなので、
## 双方が同じ時刻に同じ検査をして、片方だけずれていれば FAIL になる。

var _is_host := false
var _fails := 0
var _client_id := -1


func _ready() -> void:
	_is_host = NetworkManager.mode != NetworkManager.Mode.CLIENT
	await get_tree().process_frame
	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world

	if not await _wait_for_peer():
		print("FAIL: 相手がつながらなかった")
		get_tree().quit()
		return
	_client_id = multiplayer.get_peers()[0] if _is_host else multiplayer.get_unique_id()
	print("=== %s (peer %d / 相手 %d) ===" % [
		"HOST" if _is_host else "CLIENT", multiplayer.get_unique_id(), _client_id])

	await _wait(1.0)
	_check_spawn_gap(world)

	# 1) クライアントが自分で立候補する
	if not _is_host:
		GameManager.toggle_my_role()
	await _settle()
	_eq("クライアントの立候補", GameManager.wanted_runner, _client_id)
	await _gap()

	# 2) ホストが立候補して枠を奪う
	if _is_host:
		GameManager.toggle_my_role()
	await _settle()
	_eq("ホストが枠を奪う", GameManager.wanted_runner, 1)
	await _gap()

	# 3) 順送り: ホスト(1) -> クライアント -> 未定(-1) -> ホスト(1)
	if _is_host:
		GameManager.cycle_wanted_runner()
	await _settle()
	_eq("順送り1回目（相手を指名）", GameManager.wanted_runner, _client_id)
	await _gap()

	if _is_host:
		GameManager.cycle_wanted_runner()
	await _settle()
	_eq("順送り2回目（未定に戻る）", GameManager.wanted_runner, -1)
	await _gap()

	if _is_host:
		GameManager.cycle_wanted_runner()
		GameManager.cycle_wanted_runner()
	await _settle()
	_eq("順送り一巡（再び相手を指名）", GameManager.wanted_runner, _client_id)
	await _gap()

	# 4) 指名した人が実際に逃走者になる
	if _is_host:
		GameManager.request_start_round()
	await _settle()
	_eq("ラウンド開始後の逃走者", GameManager.runner_id, _client_id)
	_eq("状態", GameManager.state, GameManager.State.PLAYING)
	if not _is_host:
		_check_runner_spawn()
	await _gap()

	# 5) ラウンドが終わったら WAITING で止まること
	if _is_host:
		GameManager._end_round.rpc(false, GameManager.EndReason.TAGGED)
	await _wait(GameManager.RESULT_TIME + 3.0)
	_eq("リザルト後の状態（WAITING で止まる）",
		GameManager.state, GameManager.State.WAITING)
	_eq("立候補は持ち越される", GameManager.wanted_runner, _client_id)

	print("=== %s の結果: %s ===" % ["HOST" if _is_host else "CLIENT",
		"ALL OK" if _fails == 0 else "%d 件 FAIL" % _fails])
	# どちらかが先に落ちると、残った側は「相手が抜けた」状態を観測してしまう
	# （指名されていた人が抜ければ立候補は解除されるのが正しい挙動）。
	# 判定が全部終わるまでは両者とも残る
	await _wait(2.0 if _is_host else 5.0)
	get_tree().quit()


func _wait_for_peer() -> bool:
	var waited := 0.0
	while multiplayer.get_peers().is_empty() and waited < 25.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	return not multiplayer.get_peers().is_empty()


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


## ホストの操作が全ピアへ行き渡るのを待つ
func _settle() -> void:
	await _wait(1.2)


## 検査から次の操作までの間。これが無いと、ホストが自分の操作直後に読むのに対し
## クライアントは「次の操作が飛んでくる瞬間」に読むことになり1手ずれる
func _gap() -> void:
	await _wait(1.2)


## 湧き位置が重なっていないこと。重なったまま出ると CharacterBody3D 同士は
## 押し合えず、楔状に固まるか相手の頭に乗って空中で静止する
func _check_spawn_gap(world: Node) -> void:
	var bodies := world.get_node("Players").get_children()
	if bodies.size() < 2:
		_report("湧き位置の間隔", false, "プレイヤーが2体そろっていない")
		return
	var d: Vector3 = bodies[0].global_position - bodies[1].global_position
	var gap := Vector2(d.x, d.z).length()
	_report("湧き位置の間隔 %.2f m" % gap, gap >= world.SPAWN_MIN_GAP, "重なって湧いた")


## 逃走者は中央ゾーンに置かれる（地面の高さが表と食い違うと宙に浮く）
func _check_runner_spawn() -> void:
	var me := GameManager.get_runner() as Node3D
	if me == null:
		_report("逃走者のスポーン", false, "自分のプレイヤーが見つからない")
		return
	var d: Vector3 = me.global_position - WorldData.zone_center(GameManager.RUNNER_SPAWN_ZONE)
	var gap := Vector2(d.x, d.z).length()
	_report("逃走者のスポーン 中央から %.2f m" % gap, gap < 3.0, "中央ゾーンに出ていない")


func _eq(what: String, got: int, want: int) -> void:
	_report("%s = %d" % [what, got], got == want, "期待値 %d" % want)


func _report(what: String, ok: bool, why: String) -> void:
	if not ok:
		_fails += 1
	print("  %s  %s" % [what, "OK" if ok else "FAIL（%s）" % why])
