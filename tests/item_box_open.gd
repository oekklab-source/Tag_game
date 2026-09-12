extends Node

## プレゼント箱の開封エフェクト（光の輪・紙吹雪）を検証する。
##
##   godot --headless --path . res://tests/item_box_open.tscn
##   godot --path . res://tests/item_box_open.tscn -- --shots tests/shots/item_box
##
## 加算合成とグローが効いた見た目は headless では確かめられないので、
## --shots で開封の各時点を PNG に落とせるようにしてある（slip.gd と同じ形）。
##
## 見るところは4つ:
##   1. glb から Base / Lid / Burst / Confetti の4つが名前で取れること
##      （Godot 側はすべて find_child の名前解決に依存している）
##   2. ふだんはキラキラが隠れていて、加算合成シェーダに差し替わっていること
##      （glb そのままの不透明材だと、金色の板が箱に刺さって見える）
##   3. 開封中は実際にキラキラが出て広がり、消えぎわに fade が引かれること
##   4. 後始末で姿勢・可視・fade が初期状態へ戻ること。
##      ここを落とすと2回目以降の開封で「消えたままの紙吹雪」が出て何も見えない

const QBLOCK := preload("res://scenes/gimmicks/question_block.tscn")
## --shots のときだけ掛けるスロー倍率。演出は 0.66 秒しかないのに
## PNG 1枚の書き出しに 0.3 秒掛かるので、実時間のままでは中盤が撮れない
const SHOT_SLOW := 0.05

var _fail := 0


func _ready() -> void:
	print("=== プレゼント箱の開封エフェクトの検証 ===")
	_check_model()
	_check_idle()
	await _check_open()
	print("=== %s ===" % ("すべての検証に合格しました" if _fail == 0
		else "%d 件の検証に失敗しました" % _fail))
	var out := ""
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--shots" and i + 1 < args.size():
			out = args[i + 1]
	if out != "":
		await _shots(out)
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(label: String, cond: bool, extra := "") -> void:
	if not cond:
		_fail += 1
	print("  %s: %s%s" % [label, "OK" if cond else "FAIL",
		"" if extra.is_empty() else "  (%s)" % extra])


## 単体で置いた？ブロックを返す。world.tscn は待ち受けポートを掴むので使わない
func _spawn() -> Area3D:
	var block: Area3D = QBLOCK.instantiate()
	add_child(block)
	return block


## --- 1. glb の構造 -----------------------------------------------------

func _check_model() -> void:
	print("[1] glb のオブジェクト構成")
	var block := _spawn()
	var model: Node3D = block.get_node("Model")
	for part in ["Base", "Lid", "Burst", "Confetti"]:
		_ok("%s が取れる" % part, model.find_child(part, true, false) != null)
	for part in ["Burst", "Confetti"]:
		_ok("%s が GeometryInstance3D" % part,
			model.find_child(part, true, false) is GeometryInstance3D)
	block.queue_free()


## --- 2. ふだんの状態 ---------------------------------------------------

func _check_idle() -> void:
	print("[2] 非開封時のキラキラ")
	var block := _spawn()
	var model: Node3D = block.get_node("Model")
	for part in ["Burst", "Confetti"]:
		var node: GeometryInstance3D = model.find_child(part, true, false)
		_ok("%s が隠れている" % part, not node.visible)
		var mat := node.material_override as ShaderMaterial
		_ok("%s が加算合成シェーダ" % part,
			mat != null and mat.shader == preload("res://scenes/beacon.gdshader"))
		if mat != null:
			_ok("%s の fade が 1.0" % part,
				is_equal_approx(mat.get_shader_parameter("fade"), 1.0))
	block.queue_free()


## --- 3. 開封中と 4. 後始末 ---------------------------------------------

func _check_open() -> void:
	print("[3] 開封中のキラキラ")
	var block := _spawn()
	var model: Node3D = block.get_node("Model")
	var burst: GeometryInstance3D = model.find_child("Burst", true, false)
	var confetti: GeometryInstance3D = model.find_child("Confetti", true, false)
	var burst_home := burst.transform
	var confetti_home := confetti.transform

	# 取得者を指さずに開封だけ走らせる（NodePath が空なら give_item は飛ばされる）
	block._pop(1, NodePath())
	await get_tree().create_timer(0.25).timeout

	_ok("光の輪が出ている", burst.visible)
	_ok("紙吹雪が出ている", confetti.visible)
	_ok("光の輪が広がっている", burst.scale.x > 1.0, "scale.x=%.2f" % burst.scale.x)
	_ok("紙吹雪が広がっている", confetti.scale.x > 0.25,
		"scale.x=%.2f" % confetti.scale.x)
	_ok("紙吹雪が舞い上がっている", confetti.position.y > confetti_home.origin.y,
		"y=%.2f" % confetti.position.y)
	var burst_fade: float = (burst.material_override as ShaderMaterial) \
		.get_shader_parameter("fade")
	_ok("光の輪が薄れ始めている", burst_fade < 1.0, "fade=%.2f" % burst_fade)

	# OPEN_TIME(0.66) を過ぎれば箱ごと消えている
	await get_tree().create_timer(0.55).timeout
	_ok("開封後に箱が消える", not model.visible)

	print("[4] 後始末")
	block._reset_parts()
	for pair in [[burst, burst_home, "光の輪"], [confetti, confetti_home, "紙吹雪"]]:
		var node: GeometryInstance3D = pair[0]
		var home: Transform3D = pair[1]
		var label: String = pair[2]
		_ok("%sが隠れる" % label, not node.visible)
		_ok("%sの姿勢が戻る" % label, node.transform.is_equal_approx(home))
		_ok("%sの fade が戻る" % label, is_equal_approx(
			(node.material_override as ShaderMaterial).get_shader_parameter("fade"), 1.0))
	block.queue_free()


## --- 見た目の確認用 -----------------------------------------------------

## 開封の各時点を PNG に落とす。環境は world.tscn の Environment を写して作る。
## 加算合成は背景の明るさで見え方が丸ごと変わるので、トーンマップとグローを
## 本番と揃えないと「実機より派手／地味」な絵で判断してしまう
func _shots(out: String) -> void:
	DirAccess.make_dir_recursive_absolute(out)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40.0, 40.0)
	floor_mesh.mesh = plane
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.62, 0.66, 0.74)
	floor_mesh.material_override = floor_mat
	add_child(floor_mesh)
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.9, -0.6, 0.0)
	add_child(light)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = Sky.new()
	env.environment.sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment.ambient_light_color = Color(0.65, 0.70, 0.88)
	env.environment.ambient_light_energy = 0.35
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment.tonemap_white = 1.3
	env.environment.glow_enabled = true
	env.environment.glow_intensity = 0.8
	env.environment.glow_bloom = 0.15
	env.environment.glow_hdr_threshold = 1.0
	env.environment.adjustment_enabled = true
	env.environment.adjustment_contrast = 1.1
	env.environment.adjustment_saturation = 1.05
	add_child(env)
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0.0, 3.0, 6.8)
	cam.look_at(Vector3(0.0, 2.0, 0.0), Vector3.UP)
	cam.current = true

	# 1枚の書き出しに 0.3 秒ほど掛かるので、実時間では 0.66 秒の演出を追えない。
	# 時間を 1/20 に落として、演出の側をこちらに合わせる
	Engine.time_scale = SHOT_SLOW
	var block := _spawn()
	await get_tree().process_frame
	block._pop(1, NodePath())
	var t0 := Time.get_ticks_msec()
	# 0.00 は開封直前、以降は光の輪と紙吹雪が広がって消えるまでの過程
	for at in [0.0, 0.08, 0.16, 0.26, 0.40, 0.56]:
		var until := int(at * 1000.0 / SHOT_SLOW)
		while Time.get_ticks_msec() - t0 < until:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var path := "%s/item_box_%03d.png" % [out, int(at * 100.0)]
		get_viewport().get_texture().get_image().save_png(path)
		print("saved ", path)
	Engine.time_scale = 1.0
