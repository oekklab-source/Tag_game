extends Node

## マップの見た目を固定アングルで撮って PNG に落とす。
## 環境やマテリアルを触ったとき、実際にどう見えるかを確認するための道具。
##
##   godot --path . res://tests/screenshot.tscn -- --shots <出力先フォルダ>
##
## --headless では描画が走らないので必ずウィンドウ有りで実行する。
## アングルは固定にしてあるので、変更の前後を並べて比べられる。

const SHOTS: Array = [
	# [名前, カメラ位置, 注視点]
	["overview", Vector3(-95.0, 78.0, -95.0), Vector3(0.0, 0.0, 0.0)],
	["slide", Vector3(-88.0, 18.0, -18.0), Vector3(-70.0, 5.0, -20.0)],
	["ground", Vector3(0.0, 3.0, 34.0), Vector3(0.0, 2.0, 0.0)],
	["highzone", Vector3(-40.0, 16.0, -20.0), Vector3(-60.0, 8.0, -50.0)],
	# ？ブロック（emission 1.2）の寄り。glow_hdr_threshold=1.0 を超えるので、
	# ここに滲みが出ていれば Compatibility レンダラで glow が効いている証拠
	["glow", Vector3(45.5, 5.5, -55.0), Vector3(45.5, 5.5, -61.5)],
]


func _ready() -> void:
	var out := "."
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--shots" and i + 1 < args.size():
			out = args[i + 1]
	DirAccess.make_dir_recursive_absolute(out)

	await get_tree().process_frame
	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world
	for i in 30:
		await get_tree().physics_frame

	# プレイヤーのカメラを奪わずに自前のカメラを最前面にする
	var cam := Camera3D.new()
	cam.far = 400.0
	world.add_child(cam)
	cam.current = true
	# HUD はマップの見た目の邪魔になるので隠す
	var hud: CanvasLayer = world.get_node_or_null("HUD")
	if hud:
		hud.visible = false

	for shot in SHOTS:
		cam.global_position = shot[1]
		cam.look_at(shot[2], Vector3.UP)
		for i in 4:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path: String = "%s/%s.png" % [out, shot[0]]
		img.save_png(path)
		print("saved %s (%dx%d)" % [path, img.get_width(), img.get_height()])
	get_tree().quit()
