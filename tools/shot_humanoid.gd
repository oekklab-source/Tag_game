extends SceneTree

## humanoid.tscn を実際に描画して見た目を確認するスクリーンショット用スクリプト。
## 実行: godot --path <project> --script res://tools/shot_humanoid.gd -- <出力ディレクトリ>

const POSES := [
	# 名前, アニメ, 再生位置(秒), ダイブ中か, 体色
	["idle", "Idle", 0.5, false, Color(0.35, 0.78, 0.45)],
	["run", "Run", 0.0, false, Color(0.35, 0.78, 0.45)],
	["run_pass", "Run", 0.2, false, Color(0.35, 0.78, 0.45)],
	["jump", "Jump", 0.33, false, Color(0.35, 0.78, 0.45)],
	["dive", "Dive", 0.75, true, Color(0.9, 0.25, 0.25)],
]

var _out_dir := "user://"


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		_out_dir = arg
	_run()


func _run() -> void:
	await process_frame
	root.size = Vector2i(560, 620)
	root.transparent_bg = false

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.14, 0.15, 0.17)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.65)
	env.ambient_light_energy = 0.7
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	root.add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50), deg_to_rad(40), 0.0)
	sun.light_energy = 1.6
	root.add_child(sun)

	# キャラの正面は -Z。斜め前から見下ろす
	var cam := Camera3D.new()
	cam.position = Vector3(1.8, 1.5, -2.6)
	cam.look_at_from_position(cam.position, Vector3(0.0, 0.85, 0.0), Vector3.UP)
	cam.fov = 45.0
	root.add_child(cam)
	cam.current = true

	var humanoid: Node3D = load("res://scenes/humanoid.tscn").instantiate()
	root.add_child(humanoid)
	var player: AnimationPlayer = humanoid.get_node("Model").find_child(
		"AnimationPlayer", true, false)

	for pose in POSES:
		humanoid.set_color(pose[4])
		humanoid.set_diving(pose[3])
		# ダイブ中は親が Humanoid ごと前へ倒す（player.gd の DIVE_PITCH と同じ）
		humanoid.rotation.x = -1.2 if pose[3] else 0.0
		# 前傾すると体が前下がりになるので、カメラの注視点も合わせて下げる
		cam.look_at_from_position(cam.position,
			Vector3(0.0, 0.45, -0.5) if pose[3] else Vector3(0.0, 0.85, 0.0), Vector3.UP)
		player.play(pose[1])
		player.seek(pose[2], true)
		player.pause()
		await process_frame
		await process_frame
		var img := root.get_texture().get_image()
		var path := "%s/humanoid_%s.png" % [_out_dir, pose[0]]
		print(path, " -> ", error_string(img.save_png(path)))
	quit()
