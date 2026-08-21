extends Node

## 土管の出口が真上だけでなく進行方向へも飛び出すことを確かめる。
##
##   godot --headless --path . res://tests/warp_pipe.tscn --quit-after 900
##
## 以前は出口の速度が Vector3(0, up_vel, 0) で水平成分ゼロだった。
## 無操作で入ると、入った時と同じ xz 座標へそのまま落ちてきて口に戻り、
## warp_lock(0.9s) が切れた瞬間また入ってしまう＝無限ループになる。
##
## 見るところは2つ:
##   1. 無操作（速度ゼロ）で入っても、出口の水平速度がゼロでないこと
##   2. 水平速度の向きが、入った時にキャラが向いていた方向（進行方向）と一致すること


func _ready() -> void:
	await get_tree().process_frame
	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world
	for i in 20:
		await get_tree().physics_frame

	var player: CharacterBody3D = world.get_node_or_null("Players/1")
	var pipe: Node3D = world.get_node_or_null("NavRegion/Gimmicks/WarpPipe0")
	if player == null or pipe == null:
		print("FAIL: プレイヤーか WarpPipe0 が見つからない")
		get_tree().quit()
		return

	# 静止したまま、ある向きを向いて入る（無操作での突入を再現）
	var facing := deg_to_rad(40.0)
	player.rotation.y = facing
	player.teleport(pipe.global_position + Vector3(0, 1.0, 0))
	player.velocity = Vector3.ZERO
	await get_tree().physics_frame

	var before := player.velocity
	for i in 10:
		await get_tree().physics_frame
		print("  frame %d vel=%s on_floor=%s pos=%s" % [i, player.velocity,
			player.is_on_floor(), player.global_position])
	var after := player.velocity
	var flat := Vector2(after.x, after.z)
	var fwd := -player.global_transform.basis.z  # 突入時に向いていた方向
	var expect := Vector2(fwd.x, fwd.z)

	print("--- 無操作での突入 ---")
	print("  突入前 velocity=%s" % before)
	print("  数フレーム後 velocity=%s" % after)
	print("  水平速度 %.2f m/s  %s" % [flat.length(),
		"OK" if flat.length() > 0.5 else "FAIL（真上にしか飛んでいない＝無限ループの原因）"])
	if flat.length() > 0.01:
		var dot := flat.normalized().dot(expect.normalized())
		print("  進行方向との一致 dot=%.2f  %s" % [dot,
			"OK" if dot > 0.8 else "FAIL（向きが進行方向と合っていない）"])

	get_tree().quit()
