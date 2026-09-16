extends SceneTree

## 帽子(HatCatalog)の装着位置を目視調整するための確認シーン。
## Chest ボーン基準のオフセットは Blender/glTF 変換でボーン軸が変わるため
## 机上計算できず、ここで実際に描画して autoload/hat_catalog.gd の
## offset/rotation_degrees を追い込む。ウィンドウ有り実行専用（get_texture()で読むため）。
##
## 実行: godot --path <project> --script res://tests/hat_placement.gd -- <出力ディレクトリ>

var _out_dir := "user://"


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		_out_dir = arg
	_run()


func _run() -> void:
	await process_frame
	root.size = Vector2i(900, 620)
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

	var cam := Camera3D.new()
	cam.position = Vector3(1.6, 1.7, -5.6)
	cam.look_at_from_position(cam.position, Vector3(0.0, 1.1, 0.0), Vector3.UP)
	cam.fov = 40.0
	root.add_child(cam)
	cam.current = true

	var hat_ids: Array[StringName] = [&"party", &"cap", &"propeller"]
	var x := -1.6
	for id in hat_ids:
		var humanoid: Node3D = load("res://scenes/humanoid.tscn").instantiate()
		root.add_child(humanoid)
		humanoid.position.x = x
		humanoid.apply_hat(id)
		var player: AnimationPlayer = humanoid.get_node("Model").find_child(
			"AnimationPlayer", true, false)
		player.play("Idle")
		player.seek(0.5, true)
		player.pause()
		x += 1.6

	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	var path := "%s/hat_placement.png" % _out_dir
	print(path, " -> ", error_string(img.save_png(path)))
	quit()
