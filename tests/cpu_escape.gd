extends Node

## CPU 逃走者の判断（温存 / ダッシュ / 挟み回避 / 角回避 / アイテム / 逃げ切り）を確認する。
##
## cpu_strength.tscn が鬼の「1体としての強さ」を測るのと対になるテスト。
## 逃走側の強さは脚ではなく判断から出ているので、見るのは速度ではなく
## 「どこを行き先に選んだか」「いつスタミナを吐いたか」。

## 中央から北・東・南の3方向に鬼を湧かせて追わせる。脚は同一なので、
## 囲まれた状態から凌げるなら「行き先の選び方」が効いているということ
const SURVIVE_TIME := 25.0

var _fails := 0
var _runner: Node3D = null
var _me: Node3D = null
var _world: Node = null


func _ready() -> void:
	await get_tree().process_frame
	_world = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(_world)
	get_tree().current_scene = _world
	await _wait(1.0)

	GameManager.set_debug_cpu_runner(true)
	await _settle()
	GameManager.request_start_round()
	await _settle()
	_runner = GameManager.get_runner() as Node3D
	_me = GameManager._find_player(multiplayer.get_unique_id()) as Node3D
	if _runner == null or _me == null:
		_report("前提", false, "CPU逃走者か人間の鬼が見つからない")
		_finish()
		return

	await _test_conserve()
	await _test_dash()
	await _test_pincer()
	await _test_corner()
	await _test_banana()
	await _test_survive()

	_finish()


## --- 温存 ---------------------------------------------------------------
## 鬼が遠い（ROAM）うちは吐かない。ここで浪費すると、詰められた時に
## 巡航速度へ落ちて捕まる
func _test_conserve() -> void:
	_runner.teleport(WorldData.zone_center(0) + Vector3(0, 1, 0))
	var far := WorldData.zone_center(8) + Vector3(0, 1, 0)
	var dashed := false
	for i in _frames(3.0):
		await get_tree().physics_frame
		if not _alive():
			break
		_me.teleport(far)
		if _runner.is_dashing:
			dashed = true
	_report("鬼が遠いうちは温存する", not dashed and is_equal_approx(_runner.stamina, _runner.STAMINA_MAX),
		"鬼が100m先にいるのに加速している（スタミナ %.1f）" % _runner.stamina)


## --- ダッシュ -----------------------------------------------------------
## 「近い」だけでは吐かず、「近くて詰められている」時に吐く
func _test_dash() -> void:
	_runner.teleport(WorldData.zone_center(4) + Vector3(0, 1, 0))
	await _settle()
	var dashed := false
	var frames := _frames(5.0)
	for i in frames:
		await get_tree().physics_frame
		if not _alive():
			break
		# 30m から 2m/s で詰める。距離だけでなく「縮んでいること」が条件
		_pin_hunter(maxf(20.0, 30.0 - 2.0 * float(i) / Engine.physics_ticks_per_second))
		if _runner.is_dashing:
			dashed = true
	_report("詰めてくる鬼にはダッシュで応じる", dashed,
		"30m から詰められても is_dashing にならない")
	_report("ダッシュでスタミナが減る", _runner.stamina < _runner.STAMINA_MAX,
		"スタミナが %.1f のまま" % _runner.stamina)

	# 枯渇したら巡航速度へ戻る（人間の逃走者と同じ経済）
	_runner.stamina = 0.0
	_runner.exhausted = true
	var still := false
	for i in _frames(0.5):
		await get_tree().physics_frame
		if not _alive():
			break
		_pin_hunter(15.0)
		if _runner.is_dashing:
			still = true
	_report("枯渇したらダッシュできない", not still, "息切れ中でも加速している")
	_runner.stamina = _runner.STAMINA_MAX
	_runner.exhausted = false


## --- 挟み回避 -----------------------------------------------------------
## 西の端で南北から挟まれたら、その間を突っ切らず東（開いている側）へ抜ける。
## 「いちばん遠い点」を素直に選ぶと、鬼の向こう側のゾーンを掴んで自分から突っ込む
func _test_pincer() -> void:
	var a := _spawn_pinned_hunter(WorldData.zone_point(3, 0.0, -20.0))
	var b := _spawn_pinned_hunter(WorldData.zone_point(3, 0.0, 20.0))
	_runner.teleport(WorldData.zone_center(3) + Vector3(0, 1, 0))
	var goal := await _hold(2.0, [a, b], [WorldData.zone_point(3, 0.0, -20.0),
		WorldData.zone_point(3, 0.0, 20.0)])
	_report("南北から挟まれたら開いている東へ抜ける", goal.x > _runner.global_position.x + 5.0,
		"行き先 (%.0f, %.0f) が挟まれている側のまま" % [goal.x, goal.z])
	_free_hunters([a, b])


## --- 角回避 -------------------------------------------------------------
## 外周の角は「鬼から最も遠い場所」なので、素朴なスコアだと必ずそこへ収束して詰む。
## OPEN_WEIGHT（逃げ道の広さ）が効いているかの回帰
func _test_corner() -> void:
	var corner := WorldData.zone_point(6, -20.0, 20.0)
	var hunter_at := WorldData.zone_point(6, 8.0, -8.0)
	var a := _spawn_pinned_hunter(hunter_at)
	_runner.teleport(corner + Vector3(0, 1, 0))
	var before := _open(_runner.global_position)
	var goal := await _hold(2.0, [a], [hunter_at])
	_report("角へ追い込まれても内側へ抜ける", _open(goal) > before + 5.0,
		"角(逃げ道 %.0fm)から行き先(逃げ道 %.0fm)へ、外へ出ようとしていない" % [before, _open(goal)])
	_free_hunters([a])


## --- アイテム -----------------------------------------------------------
## 置き物は自分の背後に出る＝追ってくる鬼の進路。背後に付かれた時だけ置く
func _test_banana() -> void:
	var items := _world.get_node_or_null("Items")
	if items == null:
		_report("背後の鬼にバナナを置く", false, "Items ノードが無い")
		return
	_runner.teleport(WorldData.zone_center(4) + Vector3(0, 1, 0))
	await _settle()
	var before := items.get_child_count()
	_runner.give_item(Player.Item.BANANA)
	_runner.item_lock = 0.0
	for i in _frames(2.0):
		await get_tree().physics_frame
		if not _alive():
			break
		var back := _runner.global_transform.basis.z
		_me.teleport(_runner.global_position
			+ Vector3(back.x, 0.0, back.z).normalized() * 8.0)
		if _runner.item == Player.Item.NONE:
			break
	_report("背後の鬼にバナナを置く", items.get_child_count() > before,
		"背後8mに鬼がいてもバナナを置かない")


## --- 逃げ切り -----------------------------------------------------------
## 鬼3体（連携あり）に本気で追わせて、制限時間の一部を凌げるか。
## 脚は同一なので、捕まらないなら判断が効いているということ
func _test_survive() -> void:
	if GameManager.state != GameManager.State.PLAYING:
		_report("鬼3体から逃げ切る", false, "その前のテストで捕まっている")
		return
	_me.teleport(WorldData.zone_point(0, -20.0, -20.0))  # 人間は隅で静観させる
	_runner.teleport(WorldData.zone_center(4) + Vector3(0, 1, 0))
	# 前のテストで置いたバナナが中央に残っている。自分で踏んで転ぶと
	# 「逃げ切れるか」ではなく「事故ったか」を測ることになるので片付ける
	var items := _world.get_node_or_null("Items")
	if items:
		for n in items.get_children():
			items.remove_child(n)
			n.queue_free()
	GameManager.squad.begin_round()  # 鬼の担当と目撃予測もまっさらから始める
	await _settle()
	for z in [1, 5, 7]:
		_world.spawn_cpu_hunter(WorldData.zone_center(z) + Vector3(0, 3, 0))
	var held := 0.0
	while held < SURVIVE_TIME:
		await get_tree().create_timer(0.25).timeout
		if GameManager.state != GameManager.State.PLAYING:
			break
		held += 0.25
	_report("鬼3体から%.0f秒逃げ切る" % SURVIVE_TIME, held >= SURVIVE_TIME,
		"%.1f秒で捕まった" % held)


## --- 補助 ---------------------------------------------------------------

## 外周壁までの余裕 = 逃げ道の広さ。cpu_runner.gd の _escape_score と同じ式
func _open(p: Vector3) -> float:
	return minf(WorldData.WORLD_HALF - absf(p.x), WorldData.WORLD_HALF - absf(p.z))


## 鬼たちを指定位置に釘付けにしたまま待ち、逃走者が選んだ行き先を返す
func _hold(sec: float, hunters: Array, spots: Array) -> Vector3:
	for i in _frames(sec):
		await get_tree().physics_frame
		if not _alive():
			break
		for k in hunters.size():
			if is_instance_valid(hunters[k]):
				hunters[k].teleport(spots[k])
	return _runner.get_ai_goal() if _alive() else Vector3.ZERO


## 人間の鬼を逃走者から dist だけ離れた同じ方角に置き直す（詰め寄る動きを作る）
func _pin_hunter(dist: float) -> void:
	_me.teleport(_runner.global_position + Vector3(1, 0, 0) * dist)


## グループの取得順は保証されないので、増えた分を差分で拾う
func _spawn_pinned_hunter(pos: Vector3) -> Node3D:
	var before := {}
	for h in get_tree().get_nodes_in_group("cpu_hunters"):
		before[h.get_instance_id()] = true
	_world.spawn_cpu_hunter(pos + Vector3(0, 1, 0))
	for h in get_tree().get_nodes_in_group("cpu_hunters"):
		if not before.has(h.get_instance_id()):
			return h as Node3D
	return null


func _free_hunters(list: Array) -> void:
	for h in list:
		if is_instance_valid(h):
			h.remove_from_group("cpu_hunters")
			h.queue_free()


func _alive() -> bool:
	return is_instance_valid(_runner) and is_instance_valid(_me)


func _frames(sec: float) -> int:
	return int(ceil(sec * Engine.physics_ticks_per_second))


func _finish() -> void:
	print("=== cpu_escape の結果: %s ===" % ["ALL OK" if _fails == 0 else "%d 件 FAIL" % _fails])
	get_tree().quit(_fails)


func _settle() -> void:
	await _wait(0.5)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _report(what: String, ok: bool, why: String) -> void:
	if not ok:
		_fails += 1
	print("  %s  %s" % [what, "OK" if ok else "FAIL（%s）" % why])
