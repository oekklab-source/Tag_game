extends Node

## Phase 6: ネットワーク異常系・切断検証スクリプト

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
	print("【TEST】Phase 6: ネットワーク異常系・切断検証")
	print("==================================================")
	await get_tree().process_frame

	await _test_lobby_disconnect()
	await _test_runner_disconnect_during_round()
	await _test_version_mismatch()

	print("==================================================")
	print("Phase 6 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> Phase 6: ALL PASSED")
	else:
		printerr("=> Phase 6: SOME TESTS FAILED")
	get_tree().quit()


## 1. ロビー待機中のプレイヤー切断処理
func _test_lobby_disconnect() -> void:
	print("\n--- [1] ロビー待機中の切断・立候補リセット ---")
	GameManager.reset()
	GameManager.wanted_runner = 42
	GameManager.peer_profiles[42] = {"name": "Player42", "rating": 1500}

	_assert(GameManager.wanted_runner == 42, "立候補者 == 42")
	_assert(GameManager.peer_profiles.has(42), "peer_profiles に 42 が存在")

	# プレイヤー 42 が切断
	GameManager.on_player_left(42)

	_assert(GameManager.wanted_runner == -1, "立候補者が切断 -> wanted_runner が -1 (未定) に安全リセット")
	_assert(not GameManager.peer_profiles.has(42), "peer_profiles から 42 が削除")


## 2. ラウンド中の逃走者 (Runner) 切断処理
func _test_runner_disconnect_during_round() -> void:
	print("\n--- [2] ラウンド中の逃走者切断 (RUNNER_LEFT) ---")
	var spawns: Dictionary = {42: Vector3.ZERO}
	GameManager._start_round(42, 1.0, spawns)
	GameManager.head_start_left = 0.0

	_assert(GameManager.state == GameManager.State.PLAYING, "ゲーム中 -> PLAYING")
	_assert(GameManager.runner_id == 42, "Runner ID == 42")

	# Runner が切断
	GameManager.on_player_left(42)

	_assert(GameManager.state == GameManager.State.RESULT, "Runner切断後 -> RESULT 状態へ遷移")
	_assert(GameManager.result_reason == GameManager.EndReason.RUNNER_LEFT, "終了理由 -> RUNNER_LEFT (不戦勝)")


## 3. プロトコルバージョン不一致ハンドシェイク
func _test_version_mismatch() -> void:
	print("\n--- [3] プロトコルバージョン不一致 ---")
	GameManager.reset()
	# バージョン不一致の通知をシミュレート
	GameManager.notify_host("参加者のビルドが違います")

	_assert(GameManager.peer_notice != "", "バージョン不一致 -> peer_notice に警告が表示")
	_assert(GameManager._peer_notice_left == 20.0, "警告のタイマーが 20.0s にセット")
