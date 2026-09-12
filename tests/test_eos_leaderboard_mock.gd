extends Node

## EOS Leaderboard (Offline/Mock) 動作検証スクリプト
##
## is_eos_available == false(オフラインモック)の分岐のみを検証する。
## 実EOS認証が絡む is_eos_available == true の分岐(Developer Portalの
## Stat/Leaderboard定義に依存)は、実クレデンシャルでの検証が手動でしか
## 行えない(Phase 0/2の実績と同じ制約)ため、意図的に自動テスト対象外とする。

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
	print("【TEST】EOS Leaderboard Offline/Fallback 動作検証")
	print("==================================================")
	await get_tree().process_frame

	# EosManagerの初期化(EOS Platform setup + Connect匿名ログイン)は非同期。
	# is_eos_available が true になる経路は必ず await を経由するため、
	# ここでポーリングして待っても「既に完了済みのfalse分岐」を取りこぼす
	# 心配はない(false→trueにしか遷移しないため)
	var elapsed := 0.0
	while not EosManager.is_eos_available and elapsed < 5.0:
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2

	if EosManager.is_eos_available:
		print("EOS利用可能環境のため、オフラインモック専用の以下の検証はスキップします")
		print("(実EOSリーダーボード参照/更新を伴う検証は手動でのみ実施する方針)")
	else:
		await _test_request_leaderboard()
		await _test_upload_rating()

	print("==================================================")
	print("EOS Leaderboard Mock 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> EOS Leaderboard Mock: ALL PASSED")
	else:
		printerr("=> EOS Leaderboard Mock: SOME TESTS FAILED")
	get_tree().quit()


## モック分岐はawaitを挟まず同期的にシグナルを発火するため、
## CONNECT_ONE_SHOTで発火直後の引数をそのまま捕捉できる
func _test_request_leaderboard() -> void:
	print("\n--- [1] request_leaderboard() Offline/Fallback ---")
	var captured_entries: Array = []
	var cb := func(entries: Array) -> void:
		captured_entries.append_array(entries)
	EosManager.leaderboard_loaded.connect(cb, CONNECT_ONE_SHOT)
	EosManager.request_leaderboard()

	_assert(captured_entries.size() == 5, "モックエントリが5件返る")
	if captured_entries.size() == 5:
		var mine: Dictionary = captured_entries[3]
		_assert(mine.get("name") == ProfileManager.player_name, "4位のnameがProfileManager.player_nameと一致する")
		_assert(mine.get("score") == ProfileManager.rating, "4位のscoreがProfileManager.ratingと一致する")


func _test_upload_rating() -> void:
	print("\n--- [2] upload_rating() Offline/Fallback ---")
	var captured := {}
	var cb := func(success: bool, score: int) -> void:
		captured["success"] = success
		captured["score"] = score
	EosManager.leaderboard_score_uploaded.connect(cb, CONNECT_ONE_SHOT)
	EosManager.upload_rating(1234)

	_assert(captured.get("success") == true, "upload_rating(オフライン時)は success == true で発火する")
	_assert(captured.get("score") == 1234, "発火したscoreが引数と一致する")
