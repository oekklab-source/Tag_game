extends Node

## Phase 2: 各種ギミック・アイテム効果検証スクリプト

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
	print("【TEST】Phase 2: 各種ギミック・アイテム効果検証")
	print("==================================================")
	await get_tree().process_frame

	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world

	for i in 30:
		await get_tree().physics_frame

	var player: CharacterBody3D = world.get_node("Players/1")

	await _test_boost_panel(player)
	await _test_spring_pad(player)
	await _test_moving_platform(player)
	await _test_question_block(player)
	await _test_banana_stun(world, player)
	await _test_placed_block(world)
	await _test_slide_oneway(player)

	print("==================================================")
	print("Phase 2 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> Phase 2: ALL PASSED")
	else:
		printerr("=> Phase 2: SOME TESTS FAILED")
	get_tree().quit()


## 1. ダッシュパネル (Boost Panel) の加速検証
func _test_boost_panel(player: CharacterBody3D) -> void:
	print("\n--- [1] ダッシュパネル (Boost Panel) ---")
	_assert(is_equal_approx(player.buffs.get_mult(&"speed"), 1.0), "適用前速度倍率 == 1.0")

	# ブースト適用: 1.6倍, 2.5秒
	var kick := Vector3(0, 0, -4.0)
	player.apply_boost(1.6, 2.5, kick)

	_assert(is_equal_approx(player.buffs.get_mult(&"speed"), 1.6), "適用後速度倍率 == 1.6")
	_assert(player.velocity.z <= -4.0, "前方キック速度付与 (vz <= -4.0)")

	# 時間経過 (2.5秒経過) でブースト解除
	player.buffs.tick(2.6)
	_assert(is_equal_approx(player.buffs.get_mult(&"speed"), 1.0), "2.5秒経過後 -> 速度倍率が 1.0 に復帰")


## 2. ジャンプ台 (Spring Pad) の打ち上げ検証
func _test_spring_pad(player: CharacterBody3D) -> void:
	print("\n--- [2] ジャンプ台 (Spring Pad) ---")
	player.global_position = Vector3(0, 0, 0)
	player.velocity = Vector3.ZERO

	# 打ち上げ: 13.0 m/s
	player.launch(Vector3(0, 13.0, 0))
	_assert(is_equal_approx(player.velocity.y, 13.0), "初速 vy == 13.0 m/s")

	# 物理フレームを経過させて頂点高度を測定
	var max_y := 0.0
	for i in 60: # 1秒間
		await get_tree().physics_frame
		if player.global_position.y > max_y:
			max_y = player.global_position.y

	# 理論上の頂点: v^2 / (2g) = 169 / (2 * 9.8) = 8.62m
	_assert(max_y > 8.0 and max_y < 9.2, "頂点到達高度 (実測: %.2f m, 理論値: 約8.6m)" % max_y)


## 3. 動く床・搬送速度 (carry_velocity) 検証
func _test_moving_platform(player: CharacterBody3D) -> void:
	print("\n--- [3] 動く床・搬送速度 (carry_velocity) ---")
	player.global_position = Vector3(0, 0, 0)
	player.velocity = Vector3.ZERO
	player.carry_velocity = Vector3(5.0, 0, 0)

	var start_x := player.global_position.x
	# 物理フレームを30フレーム (0.5秒) 回す
	for i in 30:
		player.carry_velocity = Vector3(5.0, 0, 0)
		await get_tree().physics_frame

	var dist_x := player.global_position.x - start_x
	_assert(dist_x > 2.0, "床の搬送速度でプレイヤーが運ばれる (移動量: %.2f m)" % dist_x)

	# 離脱時: carry_velocity をクリア
	player.carry_velocity = Vector3.ZERO
	await get_tree().physics_frame


## 4. ？ブロックのアイテム抽選と復活周期 (12秒) 検証
func _test_question_block(player: CharacterBody3D) -> void:
	print("\n--- [4] ？ブロック (Question Block) ---")
	var qblock: StaticBody3D = load("res://scenes/gimmicks/question_block.tscn").instantiate()
	get_tree().current_scene.add_child(qblock)
	qblock.global_position = Vector3(0, 0, 0)
	await get_tree().physics_frame

	_assert(qblock._active == true, "初期状態 -> _active == true")

	# アイテム取得
	qblock._pop(Player.Item.ROCKET, player.get_path())
	_assert(qblock._active == false, "取得後 -> _active == false (使用済)")
	_assert(player.item == Player.Item.ROCKET, "プレイヤーがロケットを取得")

	qblock.queue_free()
	await get_tree().process_frame


## 5. バナナトラップ (Banana) 踏み・転倒 (1.5秒) 検証
func _test_banana_stun(world: Node, player: CharacterBody3D) -> void:
	print("\n--- [5] バナナトラップ (Banana) ---")
	player.stun_left = 0.0
	var banana: Area3D = load("res://scenes/gimmicks/banana.tscn").instantiate()
	world.add_child(banana)
	banana.global_position = Vector3(0, 0, 0)

	# 被弾
	banana._hit(player.get_path())
	_assert(is_equal_approx(player.stun_left, 1.5), "バナナ踏み -> stun_left == 1.5s")

	# 転倒中に前進入力を試みる
	Input.action_press("move_forward")
	var p_pos := player.global_position
	for i in 10:
		await get_tree().physics_frame
	Input.action_release("move_forward")

	_assert(player.global_position.distance_to(p_pos) < 0.1, "スタン中は移動入力が無効化")

	player.stun_left = 0.0
	await get_tree().process_frame


## 6. 設置ブロック (Placed Block) の壁効果検証
func _test_placed_block(world: Node) -> void:
	print("\n--- [6] 設置ブロック (Placed Block) ---")
	var block: StaticBody3D = load("res://scenes/gimmicks/placed_block.tscn").instantiate()
	world.add_child(block)
	block.global_position = Vector3(0, 1.0, 0)

	await get_tree().physics_frame

	# コリジョンレイヤー確認 (Layer 4 = 8: Platform / 視線遮断対象)
	_assert(block.collision_layer == 8, "設置ブロックのレイヤー == 8 (Platform / 視線遮断)")

	block.queue_free()
	await get_tree().process_frame


## 7. 滑り台の逆走阻止 (One-Way Slide) 検証
func _test_slide_oneway(player: CharacterBody3D) -> void:
	print("\n--- [7] 滑り台逆走阻止 (Slide One-Way) ---")
	# 走路方向: -Z (0, 0, -1), 重力加速度: 7.0, 上限: 18.0
	# 逆向き入力: +Z (0, 0, 1) を与えた場合
	var initial_vel := Vector3(0, 0, 0)
	var slide_dir := Vector3(0, 0, -1)
	var accel := 7.0
	var cap := 18.0
	var steer := 9.0
	var input_dir := Vector3(0, 0, 1) # 逆走入力
	var min_speed := 3.5

	var result_vel := SlideMotion.step(initial_vel, 0.016, slide_dir, accel, cap, steer, input_dir, min_speed)

	# 逆走入力をしても、下り方向 (-Z) に押し戻され（vz < 0）、決して上り（vz > 0）にはならないこと
	_assert(result_vel.z < -3.0, "逆走入力時も下り方向 (-Z) へ押し戻される (vz: %.2f < -3.0)" % result_vel.z)
	_assert(result_vel.z < 0.0, "上り方向 (+Z) への登坂は完全に阻止される")
