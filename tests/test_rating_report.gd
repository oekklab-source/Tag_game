extends Node

## C-03 R-3: rating_report.gd の純粋関数(should_report/build_hunter_puids)を
## ネットワーク無しで直接検証するスクリプト

const RatingReportScript := preload("res://autoload/game/rating_report.gd")

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
	print("【TEST】C-03 R-3: rating_report.gd 純粋関数検証")
	print("==================================================")

	_test_should_report()
	_test_build_hunter_puids()

	print("==================================================")
	print("test_rating_report 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> test_rating_report: ALL PASSED")
	else:
		printerr("=> test_rating_report: SOME TESTS FAILED")
	get_tree().quit()


func _test_should_report() -> void:
	print("\n--- should_report() ---")
	var TIME_UP := GameManager.EndReason.TIME_UP
	var TAGGED := GameManager.EndReason.TAGGED
	var RUNNER_LEFT := GameManager.EndReason.RUNNER_LEFT

	_assert(RatingReportScript.should_report(false, TAGGED, 5) == false,
		"非ランク(round_is_ranked=false) -> false")
	_assert(RatingReportScript.should_report(true, RUNNER_LEFT, 5) == false,
		"RUNNER_LEFT -> false(切断ペナルティ経路と二重処理を避ける)")
	_assert(RatingReportScript.should_report(true, TAGGED, -1) == false,
		"TAGGED + tagger_id=-1(CPU鬼タッチ) -> false(既知の制約)")
	_assert(RatingReportScript.should_report(true, TAGGED, 5) == true,
		"TAGGED + 有効なtagger_id -> true")
	_assert(RatingReportScript.should_report(true, TIME_UP, -1) == true,
		"TIME_UP(タッチ判定不要) -> true")


func _test_build_hunter_puids() -> void:
	print("\n--- build_hunter_puids() ---")
	var profiles_missing_puid := {2: {"puid": "p2"}, 3: {}}
	_assert(RatingReportScript.build_hunter_puids(profiles_missing_puid, [2, 3]) == null,
		"参加者にpuid空(EOS未接続)がいる -> null")

	var profiles_ok := {2: {"puid": "p2"}, 3: {"puid": "p3"}}
	var result: Array = RatingReportScript.build_hunter_puids(profiles_ok, [3, 2])
	_assert(result == ["p2", "p3"], "peer_id昇順で整列される([3,2]入力 -> [p2,p3])")

	var empty_result: Array = RatingReportScript.build_hunter_puids({}, [])
	_assert(empty_result == [], "鬼が0人でも空配列を返す(nullにしない)")
