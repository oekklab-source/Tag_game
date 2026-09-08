extends Node

## CPU 鬼の個体能力（ダッシュ・首振り・予測・アイテム）を確認する。
##
## 連携そのものは tests/hunter_squad.tscn が見る。こちらは「1体として強いか」を測る。

var _fails := 0
var _me: Node3D = null


func _ready() -> void:
	await get_tree().process_frame
	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world
	await _wait(1.0)

	GameManager.request_start_round()
	await _settle()
	var cpus: Array[Node3D] = []
	for n in get_tree().get_nodes_in_group("cpu_hunters"):
		cpus.append(n)
	_me = GameManager._find_player(multiplayer.get_unique_id()) as Node3D
	if cpus.is_empty() or _me == null:
		_report("前提", false, "CPU鬼か逃走者が見つからない")
		_finish()
		return
	# ヘッドスタート中は鬼が凍結されるので、明けるまで待つ
	await _wait(GameManager.HEAD_START + 0.5)

	await _test_scan(cpus)
	await _test_conserve(cpus)
	await _test_dash(cpus[0])
	_test_navmesh_snap(cpus)
	_test_predict(cpus[0])
	await _test_item(cpus[0])

	_finish()


## --- 首振り -------------------------------------------------------------
## 巡回中はボディの向きが進行方向から離れる。can_see() はボディの -Z を
## 見るので、これがそのまま実効視野の広がりになる
func _test_scan(cpus: Array[Node3D]) -> void:
	_hide_runner()
	var max_off := 0.0
	var frames := int(ceil(10.0 * Engine.physics_ticks_per_second))
	for i in range(frames):
		await get_tree().physics_frame
		_hide_runner()
		for c in cpus:
			if not is_instance_valid(c):
				continue
			var v := Vector2(c.velocity.x, c.velocity.z)
			if v.length() < 2.0:
				continue  # 止まっている時の向きは進行方向と比べても意味がない
			var moving := atan2(-v.x, -v.y)
			max_off = maxf(max_off, absf(angle_difference(c.rotation.y, moving)))
	_report("首を振って索敵する", max_off > deg_to_rad(30.0),
		"進行方向からのずれが最大 %.0f° しかない" % rad_to_deg(max_off))


## --- 温存 ---------------------------------------------------------------
func _test_conserve(cpus: Array[Node3D]) -> void:
	for c in cpus:
		c.stamina = c.STAMINA_MAX
	var frames := int(ceil(3.0 * Engine.physics_ticks_per_second))
	for i in range(frames):
		await get_tree().physics_frame
		_hide_runner()
	var lowest := INF
	for c in cpus:
		lowest = minf(lowest, c.stamina)
	_report("巡回中はスタミナを温存する", is_equal_approx(lowest, cpus[0].STAMINA_MAX),
		"見えていないのに %.1f まで減っている" % lowest)


## --- ダッシュ -----------------------------------------------------------
func _test_dash(cpu: Node3D) -> void:
	var saw_dash := await _face_and_chase(cpu, 15.0, 4.0)
	_report("見えた逃走者へダッシュする", saw_dash,
		"CHASE 距離15mでも is_dashing にならない")
	_report("ダッシュでスタミナが減る", cpu.stamina < cpu.STAMINA_MAX,
		"スタミナが %.1f のまま" % cpu.stamina)

	# 枯渇したら巡航速度へ戻る（人間の鬼と同じ経済）
	cpu.stamina = 0.0
	cpu.exhausted = true
	var still_dashing := false
	for i in range(int(ceil(0.5 * Engine.physics_ticks_per_second))):
		await get_tree().physics_frame
		_place_runner_in_front(cpu, 15.0)
		if cpu.is_dashing:
			still_dashing = true
	_report("枯渇したらダッシュできない", not still_dashing, "息切れ中でも加速している")
	cpu.stamina = cpu.STAMINA_MAX
	cpu.exhausted = false


## --- 挟み込み地点のナビ吸着 ---------------------------------------------
func _test_navmesh_snap(cpus: Array[Node3D]) -> void:
	var runner := GameManager.get_runner() as Node3D
	var flank: Node3D = null
	for c in cpus:
		if is_instance_valid(c) and not GameManager.squad.is_prime(c):
			flank = c
			break
	if flank == null or runner == null:
		_report("持ち場がナビメッシュ上にある", false, "挟み役が見つからない")
		return
	var goal: Vector3 = GameManager.squad.pincer_goal(flank, runner)
	var snapped := NavigationServer3D.map_get_closest_point(
		flank.get_world_3d().navigation_map, goal)
	_report("持ち場がナビメッシュ上にある", goal.distance_to(snapped) < 0.5,
		"持ち場が歩けない場所を指している（ずれ %.2fm）" % goal.distance_to(snapped))


## --- 見失った後の予測 ---------------------------------------------------
## 予測の中心を東端に置けば、担当ゾーンも東側（col == 2）が選ばれるはず
func _test_predict(cpu: Node3D) -> void:
	var squad: HunterSquad = GameManager.squad
	cpu.teleport(WorldData.zone_center(4) + Vector3(0, 1, 0))
	# 「予測 対 距離ペナルティ」だけを見たいので、探索の古さと他個体のゾーン所有権を
	# 平らにしておく（どのゾーンが最近掃かれたか・他のCPUが今どこを持っているかは
	# テストの進み方や実時間のブレで変わり、結果が揺れる）
	squad._zone_heat.fill(0.0)
	squad._zone_owner.clear()
	squad._claim.clear()
	squad._belief_center = WorldData.zone_center(5)
	squad._belief_dir = Vector3.ZERO
	squad._belief_left = squad.PREDICT_TIME
	var zone: int = squad.next_search_zone(cpu)
	_report("逃げた先を優先して捜索する", WorldData.ZONE_COL[zone] == 2,
		"予測を東(col 2)へ置いたのにゾーン %d を選んだ" % zone)
	squad._belief_left = 0.0


## --- アイテム -----------------------------------------------------------
## 先回りできている（逃走者が自分の背後）時にだけ置く。
## 自分では見えない位置なので、仲間の視認（GameManager.spotted）で判断する
func _test_item(cpu: Node3D) -> void:
	var items := get_tree().current_scene.get_node_or_null("Items")
	if items == null:
		_report("先回り中にバナナを置く", false, "Items ノードが無い")
		return
	var before := items.get_child_count()
	cpu.teleport(WorldData.zone_center(4) + Vector3(0, 1, 0))
	cpu.give_item(Player.Item.BANANA)
	cpu.item_lock = 0.0
	# 逃走者を CPU の真後ろ 8m に置き、仲間が見ている状態を作る
	for i in range(int(ceil(2.0 * Engine.physics_ticks_per_second))):
		await get_tree().physics_frame
		if not is_instance_valid(cpu):
			break
		var back := cpu.global_transform.basis.z
		if _me:
			_me.teleport(cpu.global_position + Vector3(back.x, 0.0, back.z).normalized() * 8.0)
		GameManager.spotted = true
		if cpu.item == Player.Item.NONE:
			break
	_report("先回り中にバナナを置く", items.get_child_count() > before,
		"背後8mに逃走者がいてもバナナが置かれない")


## --- 補助 ---------------------------------------------------------------

## 逃走者を落下限界のはるか下へ沈めて、視認されない状態を作る
func _hide_runner() -> void:
	if _me:
		_me.teleport(Vector3(0.0, WorldData.FALL_LIMIT - 200.0, 0.0))


func _place_runner_in_front(cpu: Node3D, dist: float) -> void:
	if _me == null or not is_instance_valid(cpu):
		return
	var fwd := -cpu.global_transform.basis.z
	_me.teleport(cpu.global_position + Vector3(fwd.x, 0.0, fwd.z).normalized() * dist)


## 逃走者を正面に置き続けて CHASE に入らせ、ダッシュしたかを返す
func _face_and_chase(cpu: Node3D, dist: float, sec: float) -> bool:
	var saw := false
	for i in range(int(ceil(sec * Engine.physics_ticks_per_second))):
		await get_tree().physics_frame
		if not is_instance_valid(cpu):
			break
		_place_runner_in_front(cpu, dist)
		if cpu.is_dashing:
			saw = true
	return saw


func _finish() -> void:
	print("=== cpu_strength の結果: %s ===" % ["ALL OK" if _fails == 0 else "%d 件 FAIL" % _fails])
	get_tree().quit(_fails)


func _settle() -> void:
	await _wait(0.5)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _report(what: String, ok: bool, why: String) -> void:
	if not ok:
		_fails += 1
	print("  %s  %s" % [what, "OK" if ok else "FAIL（%s）" % why])
