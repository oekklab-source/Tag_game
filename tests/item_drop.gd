extends Node

## 置き物アイテム（バナナ・ブロック）が実際に生成されるかを確かめる。
##
##   godot --headless --path . res://tests/item_drop.tscn --quit-after 900
##
## 本物の world.tscn を current_scene に据えて動かす。
## GameManager.request_drop が current_scene 経由で spawn_dropped_item を呼ぶので、
## ここを差し替えると経路を実際には検証できなくなる。
##
## ラウンド外（WAITING）でも置けることを見るのが要点。
## 以前ここが PLAYING 限定で、？ブロック側には状態の判定が無かったため、
## マップを歩き回って試すとアイテムだけ消えて何も置かれなかった。

const POSITION_EPS := 0.05
const BANANA_SCENE := preload("res://scenes/gimmicks/banana.tscn")
const BLOCK_SCENE := preload("res://scenes/gimmicks/placed_block.tscn")

var _failures := 0


func _ready() -> void:
	# root は _ready の最中に子を追加できないので1フレーム待つ
	await get_tree().process_frame
	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world
	for i in 20:
		await get_tree().physics_frame

	var player: Node = world.get_node_or_null("Players/1")
	if player == null:
		print("FAIL: プレイヤーがスポーンしていない")
		get_tree().quit()
		return
	var items: Node = world.get_node("Items")

	print("--- state=WAITING（ラウンド外）---")
	await _drop_all(player, items)
	GameManager.state = GameManager.State.PLAYING
	GameManager.head_start_left = 0.0
	print("--- state=PLAYING ---")
	await _drop_all(player, items)
	await _verify_placement_rules(player, items)
	await _verify_thrown_banana_physics()

	# ？ブロックから受け取れるかも見る（触れた時と同じ経路を通す）
	var qblock: Node = world.get_node_or_null("NavRegion/Gimmicks/QuestionBlock0")
	if qblock == null:
		print("FAIL: ？ブロックが無い")
	else:
		player.item = Player.Item.NONE
		qblock._on_touch(player)
		await get_tree().physics_frame
		print("  question block -> item %d  %s"
			% [player.item, "OK" if player.item != Player.Item.NONE else "FAIL"])

	print("--- InputMap ---")
	for a in InputMap.get_actions():
		if String(a).begins_with("ui_"):
			continue
		var keys := PackedStringArray()
		for e in InputMap.action_get_events(a):
			if e is InputEventKey:
				keys.append(OS.get_keycode_string(e.physical_keycode))
			elif e is InputEventMouseButton:
				keys.append("Mouse%d" % e.button_index)
		print("  %-14s %s" % [a, ", ".join(keys)])
	print("=== item_drop の結果: %s ===" % [
		"ALL OK" if _failures == 0 else "%d 件 FAIL" % _failures])
	get_tree().quit(_failures)


func _drop_all(player: Node, items: Node) -> void:
	for kind in [Player.Item.BANANA, Player.Item.BLOCK]:
		var before := items.get_child_count()
		player.item = kind
		player._use_item()
		await get_tree().physics_frame
		var after := items.get_child_count()
		print("  item %d: %d -> %d  %s"
			% [kind, before, after, "OK" if after > before else "FAIL"])
		if after > before:
			var drop: Node3D = items.get_child(after - 1)
			var layer: int = drop.collision_layer if drop is CollisionObject3D else -1
			print("    %s  layer=%d  script=%s" % [drop.name, layer,
				drop.get_script().resource_path.get_file() if drop.get_script() else "-"])


func _verify_placement_rules(player: Node3D, items: Node) -> void:
	print("--- 配置仕様 ---")
	for child in items.get_children():
		child.queue_free()
	await get_tree().process_frame

	GameManager.state = GameManager.State.PLAYING
	GameManager.head_start_left = 0.0
	player.rotation.y = 0.0
	var origin := player.global_position
	var player_id := String(player.name).to_int()

	var block := _spawn_item(player, items, Player.Item.BLOCK)
	var expected_block := origin + Vector3(0.0, 0.0, Player.BLOCK_BEHIND)
	_report("壁は背後3m", block != null
		and block.global_position.distance_to(expected_block) < POSITION_EPS,
		"位置 %s / 期待 %s" % [block.global_position, expected_block] if block else "生成なし")
	if block:
		var excluded: Dictionary = player.get("_camera_block_rids")
		_report("生成直後に壁をカメラ判定から除外", excluded.has(block.get_instance_id()),
			"登録数 %d" % excluded.size())
		player.call("_update_placed_block_camera")
		_report("実カメラ方向でも壁を透過判定", block.get("_camera_obscured"),
			"SpringArm角度 %s / 長さ %.1f" % [player.spring_arm.rotation,
				player.spring_arm.spring_length])
		block._process(0.0)
		await _save_wall_shot_if_requested()
		var target := origin + Vector3.UP * 1.6
		block.update_camera_obscured(target, target + Vector3(0.0, 0.0, 4.0))
		block._process(0.0)
		var hidden_alpha: float = block.mesh.material_override.albedo_color.a
		block.update_camera_obscured(target, target + Vector3(4.0, 0.0, 0.0))
		block._process(0.0)
		var clear_alpha: float = block.mesh.material_override.albedo_color.a
		_report("視界内だけ壁を半透明化", hidden_alpha >= 0.30 and hidden_alpha <= 0.35
			and clear_alpha >= 0.99,
			"遮蔽時alpha %.2f / 復帰後alpha %.2f" % [hidden_alpha, clear_alpha])
		block.queue_free()
		await get_tree().process_frame

	GameManager.runner_id = player_id
	var runner_banana := _spawn_item(player, items, Player.Item.BANANA)
	var expected_runner := player.global_position + Vector3(0.0, 0.0, Player.BANANA_BEHIND)
	_report("逃走者のバナナは背後3m", runner_banana != null
		and runner_banana.global_position.distance_to(expected_runner) < POSITION_EPS
		and runner_banana.launch_velocity.is_zero_approx(),
		"位置 %s / 初速 %s" % [runner_banana.global_position, runner_banana.launch_velocity]
		if runner_banana else "生成なし")
	if runner_banana:
		runner_banana.queue_free()
		await get_tree().process_frame

	GameManager.runner_id = 0
	player.velocity = Vector3.ZERO
	var hunter_banana := _spawn_item(player, items, Player.Item.BANANA)
	var fwd := Vector3.FORWARD
	var expected_spawn := player.global_position + fwd * Player.BANANA_THROW_SPAWN + Vector3.UP
	var launch_ok := hunter_banana != null \
		and hunter_banana.global_position.distance_to(expected_spawn) < POSITION_EPS \
		and is_equal_approx(hunter_banana.launch_velocity.y, Player.BANANA_THROW_UP) \
		and is_equal_approx(Vector2(hunter_banana.launch_velocity.x,
			hunter_banana.launch_velocity.z).length(), Player.BANANA_THROW_FORWARD)
	_report("鬼のバナナは前方へ投げる", launch_ok,
		"位置 %s / 初速 %s" % [hunter_banana.global_position, hunter_banana.launch_velocity]
		if hunter_banana else "生成なし")
	if hunter_banana:
		var gravity := float(hunter_banana.THROW_GRAVITY)
		var flight_time := (Player.BANANA_THROW_UP + sqrt(
			Player.BANANA_THROW_UP * Player.BANANA_THROW_UP + 2.0 * gravity)) / gravity
		var distance := Player.BANANA_THROW_SPAWN + Player.BANANA_THROW_FORWARD * flight_time
		var peak := 1.0 + Player.BANANA_THROW_UP * Player.BANANA_THROW_UP / (2.0 * gravity)
		_report("放物線は約16m・最高点約4m", distance >= 15.8 and distance <= 16.2
			and peak >= 3.9 and peak <= 4.1,
			"着地点 %.2fm / 最高点 %.2fm" % [distance, peak])
		hunter_banana._on_body_entered(player)
		_report("飛行中は投げ主へ当たらない", not hunter_banana.get("_used"),
			"使用済み=%s" % hunter_banana.get("_used"))
		hunter_banana.queue_free()
		await get_tree().process_frame

	player.velocity = Vector3(2.0, 1.5, -3.0)
	var moving_banana := _spawn_item(player, items, Player.Item.BANANA)
	var expected_moving_velocity := Vector3(1.0,
		Player.BANANA_THROW_UP + 0.75, -Player.BANANA_THROW_FORWARD - 1.5)
	_report("投げ手の全方向速度を半分加算", moving_banana != null
		and moving_banana.launch_velocity.distance_to(expected_moving_velocity) < 0.01,
		"初速 %s / 期待 %s" % [moving_banana.launch_velocity, expected_moving_velocity]
		if moving_banana else "生成なし")
	player.velocity = Vector3.ZERO
	if moving_banana:
		moving_banana.queue_free()
		await get_tree().process_frame


func _spawn_item(player: Node, items: Node, kind: int) -> Node3D:
	var before := items.get_child_count()
	player.item = kind
	player.item_lock = 0.0
	player._use_item()
	if items.get_child_count() <= before:
		return null
	return items.get_child(items.get_child_count() - 1) as Node3D


func _verify_thrown_banana_physics() -> void:
	print("--- 投げバナナ物理 ---")
	var floor_top := 40.0
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.position = Vector3(100.0, floor_top - 0.5, 100.0)
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(80.0, 1.0, 30.0)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	add_child(floor_body)
	await get_tree().physics_frame

	var banana: Area3D = BANANA_SCENE.instantiate()
	banana.position = Vector3(100.0, floor_top + 1.0, 104.0)
	banana.launch_velocity = Vector3(0.0, Player.BANANA_THROW_UP,
		-Player.BANANA_THROW_FORWARD)
	banana.thrower_peer_id = 1
	add_child(banana)
	var start := banana.global_position
	var peak := start.y
	for i in 120:
		await get_tree().physics_frame
		peak = maxf(peak, banana.global_position.y)
		if banana.get("_landed"):
			break
	var flight_distance := start.z - banana.global_position.z
	var peak_height := peak - floor_top
	_report("実物も放物線で着地", banana.get("_landed")
		and flight_distance >= 14.5 and flight_distance <= 15.0
		and peak_height >= 3.9 and peak_height <= 4.1,
		"飛行 %.2fm / 最高点 %.2fm" % [flight_distance, peak_height])
	banana.queue_free()
	await get_tree().process_frame

	var wall: StaticBody3D = BLOCK_SCENE.instantiate()
	wall.position = Vector3(130.0, floor_top, 100.0)
	add_child(wall)
	await get_tree().physics_frame
	var blocked_banana: Area3D = BANANA_SCENE.instantiate()
	blocked_banana.position = Vector3(130.0, floor_top + 1.0, 104.0)
	blocked_banana.launch_velocity = Vector3(0.0, Player.BANANA_THROW_UP,
		-Player.BANANA_THROW_FORWARD)
	blocked_banana.thrower_peer_id = 1
	add_child(blocked_banana)
	for i in 120:
		await get_tree().physics_frame
		if blocked_banana.get("_landed"):
			break
	var blocked_distance := 104.0 - blocked_banana.global_position.z
	_report("壁へ当たると貫通せず落下", blocked_banana.get("_landed")
		and blocked_distance >= 3.3 and blocked_distance <= 3.6,
		"壁までの飛行 %.2fm / 着地Z %.2f" % [
			blocked_distance, blocked_banana.global_position.z])
	blocked_banana.queue_free()
	wall.queue_free()
	floor_body.queue_free()
	await get_tree().process_frame


func _report(label: String, ok: bool, detail: String) -> void:
	print("  %-30s %s (%s)" % [label, "OK" if ok else "FAIL", detail])
	if not ok:
		_failures += 1


func _save_wall_shot_if_requested() -> void:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--wall-shot")
	if index < 0 or index + 1 >= args.size():
		return
	for i in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path: String = args[index + 1]
	get_viewport().get_texture().get_image().save_png(path)
	print("  壁透過スクリーンショット: %s" % path)
