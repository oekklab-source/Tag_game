extends Node

## 鬼の定員（逃走者1 + 鬼3 = 4人）と連携（分担探索・挟み込み）を確認する。
##
## ソロで開始すると人間が逃走者になり、足りない鬼3体を CPU が埋める。
## この状態で「担当ゾーンが重複しないこと」「時間が経つと全体へ散ること」
## 「追跡役が常に1体だけで、残りが左右へ分かれること」を見る。

var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world
	await _wait(1.0)

	GameManager.request_start_round()
	await _settle()

	# get_nodes_in_group() は Array[Node] なので、Node3D へ入れ直して
	# global_position の型を通す
	var cpus: Array[Node3D] = []
	for n in get_tree().get_nodes_in_group("cpu_hunters"):
		cpus.append(n)
	_report("CPU鬼が3体", cpus.size() == GameManager.MAX_HUNTERS,
		"%d体しか湧いていない" % cpus.size())
	_report("鬼の人数が3", GameManager.hunter_count == GameManager.MAX_HUNTERS,
		"hunter_count が %d" % GameManager.hunter_count)
	_report("速度補正が3人ぶん", is_equal_approx(GameManager.hunter_mult, 0.95),
		"hunter_mult が %f（CPU鬼を数えていない）" % GameManager.hunter_mult)

	var spawn_zones := {}
	for c in cpus:
		spawn_zones[WorldData.zone_index(c.global_position)] = true
	_report("初期配置が散っている", spawn_zones.size() == cpus.size(),
		"同じゾーンに重なって湧いている")

	# --- 分担探索 -------------------------------------------------------
	# 逃走者（＝中央に立ったままの自分）が見つかると鬼は CHASE に入って
	# 巡回をやめる。探索の分担だけを測りたいので、逃走者を落下限界の下へ
	# 沈めて視認されない状態にしてから計測する
	var me := GameManager._find_player(multiplayer.get_unique_id()) as Node3D
	if me:
		me.teleport(Vector3(0.0, WorldData.FALL_LIMIT - 200.0, 0.0))
	# ヘッドスタート中は凍結されているので、明けるまで待ってから追う
	await _wait(GameManager.HEAD_START + 1.0)
	var dup_frames := 0
	var visited := {}
	var frames := int(ceil(40.0 * Engine.physics_ticks_per_second))
	for i in range(frames):
		await get_tree().physics_frame
		if GameManager.state != GameManager.State.PLAYING:
			break
		if me:
			me.teleport(Vector3(0.0, WorldData.FALL_LIMIT - 200.0, 0.0))
		var claimed := {}
		for c in cpus:
			if not is_instance_valid(c):
				continue
			visited[WorldData.zone_index(c.global_position)] = true
			var z: int = GameManager.squad.search_zone(c)
			if claimed.has(z):
				dup_frames += 1
			claimed[z] = true
	_report("担当ゾーンが重複しない", dup_frames == 0,
		"%d フレームで2体が同じゾーンを担当していた" % dup_frames)
	_report("全体に広がって探す", visited.size() >= 5,
		"40秒で %d ゾーンしか回っていない" % visited.size())

	# --- 挟み込み -------------------------------------------------------
	# 探索の計測で沈めた逃走者を地上へ戻す。持ち場はナビメッシュへ吸着させる
	# ので、逃走者が歩けない場所にいると全員の持ち場が同じ点へ潰れてしまう
	if me:
		me.teleport(WorldData.zone_center(GameManager.RUNNER_SPAWN_ZONE)
			+ Vector3(0, 1, 0))
	# 戻した直後は CPU と重なって押し出され、逃走者に数 m/s の横移動が乗る。
	# 落ち着くまで待ってから、割り当てが1回以上更新されるのを待つ
	await _wait(2.5)
	await _wait(GameManager.squad.REASSIGN_INTERVAL + 0.3)
	var runner := GameManager.get_runner() as Node3D
	_report("逃走者がいる", runner != null, "逃走者が見つからない")
	if runner:
		var primes := 0
		for c in cpus:
			if is_instance_valid(c) and GameManager.squad.is_prime(c):
				primes += 1
		_report("追跡役はちょうど1体", primes == 1, "追跡役が %d体" % primes)

		# 持ち場は「逃走者の逃走方向」を軸に左右へ分かれる。軸の決め方は
		# HunterSquad._assign_slots と必ず同じにすること。追跡役から見た方向で
		# 代用すると、逃走者が動いている時に軸がずれて誤検知する。
		#
		# 軸は必ず先に確定させること。1周のループで「追跡役なら軸を決め、
		# そうでなければ判定する」と書くと、追跡役が配列の後ろにいた時だけ
		# 初期値の軸で判定してしまい、通ったり落ちたりする
		var vel := GameManager.squad._runner_vel
		var flee := Vector2(vel.x, vel.z)
		if flee.length() < 1.5:
			for c in cpus:
				if is_instance_valid(c) and GameManager.squad.is_prime(c):
					var f := runner.global_position - c.global_position
					flee = Vector2(f.x, f.z)
					break
		var axis := flee.normalized() if flee.length() > 0.01 else Vector2.RIGHT

		var sides: Array[float] = []
		for c in cpus:
			if not is_instance_valid(c) or GameManager.squad.is_prime(c):
				continue
			var g: Vector3 = GameManager.squad.pincer_goal(c, runner)
			var d := g - runner.global_position
			sides.append(axis.cross(Vector2(d.x, d.z)))
		var ok := sides.size() == 2 and sides[0] * sides[1] < 0.0
		if not ok:
			# 原因の切り分けに要るので、失敗した時だけ内訳を出す
			print("    axis=%v (%.1fdeg) runner_vel=%v" % [axis, rad_to_deg(axis.angle()),
				GameManager.squad._runner_vel])
			for c in cpus:
				if not is_instance_valid(c):
					continue
				var sl: float = GameManager.squad._slot.get(c.get_instance_id(), NAN)
				var gg: Vector3 = GameManager.squad.pincer_goal(c, runner)
				print("      %s prime=%s slot=%.1fdeg goal_off=%v" % [c.name,
					GameManager.squad.is_prime(c), rad_to_deg(sl),
					Vector2(gg.x - runner.global_position.x, gg.z - runner.global_position.z)])
		_report("挟み役が左右に分かれる", ok,
			"持ち場が同じ側に固まっている（%s）" % [sides])

	print("=== hunter_squad の結果: %s ===" % ["ALL OK" if _fails == 0 else "%d 件 FAIL" % _fails])
	get_tree().quit(_fails)


func _settle() -> void:
	await _wait(0.5)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _report(what: String, ok: bool, why: String) -> void:
	if not ok:
		_fails += 1
	print("  %s  %s" % [what, "OK" if ok else "FAIL（%s）" % why])
