extends Node

## バンパーが全キャラクターを一定の強さで弾き返すかを確かめる。
##
##   godot --headless --path . --scene res://tests/bumper.tscn
##
## 通信ポートを使うワールド全体テストにはせず、バンパーの実際の接触処理と
## Player / CPU鬼 / CPU逃走者の実シーンを直接組み合わせる。
## これならゲームを起動したままでも、接触後の速度を決定論的に検証できる。

const BUMPER_SCRIPT := preload("res://scenes/gimmicks/bumper.gd")
const PLAYER_SCENE := preload("res://scenes/player.tscn")
const CPU_HUNTER_SCENE := preload("res://scenes/cpu_hunter.tscn")
const CPU_RUNNER_SCENE := preload("res://scenes/cpu_runner.tscn")

const PUSH := 13.0
const LIFT := 4.0

var _failures := 0


func _ready() -> void:
	await _test_visual_and_collision()
	var bumper := Area3D.new()
	bumper.set_script(BUMPER_SCRIPT)
	add_child(bumper)
	await get_tree().process_frame

	for setup in [
		{"name": "Player", "scene": PLAYER_SCENE},
		{"name": "CPU鬼", "scene": CPU_HUNTER_SCENE},
		{"name": "CPU逃走者", "scene": CPU_RUNNER_SCENE},
	]:
		var body := (setup["scene"] as PackedScene).instantiate() as CharacterBody3D
		body.name = setup["name"]
		add_child(body)
		await get_tree().process_frame
		# Player は権威ピアだけが衝突効果を適用する。本番のローカルプレイヤーと
		# 同じ条件にして、CPU と同じ接触処理を検証する。子ノードの同期設定が
		# 準備された後に設定しないと、Player 側の権威が更新されない。
		body.set_multiplayer_authority(1, true)
		await _run_cases(bumper, body)
		body.queue_free()
		await get_tree().process_frame

	print("=== bumper の結果: %s ===" % ["ALL OK" if _failures == 0 else "%d 件 FAIL" % _failures])
	get_tree().quit(_failures)


func _test_visual_and_collision() -> void:
	var root := Node3D.new()
	add_child(root)
	WorldBuilder._bumper(root, "VisualSample", Vector3.ZERO,
		WorldBuilder.soft_material(Color.WHITE))
	var sample := root.get_node_or_null("VisualSample") as StaticBody3D
	var hit_area := root.get_node_or_null("VisualSample/Hit") as Area3D
	var hit_shape: CollisionShape3D = null
	if hit_area:
		for child in hit_area.get_children():
			if child is CollisionShape3D:
				hit_shape = child
				break
	var hit := hit_shape.shape as CylinderShape3D if hit_shape else null
	var required := [
		"Visual/Base", "Visual/BaseTrim", "Visual/BounceVisual/Dome",
		"Visual/BounceVisual/InnerPad", "Visual/BounceVisual/Rim",
		"Visual/BounceVisual/Clip0", "Visual/BounceVisual/Clip1",
		"Visual/BounceVisual/Clip2", "Visual/BounceVisual/Clip3",
		"Visual/BounceVisual/Spring0_0", "Visual/BounceVisual/Spring1_0",
		"Visual/BounceVisual/Spring2_0", "Visual/BounceVisual/Spring3_0",
	]
	var parts_ok := sample != null
	if sample:
		for path in required:
			parts_ok = parts_ok and sample.has_node(path)
	var collision_ok := hit != null and is_equal_approx(hit.radius, 2.7) \
		and is_equal_approx(hit.height, 3.2)
	var dome_instance := sample.get_node_or_null("Visual/BounceVisual/Dome") as MeshInstance3D \
		if sample else null
	var dome_material := dome_instance.mesh.material as StandardMaterial3D \
		if dome_instance and dome_instance.mesh else null
	var dome_mesh := dome_instance.mesh as SphereMesh if dome_instance else null
	var frosted_ok := dome_material != null \
		and dome_material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA \
		and dome_material.albedo_color.a > 0.35 and dome_material.albedo_color.a < 0.65 \
		and dome_material.roughness >= 0.85
	var dome_size_ok := dome_mesh != null and is_equal_approx(dome_mesh.radius * 2.0, 3.92) \
		and is_equal_approx(dome_mesh.height * dome_instance.scale.y, 1.6856)
	_report("9番の外観部品", parts_ok,
		"半透明ドーム・内側パッド・リム・4個の留め具・4本のバネ")
	_report("ドームのマット透明表現", frosted_ok,
		"透明度 %.2f / 粗さ %.2f" % [dome_material.albedo_color.a, dome_material.roughness]
		if dome_material else "マテリアルなし")
	_report("ドームの大きさ", dome_size_ok,
		"幅 %.2f / 高さ %.2f" % [dome_mesh.radius * 2.0,
			dome_mesh.height * dome_instance.scale.y] if dome_mesh else "メッシュなし")
	_report("反発判定サイズ", collision_ok,
		"半径 %.2f / 高さ %.2f" % [hit.radius, hit.height] if hit else "判定なし")
	await get_tree().process_frame
	var bounce_visual := sample.get_node_or_null("Visual/BounceVisual") as Node3D if sample else null
	if hit_area:
		hit_area.call("_squash")
	_report("潰し演出の対象取得", hit_area != null and hit_area.get("_mesh") == bounce_visual,
		"BounceVisualを参照")
	var compressed_scale := bounce_visual.scale if bounce_visual else Vector3.ZERO
	var compressed := (bounce_visual != null and bounce_visual.scale.x > 1.05
		and bounce_visual.scale.y < 0.95)
	await get_tree().create_timer(0.45).timeout
	var restored_scale := bounce_visual.scale if bounce_visual else Vector3.ZERO
	var restored := bounce_visual != null and bounce_visual.scale.is_equal_approx(Vector3.ONE)
	_report("潰れて戻る演出", compressed and restored,
		"圧縮 %s / 復元 %s" % [compressed_scale, restored_scale])
	root.queue_free()


func _run_cases(bumper: Area3D, body: CharacterBody3D) -> void:
	var direction := Vector3.RIGHT
	var tangent := Vector3.FORWARD
	await _hit(bumper, body, "正面", direction * 1.0, -direction * 8.0, direction)
	await _hit(bumper, body, "低速", direction * 1.0, -direction * 1.0, direction)
	await _hit(bumper, body, "斜め", direction * 1.0,
		-direction * 8.0 + tangent * 3.0, direction)
	await _hit(bumper, body, "ダッシュボード後", direction * 1.0,
		-direction * 8.0, direction, true)
	# 真上は水平の接触位置が中心になる。実装どおり FORWARD へ逃がす。
	await _hit(bumper, body, "真上", Vector3(0.0, 3.0, 0.0),
		Vector3(0.0, -4.0, 0.0), Vector3.FORWARD)


## Bumper._on_body_entered は Area3D のシグナルから呼ばれる本体処理。
## ここでは接触位置と接触直前の速度を固定して直接呼び、接触後の値を検証する。
func _hit(bumper: Area3D, body: CharacterBody3D, case_name: String, position: Vector3,
		incoming: Vector3, expected_away: Vector3, with_boost := false) -> void:
	body.global_position = position
	body.velocity = incoming
	if with_boost:
		# ダッシュボードの蹴り出しと加速中でも、バンパーの反動を保持できること。
		body.call("apply_boost", 1.6, 2.5, -expected_away * 4.0)
	bumper.call("_on_body_entered", body)
	var horizontal := Vector3(body.velocity.x, 0.0, body.velocity.z)
	var horizontal_speed := horizontal.length()
	var outward_speed := horizontal.dot(expected_away)
	var launch_y := body.velocity.y
	var immediate_ok := is_equal_approx(horizontal_speed, PUSH) \
		and is_equal_approx(outward_speed, PUSH) \
		and is_equal_approx(launch_y, LIFT)
	await get_tree().physics_frame
	var after_frame := Vector3(body.velocity.x, 0.0, body.velocity.z)
	var held_ok := is_equal_approx(after_frame.length(), PUSH) \
		and is_equal_approx(after_frame.dot(expected_away), PUSH) \
		and float(body.get("bumper_bounce_left")) > 0.0
	var passed := immediate_ok and held_ok
	var detail := "水平 %.2f / 外向き %.2f / 上向き %.2f" % [
		horizontal_speed, outward_speed, launch_y]
	_report("%s: %s" % [body.name, case_name], passed, detail)


func _report(what: String, passed: bool, detail: String) -> void:
	print("  %s  %s (%s)" % [what, "OK" if passed else "FAIL", detail])
	if not passed:
		_failures += 1
