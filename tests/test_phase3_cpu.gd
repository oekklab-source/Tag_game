extends Node

## Phase 3: CPU Hunter AI 自律行動検証スクリプト

var passed_count := 0
var failed_count := 0

func _assert(condition: bool, msg: String) -> void:
	if condition:
		print("  [OK] %s" % msg)
		passed_count += 1
	else:
		printerr("  [FAIL] %s" % msg)
		failed_count += 1


func _ready() -> void:
	print("==================================================")
	print("【TEST】Phase 3: CPU Hunter AI 自律行動検証")
	print("==================================================")
	await get_tree().process_frame

	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world

	for i in 30:
		await get_tree().physics_frame

	var cpu: CharacterBody3D = load("res://scenes/cpu_hunter.tscn").instantiate()
	cpu.name = "TestCPU"
	world.get_node("Players").add_child(cpu)
	cpu.global_position = Vector3(0, 0, 10)

	for i in 10:
		await get_tree().physics_frame

	await _test_ai_state_transitions(world, cpu)
	await _test_cpu_stun_trap(cpu)
	await _test_cpu_navigation(cpu)

	cpu.queue_free()

	print("==================================================")
	print("Phase 3 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> Phase 3: ALL PASSED")
	else:
		printerr("=> Phase 3: SOME TESTS FAILED")
	get_tree().quit()


## 1. CPU AI の状態遷移 (PATROL -> INVESTIGATE -> CHASE)
func _test_ai_state_transitions(world: Node, cpu: CharacterBody3D) -> void:
	print("\n--- [1] CPU AI 状態遷移 ---")
	# Runner を壁の奥 (見えない位置: ゾーン1の奥) に配置
	var spawns: Dictionary = {1: Vector3(0, 2, -60)}
	GameManager._start_round(1, 1.0, spawns)
	GameManager.head_start_left = 0.0 # ヘッドスタート解除

	var runner: CharacterBody3D = world.get_node("Players/1")
	runner.global_position = Vector3(0, 2, -60)

	# (a) 情報なし (見失って20秒経過) -> PATROL (0)
	GameManager._set_intel(-1, 0.0, false)
	GameManager._seer_ids.clear()
	for i in 5:
		await get_tree().physics_frame

	_assert(cpu._mind == 0, "情報なし (遮蔽あり) -> PATROL (Mind=0)")

	# (b) ゾーン通報あり (未視認) -> INVESTIGATE (1)
	GameManager._set_intel(4, 20.0, false)
	for i in 5:
		await get_tree().physics_frame

	_assert(cpu._mind == 1, "ゾーン通報あり (未視認) -> INVESTIGATE (Mind=1)")

	# (c) Runner を CPU の正面 10m (視界内) に移動 -> 自動視認で CHASE (2) に遷移
	runner.global_position = cpu.global_position + Vector3(0, 0, -10)
	for i in 10:
		await get_tree().physics_frame

	_assert(cpu._mind == 2, "目視視認時 -> CHASE (Mind=2)")


## 2. CPU のトラップ反応 (バナナ踏み・スタン)
func _test_cpu_stun_trap(cpu: CharacterBody3D) -> void:
	print("\n--- [2] CPU のバナナトラップ反応 ---")
	cpu.stun_left = 0.0
	cpu.apply_stun(1.5)

	_assert(is_equal_approx(cpu.stun_left, 1.5), "CPU バナナ被弾 -> stun_left == 1.5s")

	# スタン中の移動停止を確認
	var start_p := cpu.global_position
	for i in 10:
		await get_tree().physics_frame

	_assert(cpu.global_position.distance_to(start_p) < 0.1, "スタン中 CPU は移動停止")

	cpu.stun_left = 0.0
	await get_tree().process_frame


## 3. CPU のナビゲーション移動 (PATROL自律走行)
func _test_cpu_navigation(cpu: CharacterBody3D) -> void:
	print("\n--- [3] CPU のナビゲーション自律走行 ---")
	GameManager.head_start_left = 0.0
	GameManager._set_intel(-1, 0.0, false)
	GameManager._seer_ids.clear()

	cpu.global_position = Vector3(0, 0, 0)
	cpu._repath_timer = 0.0
	cpu._goal_timer = 0.0

	var initial_pos := cpu.global_position
	# 60フレーム (1秒) 走行させる
	for i in 60:
		await get_tree().physics_frame

	var moved := cpu.global_position.distance_to(initial_pos)
	_assert(moved > 2.0, "CPU が巡回目標へ向かって自律移動 (移動量: %.2f m > 2.0m)" % moved)
