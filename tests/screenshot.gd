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
	# マンホール（PIPE YARD の Manhole0 は (14, 2, -53.5)）の寄りと、
	# 遠景から光柱が見つけられるか。地面と面一にした代わりの目印なので、
	# 遠景で見えなくなっていたらマンホールの設計が破綻している
	["manhole", Vector3(14.0, 3.4, -49.0), Vector3(14.0, 2.3, -53.5)],
	["manhole_far", Vector3(0.0, 7.0, -8.0), Vector3(14.0, 9.0, -53.5)],
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
		print("saved %s  draw calls %d" % [path,
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)])
	print("materials %d  objects %d" % [
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	await _check_wobble(cam, out)
	get_tree().quit()


## 装飾の揺れ（decor_float.gdshader）が実際に動いているか。
##
## 頂点シェーダが効いているかは静止画1枚では判断できないので、
## 同じアングルで時間を空けて2枚撮り、変化した画素の割合で判定する。
## INSTANCE_CUSTOM が Compatibility レンダラで載るかは実測でしか分からない
## （glow と同じく、仕様表を読んでも答えが出なかった箇所）
func _check_wobble(cam: Camera3D, out: String) -> void:
	cam.global_position = Vector3(0.0, 52.0, 40.0)
	cam.look_at(Vector3(0.0, 50.0, -40.0), Vector3.UP)
	var shots: Array[Image] = []
	for pass_i in 2:
		for i in 4:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/wobble_%d.png" % [out, pass_i])
		shots.append(img)
		if pass_i == 0:
			# 揺れの周期（speed 0.28 -> 約22秒）に対して十分な間隔を空ける
			var until := Time.get_ticks_msec() + 1600
			while Time.get_ticks_msec() < until:
				await get_tree().process_frame
	var a := shots[0].get_data()
	var b := shots[1].get_data()
	var diff := 0
	for i in range(0, a.size(), 3):
		if absi(int(a[i]) - int(b[i])) > 3:
			diff += 1
	var ratio := float(diff) / float(a.size() / 3)
	print("decor wobble: 変化した画素 %.2f%%  %s"
		% [ratio * 100.0, "OK" if ratio > 0.002 else "FAIL（揺れていない）"])
	await _check_instance_phase(shots[1])


## インスタンスごとの位相（INSTANCE_CUSTOM）が本当に効いているか。
##
## 時間差の比較だけでは足りない。INSTANCE_CUSTOM が読めていなくても
## 全部の雲が揃って動くので、画は変化してしまうため。
## 揺れを止めた（speed=0）状態で位相を全部 0 に潰し、画が変わるかで見る。
## 変わらなければ位相は最初から効いていなかったということになる
func _check_instance_phase(before: Image) -> void:
	var mmi: MultiMeshInstance3D = get_tree().current_scene.get_node_or_null("Decor/Clouds")
	if mmi == null:
		print("instance phase: FAIL（Decor/Clouds が無い）")
		return
	var mat: ShaderMaterial = mmi.multimesh.mesh.material
	# TIME を無効化すると、残る変位はインスタンスごとの位相ぶんだけになる
	mat.set_shader_parameter("speed", 0.0)
	var a := await _grab()
	for i in mmi.multimesh.instance_count:
		mmi.multimesh.set_instance_custom_data(i, Color(0, 0, 0, 0))
	var b := await _grab()
	var da := a.get_data()
	var db := b.get_data()
	var diff := 0
	for i in range(0, da.size(), 3):
		if absi(int(da[i]) - int(db[i])) > 3:
			diff += 1
	var ratio := float(diff) / float(da.size() / 3)
	print("instance phase: 位相を潰すと %.2f%% 変化  %s"
		% [ratio * 100.0, "OK" if ratio > 0.002 else "FAIL（INSTANCE_CUSTOM が効いていない）"])


func _grab() -> Image:
	for i in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()
