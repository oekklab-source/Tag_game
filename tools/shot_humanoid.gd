extends SceneTree

## humanoid.tscn を実際に描画して見た目を確認するスクリーンショット用スクリプト。
## 実行: godot --path <project> --script res://tools/shot_humanoid.gd -- <出力ディレクトリ> [スキンID]
##
## --headless では動かない（root のテクスチャを読むので描画ドライバが要る）。
## 装備がポーズで体や床を突き抜けないかは、静止画の Blender レンダーでは
## 分からない。忍びの刀・マフラー・帯は必ずここで Slip / Dive / Come を見ること

const POSES := [
	# 名前, アニメ, 再生位置(秒), ダイブ中か
	["idle", "Idle", 0.5, false],
	["run", "Run", 0.0, false],
	["run_pass", "Run", 0.2, false],
	["jump", "Jump", 0.33, false],
	["dive", "Dive", 0.75, true],
	# 転倒は顔面ダイブ。つんのめる -> 顔から着地 -> べたっと伸びる -> 起き上がる
	["slip_trip", "Slip", 0.10, false],
	["slip_land", "Slip", 0.30, false],
	["slip_flat", "Slip", 0.73, false],
	["slip_rise", "Slip", 1.27, false],
	["nice_down", "Nice", 0.0, false],
	["nice_up", "Nice", 0.3, false],
	# 挑発3種。各クリップの「構え」と「招いた瞬間」を1枚ずつ。
	# 腕が顔の前で交差していないか・フードに埋まっていないかはここで見る
	["come_lean_ready", "Come", 0.0, false],
	["come_lean_beck", "Come", 0.133, false],
	["come_hip_side", "ComeHip", 0.0, false],
	["come_hip_beck", "ComeHip", 0.167, false],
	["come_cool_ready", "ComeCool", 0.0, false],
	["come_cool_pull", "ComeCool", 0.267, false],
]

var _out_dir := "user://"
var _skin := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out_dir = args[0]
	if args.size() > 1:
		_skin = int(args[1])
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
	humanoid.set_skin(_skin)
	var player: AnimationPlayer = humanoid.get_node("Model").find_child(
		"AnimationPlayer", true, false)

	for pose in POSES:
		humanoid.set_diving(pose[3])
		# 転倒中は頭上に星が出る。ここで一緒に写しておく
		humanoid.set_stunned(pose[1] == "Slip")
		# ダイブ中は親が Humanoid ごと前へ倒す（player.gd の DIVE_PITCH と同じ）
		humanoid.rotation.x = -1.2 if pose[3] else 0.0
		# 前傾すると体が前下がりになるので、カメラの注視点も合わせて下げる。
		# 転倒は足元を支点に倒れるぶん、頭が前方 1.6m まで出るのでさらに前・下を見る
		var eye := Vector3(1.8, 1.5, -2.6)
		var look := Vector3(0.0, 0.85, 0.0)
		if pose[3]:
			look = Vector3(0.0, 0.45, -0.5)
		elif pose[1] == "Slip":
			# 転倒は足元から頭まで 1.7m 横に伸びるので、寄ったままだと収まらない
			eye = Vector3(2.8, 1.9, -4.2)
			look = Vector3(0.0, 0.3, -0.85)
		cam.look_at_from_position(eye, look, Vector3.UP)
		player.play(pose[1])
		player.seek(pose[2], true)
		player.pause()
		await process_frame
		await process_frame
		var img := root.get_texture().get_image()
		# ファイル名はスキンの glb 名（fallguy / ninja）。表示名は日本語なので使わない
		var skin_key: String = String(Humanoid.SKINS[_skin]["path"]).get_file().get_basename()
		var path := "%s/%s_%s.png" % [_out_dir, skin_key, pose[0]]
		print(path, " -> ", error_string(img.save_png(path)))
	quit()
