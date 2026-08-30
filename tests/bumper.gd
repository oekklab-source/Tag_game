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
