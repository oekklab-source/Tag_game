extends Node

const CPU_NAV_ASSIST := preload("res://scenes/cpu_nav_assist.gd")

## デバッグ用ソロ: 人間が Hunter、CPU が Runner になることを確認する。

var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world
	await _wait(1.0)

	GameManager.set_debug_cpu_runner(true)
	await _settle()
	_report("デバッグモードON", GameManager.debug_cpu_runner, "切替が反映されていない")

	GameManager.request_start_round()
	await _settle()
	_report("状態がPLAYING", GameManager.state == GameManager.State.PLAYING, "ラウンドが始まっていない")
	_report("CPUが逃走者", GameManager.runner_id == GameManager.CPU_RUNNER_ID, "runner_id が CPU 用IDではない")
	_report("ヘッドスタートなし", GameManager.head_start_left == 0.0, "head_start_left が 0 ではない")
	var runner := GameManager.get_runner() as Node3D
	_report("CPU逃走者が存在", runner != null, "CPU逃走者が見つからない")
	var me := GameManager._find_player(multiplayer.get_unique_id())
	_report("自分は鬼", me != null and me != runner, "自分が逃走者扱いになっている")
	_report("1対1の鬼スタミナ", GameManager.hunter_stamina_max_for(1) == 150.0, "1対1で150になっていない")
	_report("1対2の鬼スタミナ", GameManager.hunter_stamina_max_for(2) == 120.0, "1対2で120になっていない")
	_report("1対3以上の鬼スタミナ", GameManager.hunter_stamina_max_for(3) == 100.0, "1対3以上で100になっていない")
	_report("CPU逃走者時の鬼スタミナ", me != null and me.stamina_max() == 150.0, "デバッグ時の鬼が150になっていない")

	await _wait(5.0)
	runner = GameManager.get_runner() as Node3D
	var zone := WorldData.zone_index(runner.global_position) if runner else -1
	_report("初動で雲土管に入らない", runner != null and zone != 0 and runner.global_position.y < 5.0,
		"雲の展望台へワープした、または高所に残っている")

	# ここから先は近道ギミック（滑り台・ジャンプ台・ダッシュパネル・バンパー）を
	# 通り抜けられるかだけを見る。CPU 逃走者は鬼の位置と GameManager.spotted で
	# 行き先を選び直すので、鬼が近く／見えているとテストが指定した _goal が
	# その場で捨てられてしまう。人間の鬼を退場させて ROAM 固定にしてから測る
	if me:
		me.remove_from_group("players")
		me.queue_free()
		me = null
		await _settle()

	if runner:
		var slide_pts := CPU_NAV_ASSIST._slide_path(WorldData.SLIDES[1])
		runner.teleport(slide_pts[0] + Vector3(0, 1.0, 0))
		_force_goal(runner, WorldData.zone_center(1))
		var before := runner.global_position
		for i in range(int(ceil(3.0 * Engine.physics_ticks_per_second))):
			await get_tree().physics_frame
			if is_instance_valid(runner):
				_force_goal(runner, WorldData.zone_center(1))
		var moved := Vector2(runner.global_position.x - before.x, runner.global_position.z - before.z).length()
		_report("滑り台入口で止まらない", moved > 4.0 and runner.global_position.y < before.y,
			"滑り台入口から十分に進んでいない")

		var boost_goal := WorldData.zone_center(5)
		runner.teleport(WorldData.zone_point(2, 0.0, 20.0) + Vector3(0.0, 1.0, 0.0))
		_force_goal(runner, boost_goal)
		var min_boost_dist := await _track_min_xz_dist(runner, boost_goal, 9.0)
		_report("ブロック広場からブーストサーキットへ抜ける", min_boost_dist < 10.0,
			"坂道出口付近で止まり、ブーストサーキット中心へ近づけていない")

		var spring_pad := WorldData.zone_point(5, 0.0, 19.0)
		runner.teleport(spring_pad + Vector3(0.0, 1.0, -7.0))
		_force_goal(runner, WorldData.zone_center(8))
		var max_y := await _track_max_y(runner, WorldData.zone_center(8), 4.0)
		_report("ブーストサーキットでジャンプ台を使う",
			max_y > WorldData.ZONE_GROUND[5] + 5.0,
			"そらの階段へ向かうジャンプ台で十分に上昇していない")

		runner.teleport(WorldData.zone_center(8) + Vector3(0.0, 1.0, 0.0))
		_force_goal(runner, WorldData.zone_center(7))
		var min_lift_dist := await _track_min_xz_dist(runner, WorldData.zone_center(7), 10.0)
		var dropped_to_lift := runner.global_position.y < WorldData.ZONE_GROUND[8] - 2.0
		_report("そらの階段からリフト港へ抜ける", dropped_to_lift and min_lift_dist < 15.0,
			"バンパー付近で引っかかり、リフト港側へ降りられていない")

	print("=== debug_cpu_runner の結果: %s ===" % ["ALL OK" if _fails == 0 else "%d 件 FAIL" % _fails])
	get_tree().quit(_fails)


func _settle() -> void:
	await _wait(0.5)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


## 逃走 AI は 0.4 秒ごとに行き先を選び直すので、放っておくとテストが指定した
## _goal はすぐ捨てられる。ここで見たいのは「指定した場所へ辿り着けるか」
## （近道ギミックを通れるか）なので、計測の間だけ選び直しを止めて釘付けにする
func _force_goal(body: Node3D, target: Vector3) -> void:
	body._goal = target
	body._goal_timer = 999.0
	body._repick_timer = 999.0
	body._progress_timer = 999.0


func _track_max_y(body: Node3D, target: Vector3, sec: float) -> float:
	var frames := int(ceil(sec * Engine.physics_ticks_per_second))
	var max_y := body.global_position.y
	for i in range(frames):
		await get_tree().physics_frame
		if is_instance_valid(body):
			_force_goal(body, target)
			max_y = maxf(max_y, body.global_position.y)
	return max_y


func _track_min_xz_dist(body: Node3D, target: Vector3, sec: float) -> float:
	var frames := int(ceil(sec * Engine.physics_ticks_per_second))
	var min_dist := _xz_dist(body.global_position, target)
	for i in range(frames):
		await get_tree().physics_frame
		if is_instance_valid(body):
			_force_goal(body, target)
			min_dist = minf(min_dist, _xz_dist(body.global_position, target))
	return min_dist


func _xz_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _report(what: String, ok: bool, why: String) -> void:
	if not ok:
		_fails += 1
	print("  %s  %s" % [what, "OK" if ok else "FAIL（%s）" % why])
