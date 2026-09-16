extends Node3D

var failures := 0
var player: Player


func check(ok: bool, label: String) -> void:
	print("PASS: " if ok else "FAIL: ", label)
	if not ok:
		failures += 1


func frames(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func angle_close(actual: float, expected: float, tolerance := 0.08) -> bool:
	return absf(angle_difference(actual, expected)) <= tolerance


func _ready() -> void:
	var floor_body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30.0, 0.2, 30.0)
	collision.shape = box
	floor_body.position.y = -0.1
	floor_body.add_child(collision)
	add_child(floor_body)

	player = load("res://scenes/player.tscn").instantiate()
	player.name = str(multiplayer.get_unique_id())
	add_child(player)
	await frames(3)
	player.set_process(false)
	player.sync_facing_yaw = 0.0
	player.humanoid.rotation.y = 0.0
	Input.action_press("move_back")
	await frames(1)
	player._process(1.0 / 60.0)
	var first_turn := absf(player.humanoid.rotation.y)
	check(first_turn > 0.1 and first_turn < PI - 0.1, "向きは瞬間移動せず滑らかに回る")
	for i in 9:
		player._process(1.0 / 60.0)
	check(angle_close(player.humanoid.rotation.y, PI), "約0.15秒で手前向きに切り替わる")
	Input.action_release("move_back")
	player.set_process(true)

	var cases := [
		[["move_forward"], 0.0, "Wで奥を向く"],
		[["move_back"], PI, "Sで手前を向く"],
		[["move_left"], PI * 0.5, "Aで左を向く"],
		[["move_right"], -PI * 0.5, "Dで右を向く"],
		[["move_forward", "move_left"], PI * 0.25, "WAで左奥を向く"],
		[["move_forward", "move_right"], -PI * 0.25, "WDで右奥を向く"],
		[["move_back", "move_left"], PI * 0.75, "SAで左手前を向く"],
		[["move_back", "move_right"], -PI * 0.75, "SDで右手前を向く"],
	]
	for test_case in cases:
		await check_direction(test_case[0], test_case[1], test_case[2])

	var held_yaw := player.sync_facing_yaw
	await frames(12)
	check(angle_close(player.sync_facing_yaw, held_yaw, 0.001), "停止後も最後の向きを維持")

	var body_yaw := player.rotation.y
	var camera_yaw := player.spring_arm.rotation.y
	await check_direction(["move_left"], PI * 0.5, "見た目だけ左へ向く")
	check(angle_close(player.rotation.y, body_yaw, 0.001), "Player本体の向きを変えない")
	check(angle_close(player.spring_arm.rotation.y, camera_yaw, 0.001), "カメラの向きを変えない")

	player.apply_stun(1.5)
	await frames(15)
	check(angle_close(player.humanoid.rotation.y, 0.0), "転倒中は既存の正面姿勢を優先")
	check(angle_close(player.sync_facing_yaw, PI * 0.5), "特殊姿勢中も最後の通常移動方向を保持")

	var synchronizer: MultiplayerSynchronizer = player.get_node("MultiplayerSynchronizer")
	var config := synchronizer.replication_config
	check(config.has_property(NodePath(".:sync_facing_yaw")),
		"見た目の向きをMultiplayerSynchronizerで同期")

	for action in ["move_forward", "move_back", "move_left", "move_right"]:
		Input.action_release(action)
	print("PLAYER FACING TEST: ", "ALL OK" if failures == 0 else str(failures) + " FAILED")
	get_tree().quit(0 if failures == 0 else 1)


func check_direction(actions: Array, expected: float, label: String) -> void:
	for action in ["move_forward", "move_back", "move_left", "move_right"]:
		Input.action_release(action)
	for action in actions:
		Input.action_press(action)
	await frames(18)
	check(angle_close(player.sync_facing_yaw, expected, 0.001), label + "（同期値）")
	check(angle_close(player.humanoid.rotation.y, expected), label + "（表示）")
	for action in actions:
		Input.action_release(action)
	await frames(1)
