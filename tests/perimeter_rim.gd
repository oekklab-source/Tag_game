extends Node3D
var failures := 0
func check(ok: bool, message: String) -> void:
	print("PASS: " if ok else "FAIL: ", message)
	if not ok: failures += 1
func frames(n: int) -> void:
	for i in n: await get_tree().physics_frame
func _ready() -> void:
	await get_tree().process_frame
	var args := OS.get_cmdline_user_args()
	var client := args.has("rim-client")
	var host := args.has("rim-host")
	if client or host:
		var peer := ENetMultiplayerPeer.new()
		var err := peer.create_client("127.0.0.1", 19991) if client else peer.create_server(19991, 1)
		check(err == OK, "通信ピア作成")
		multiplayer.multiplayer_peer = peer
		for i in 300:
			if not multiplayer.get_peers().is_empty(): break
			await frames(1)
	var map := Node3D.new()
	add_child(map)
	var mat := StandardMaterial3D.new()
	WorldBuilder._build_walls(map, mat)
	WorldBuilder._build_wall_corners(map, mat)
	var rim = preload("res://scenes/perimeter_rim.gd").install(map, self, mat)
	WorldBuilder._box(map, "CenterFloor", Vector3(0, -0.1, 0), Vector3(20, 0.2, 20), mat)
	var player = preload("res://scenes/player.tscn").instantiate()
	player.name = "1"
	add_child(player)
	GameManager.state = GameManager.State.PLAYING
	GameManager.runner_id = 1
	if client:
		var saw_tilt := false
		var saw_reset := false
		for i in 560:
			await frames(1)
			if not rim.ages.is_empty(): saw_tilt = true
			if saw_tilt and rim.ages.is_empty(): saw_reset = true
		check(saw_tilt and saw_reset, "別ピアにも傾きと復元が反映される")
		get_tree().quit(failures)
		return
	if not args.has("corner-only"):
		player.teleport(Vector3(0, 14, -80.5))
		await frames(240)
		check(rim.ages.is_empty(), "5秒前は傾かない")
		# 隣の区間へ移っても外周の滞在時間を引き継ぐ。
		player.global_position.x = 12
		await frames(50)
		check(rim.ages.is_empty(), "区間移動後も5秒前は静止")
		await frames(22)
		check(not rim.ages.is_empty(), "連続5秒で足元の縁だけ傾く")
		check(player.velocity.z < -1, "外側へ排出する")
		await frames(240)
		check(rim.ages.is_empty(), "縁が元に戻る")
		check(absf(player.position.z) < 3 and player.sync_respawn_left > 0, "外へ落下して中央の目回りにつながる")
		player.teleport(Vector3(20, 14, -80.5))
		await frames(180)
		player.teleport(Vector3(0, 1, 0))
		await frames(2)
		check(rim.stays.is_empty(), "外周を降りると時間をリセット")
		player.teleport(Vector3(20, 14, -80.5))
		await frames(180)
		check(rim.ages.is_empty(), "再登頂は改めて5秒待つ")
	player.teleport(Vector3(0, 1, 0))
	await frames(2)
	player.teleport(Vector3(-79, 14.1, 79))
	await frames(120)
	check(player.position.y > 13.9, "黄色い角の空洞へ落ち込まない")
	await frames(240)
	check(player.position.x < -81 and player.position.z > 81, "埋めた角も5秒後に外へ排出する")
	var giant := get_node("UnpaintedGiant")
	check(giant.find_children("*", "CollisionObject3D", true, false).is_empty(), "巨大キャラに当たり判定なし")
	var unpainted := true
	for mesh in giant.find_children("*", "MeshInstance3D", true, false):
		var color: Color = mesh.material_override.albedo_color
		unpainted = unpainted and is_equal_approx(color.r, color.g) and is_equal_approx(color.g, color.b) and mesh.cast_shadow == 0
	check(unpainted and giant.process_mode == Node.PROCESS_MODE_DISABLED, "巨大キャラは無彩色・影なし・静止")
	print("PERIMETER: ALL OK" if failures == 0 else "PERIMETER: FAILED")
	get_tree().quit(0 if failures == 0 else 1)
