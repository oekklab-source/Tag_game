extends Node3D

var failures := 0


func check(ok: bool, label: String) -> void:
	print("PASS: " if ok else "FAIL: ", label)
	if not ok:
		failures += 1


func frames(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _ready() -> void:
	await get_tree().process_frame
	var args := OS.get_cmdline_user_args()
	var client := args.has("respawn-client")
	var host := args.has("respawn-host")
	if client or host:
		var peer := ENetMultiplayerPeer.new()
		var err := peer.create_client("127.0.0.1", 19990) if client else peer.create_server(19990, 1)
		check(err == OK, "通信ピア作成")
		if err != OK:
			get_tree().quit(1)
			return
		multiplayer.multiplayer_peer = peer
		for i in 300:
			if not multiplayer.get_peers().is_empty():
				break
			await frames(1)
		if multiplayer.get_peers().is_empty():
			check(false, "接続タイムアウト")
			get_tree().quit(1)
			return
	var center := WorldData.zone_center(4)
	var floor_body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(100, 0.2, 100)
	col.shape = box
	floor_body.position = center - Vector3.UP * 0.1
	floor_body.add_child(col)
	add_child(floor_body)
	var player: CharacterBody3D = load("res://scenes/player.tscn").instantiate()
	player.name = "1"
	add_child(player)
	var anim: AnimationPlayer = player.find_child("AnimationPlayer", true, false)
	if client:
		var saw_animation := false
		var saw_end := false
		for i in 260:
			await frames(1)
			var birds := player.get_node_or_null("Humanoid/RespawnBirds")
			if player.sync_respawn_left > 0 and anim.current_animation == "RespawnDizzy" and birds and birds.visible:
				saw_animation = true
			if saw_animation and player.sync_respawn_left <= 0 and birds and not birds.visible:
				saw_end = true
		check(saw_animation and saw_end, "別ピアでも目回り/小鳥の開始と終了が一致")
	else:
		player.teleport(center + Vector3.UP * 0.1)
		await frames(5)
		check(player.sync_respawn_left == 0, "通常teleportはペナルティなし")
		player.position.y = WorldData.FALL_LIMIT - 1
		await frames(3)
		check(player.sync_respawn_left > 2.9, "落下判定から3秒ペナルティを開始")
		var origin := Vector2(player.position.x, player.position.z)
		check(origin.distance_to(Vector2(center.x, center.z)) < 0.01, "既存の中央復帰位置を維持")
		Input.action_press("move_forward")
		Input.action_press("dash")
		Input.action_press("dive")
		var drift := 0.0
		var locked_frames := 0
		while player.sync_respawn_left > 0 and locked_frames < 190:
			drift = maxf(drift, origin.distance_to(Vector2(player.position.x, player.position.z)))
			await frames(1)
			locked_frames += 1
		check(drift < 0.001 and not player.diving, "ペナルティ中は移動/ダッシュ/飛びつき不可")
		check(locked_frames >= 175 and locked_frames <= 181, "解除まで約3秒")
		check(anim.has_animation("RespawnDizzy") and is_equal_approx(anim.get_animation("RespawnDizzy").length, 3.0), "アニメも立ち上がり込み3秒")
		await frames(5)
		check(player.velocity.length() > 0.1, "3秒後は操作が戻る")
		Input.action_release("move_forward")
		Input.action_release("dash")
		Input.action_release("dive")
		player.teleport(center + Vector3(10, 0.1, 0))
		player.apply_stun(1.5)
		await frames(2)
		check(anim.current_animation == "Slip" and player.sync_respawn_left == 0, "バナナ転倒は既存Slipのまま")
		if not host:
			for kind in ["cpu_hunter", "cpu_runner"]:
				var cpu: CharacterBody3D = load("res://scenes/%s.tscn" % kind).instantiate()
				cpu.name = kind
				add_child(cpu)
				cpu.respawn_after_fall()
				check(cpu.sync_respawn_left == 3.0, kind + "も同じ3秒ペナルティ")
				cpu.teleport(center + Vector3(20, 0.1, 0))
				check(cpu.sync_respawn_left == 0, kind + "の通常配置はペナルティ解除")
				cpu.queue_free()
		if host:
			await frames(120)
	print("RESPAWN TEST: ", "ALL OK" if failures == 0 else str(failures) + " FAILED")
	get_tree().quit(0 if failures == 0 else 1)
