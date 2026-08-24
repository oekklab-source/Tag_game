extends Node

## Phase 1: ゲームプレイ・対戦ルール検証スクリプト

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
	print("【TEST】Phase 1: ゲームプレイ・対戦ルール検証")
	print("==================================================")
	await get_tree().process_frame

	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world

	for i in 30:
		await get_tree().physics_frame

	await _test_hunter_mult()
	await _test_head_start(world)
	await _test_line_of_sight(world)
	await _test_intel_sharing(world)
	await _test_tag_catch(world)
	await _test_time_up(world)

	print("==================================================")
	print("Phase 1 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> Phase 1: ALL PASSED")
	else:
		printerr("=> Phase 1: SOME TESTS FAILED")
	get_tree().quit()


## 1. 鬼の人数別速度補正の検証
func _test_hunter_mult() -> void:
	print("\n--- [1] 鬼の人数別速度補正 (hunter_mult) ---")
	_assert(is_equal_approx(GameManager.hunter_mult_for(1), 1.0), "鬼1人 -> 100% (1.0)")
	_assert(is_equal_approx(GameManager.hunter_mult_for(2), 1.0), "鬼2人 -> 100% (1.0)")
	_assert(is_equal_approx(GameManager.hunter_mult_for(3), 0.95), "鬼3人 -> 95% (0.95)")
	_assert(is_equal_approx(GameManager.hunter_mult_for(4), 0.95), "鬼4人 -> 95% (0.95)")
	_assert(is_equal_approx(GameManager.hunter_mult_for(5), 0.90), "鬼5人 -> 90% (0.90)")
	_assert(is_equal_approx(GameManager.hunter_mult_for(8), 0.90), "鬼8人 -> 90% (0.90)")


## 2. ヘッドスタート拘束 (8秒間) の検証
func _test_head_start(world: Node) -> void:
	print("\n--- [2] ヘッドスタート拘束 (8秒) ---")
	GameManager.set_wanted_runner_to(1) # ホスト(1)がRunner
	var spawns: Dictionary = {1: Vector3.ZERO, 99: Vector3(10, 0, 10)}
	GameManager._start_round(1, 1.0, spawns)

	_assert(GameManager.state == GameManager.State.PLAYING, "ラウンド開始 -> PLAYING")
	_assert(is_equal_approx(GameManager.head_start_left, GameManager.HEAD_START), "head_start_left == 8.0s")
	_assert(GameManager.runner_id == 1, "GameManager.runner_id == 1")

	# ダミーHunterを作成
	var dummy_hunter: CharacterBody3D = load("res://scenes/player.tscn").instantiate()
	dummy_hunter.name = "99"
	world.get_node("Players").add_child(dummy_hunter)

	var hunter_start_pos := dummy_hunter.global_position
	for i in 10:
		await get_tree().physics_frame

	_assert(dummy_hunter.global_position.distance_to(hunter_start_pos) < 0.1, "ヘッドスタート中 Hunter は移動不能")

	# Runner は移動可能
	var runner: CharacterBody3D = world.get_node("Players/1")
	var runner_start_pos := runner.global_position
	Input.action_press("move_forward")
	for i in 15:
		await get_tree().physics_frame
	Input.action_release("move_forward")
	_assert(runner.global_position.distance_to(runner_start_pos) > 0.3, "ヘッドスタート中 Runner は移動可能")

	dummy_hunter.queue_free()
	await get_tree().process_frame


## 3. 索敵・視界コーン (Line of Sight) 境界値検証
func _test_line_of_sight(world: Node) -> void:
	print("\n--- [3] 索敵・視界コーン境界値 ---")
	var hunter: Node3D = load("res://scenes/player.tscn").instantiate()
	hunter.name = "SightHunter"
	world.get_node("Players").add_child(hunter)
	# ゾーン4 (中央) の原点 (0, 0, 0) に配置（十字クリアランス内）
	hunter.global_position = Vector3(0, 0, 0)
	hunter.global_transform.basis = Basis.IDENTITY # 前方は -Z

	var target: Node3D = load("res://scenes/player.tscn").instantiate()
	target.name = "SightTarget"
	world.get_node("Players").add_child(target)

	for i in 2:
		await get_tree().physics_frame

	# (a) 正面 8m (Z = -8, 十字通路内) -> 視認可
	target.global_position = Vector3(0, 0, -8)
	_assert(GameManager.can_see(hunter, target) == true, "正面 8m (視界内・遮蔽なし) -> 視認成功")

	# (b) 背後 8m (Z = +8) -> 視野外 (180°)
	target.global_position = Vector3(0, 0, 8)
	_assert(GameManager.can_see(hunter, target) == false, "背後 8m (視野外) -> 視認失敗")

	# (c) 距離 50m (Z = -50, SIGHT_RANGE 48m 超) -> 距離外
	target.global_position = Vector3(0, 0, -50)
	_assert(GameManager.can_see(hunter, target) == false, "距離 50m (48m超) -> 視認失敗")

	# (d) 水平視野角 100° (片側 50°) の境界 (8m先)
	# 40° 方向 (8m)
	var dir_40 := Vector3(sin(deg_to_rad(40)), 0, -cos(deg_to_rad(40))) * 8.0
	target.global_position = hunter.global_position + dir_40
	_assert(GameManager.can_see(hunter, target) == true, "水平 40° (50°以内) -> 視認成功")

	# 60° 方向 (8m)
	var dir_60 := Vector3(sin(deg_to_rad(60)), 0, -cos(deg_to_rad(60))) * 8.0
	target.global_position = hunter.global_position + dir_60
	_assert(GameManager.can_see(hunter, target) == false, "水平 60° (50°超過) -> 視認失敗")

	# (e) 遮蔽物の向こう側 (段差・外壁の向こう)
	hunter.global_position = Vector3(0, 0, -20)
	target.global_position = Vector3(0, 2, -60)
	_assert(GameManager.can_see(hunter, target) == false, "壁・遮蔽物の奥 -> レイ遮断で視認失敗")

	hunter.queue_free()
	target.queue_free()
	await get_tree().process_frame


## 4. ゾーン情報共有とインテル減衰検証
func _test_intel_sharing(world: Node) -> void:
	print("\n--- [4] ゾーン情報共有 & インテル減衰 ---")
	GameManager.spotted = false
	GameManager.spotted_zone = -1
	GameManager.intel_left = 0.0

	# ゾーン4(中央)で視認発生
	GameManager._set_intel(4, GameManager.INTEL_TIME, true)
	_assert(GameManager.spotted == true, "視認発生 -> spotted == true")
	_assert(GameManager.spotted_zone == 4, "目撃ゾーン -> spotted_zone == 4")
	_assert(is_equal_approx(GameManager.intel_left, GameManager.INTEL_TIME), "intel_left == 20.0s")

	# 見失う (spotted=false, spotted_zone=4 のまま減衰)
	GameManager._set_intel(4, 15.0, false)
	_assert(GameManager.spotted == false, "見失い -> spotted == false")
	_assert(GameManager.spotted_zone == 4, "ゾーン記憶維持 -> spotted_zone == 4")

	# 時間切れ
	GameManager._set_intel(-1, 0.0, false)
	_assert(GameManager.spotted_zone == -1, "20秒経過後 -> spotted_zone == -1 (NO INTEL)")


## 5. タッチ・接触判定 (Tag / Catch) 検証
func _test_tag_catch(world: Node) -> void:
	print("\n--- [5] タッチ判定 (Tag / Catch) ---")
	var spawns: Dictionary = {1: Vector3.ZERO}
	GameManager._start_round(1, 1.0, spawns)
	GameManager.head_start_left = 0.0 # ヘッドスタート解除

	var runner: CharacterBody3D = world.get_node("Players/1")
	runner.global_position = Vector3(0, 0, 0)

	# ダミーHunterをRunnerの至近（接触距離 Area3D 1.1m 以内）に生成
	var hunter: CharacterBody3D = load("res://scenes/player.tscn").instantiate()
	hunter.name = "42"
	world.get_node("Players").add_child(hunter)
	hunter.global_position = Vector3(0.3, 0, 0.3)

	# 物理フレームを回してArea3Dの衝突をトリガー
	for i in 20:
		await get_tree().physics_frame

	_assert(GameManager.state == GameManager.State.RESULT, "接触後 -> RESULT 状態へ遷移")
	_assert(GameManager.result_runner_won == false, "Hunter勝利 -> result_runner_won == false")
	_assert(GameManager.result_reason == GameManager.EndReason.TAGGED, "終了理由 -> TAGGED")
	_assert(GameManager.tagger_peer_id == 42, "捕獲者 ID == 42")

	hunter.queue_free()
	await get_tree().process_frame


## 6. 3分タイムアップ (Time Up) 逃げ切り検証
func _test_time_up(world: Node) -> void:
	print("\n--- [6] タイムアップ逃げ切り (Time Up) ---")
	var spawns: Dictionary = {1: Vector3.ZERO}
	GameManager._start_round(1, 1.0, spawns)
	GameManager.head_start_left = 0.0
	GameManager.time_left = 0.02 # 残り0.02秒に設定

	for i in 10:
		await get_tree().physics_frame

	_assert(GameManager.state == GameManager.State.RESULT, "時間切れ後 -> RESULT 状態へ遷移")
	_assert(GameManager.result_runner_won == true, "Runner勝利 -> result_runner_won == true")
	_assert(GameManager.result_reason == GameManager.EndReason.TIME_UP, "終了理由 -> TIME_UP")
