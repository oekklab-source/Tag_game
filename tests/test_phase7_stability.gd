extends Node

## Phase 7: 長時間連続実行・メモリ安定性検証スクリプト

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
	print("【TEST】Phase 7: 長時間連続実行・メモリ安定性検証")
	print("==================================================")
	await get_tree().process_frame

	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world

	for i in 30:
		await get_tree().physics_frame

	await _test_consecutive_rounds(world)

	print("==================================================")
	print("Phase 7 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> Phase 7: ALL PASSED")
	else:
		printerr("=> Phase 7: SOME TESTS FAILED")
	get_tree().quit()


## 10 ラウンド連続プレイ・CPU Hunter 生成/破棄・メモリ安定性の検証
func _test_consecutive_rounds(world: Node) -> void:
	print("\n--- [1] 10ラウンド連続シミュレーション ---")

	var initial_node_count := get_tree().get_node_count()
	var initial_mem := OS.get_static_memory_usage()
	print("初期ノード数: %d, 初期メモリ: %.2f MB" % [initial_node_count, float(initial_mem) / (1024.0 * 1024.0)])

	for round_num in range(1, 11):
		# 1) WAITING -> PLAYING (ソロモード開始: CPU 6体スポーン)
		GameManager.request_start_round()
		for i in 5:
			await get_tree().physics_frame

		_assert(GameManager.state == GameManager.State.PLAYING, "R%d: PLAYING 状態へ移行" % round_num)

		# 2) プレイ進行 (フレーム経過)
		for i in 10:
			await get_tree().physics_frame

		# 3) PLAYING -> RESULT (タッチ終了)
		GameManager._end_round(false, GameManager.EndReason.TAGGED)
		for i in 5:
			await get_tree().physics_frame

		_assert(GameManager.state == GameManager.State.RESULT, "R%d: RESULT 状態へ移行" % round_num)

		# 4) RESULT -> WAITING (CPU 6体が破棄される)
		GameManager._back_to_waiting()
		for i in 5:
			await get_tree().physics_frame

		_assert(GameManager.state == GameManager.State.WAITING, "R%d: WAITING 状態へ復帰" % round_num)

	# 10ラウンド完了後のリソース確認
	for i in 10:
		await get_tree().physics_frame

	var final_node_count := get_tree().get_node_count()
	var final_mem := OS.get_static_memory_usage()
	print("10R完了後ノード数: %d, 完了後メモリ: %.2f MB" % [final_node_count, float(final_mem) / (1024.0 * 1024.0)])

	# CPU Hunter が毎ラウンド完全に解放され、ノード数が初期値に戻っていること
	var node_diff := final_node_count - initial_node_count
	_assert(node_diff == 0, "10R周回後のノード増分 (差分: %d) -> CPU Hunter等の破棄漏れゼロ" % node_diff)

	# メモリ増加が 10MB 未満であること
	var mem_diff_mb := float(final_mem - initial_mem) / (1024.0 * 1024.0)
	_assert(mem_diff_mb < 10.0, "10R周回後のメモリ増加量 (%.2f MB < 10MB) -> メモリ安定" % mem_diff_mb)
