extends Node

## C-03 R-6: ranking_dialog.gd の純粋関数(convert_rating_api_entries)を
## ネットワーク無しで直接検証するスクリプト

const RankingDialogScript := preload("res://scenes/ranking_dialog.gd")

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
	print("【TEST】C-03 R-6: ranking_dialog.gd 純粋関数検証")
	print("==================================================")

	_test_convert_rating_api_entries()
	_test_convert_rating_api_entries_empty()

	print("==================================================")
	print("test_ranking_leaderboard_source 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> test_ranking_leaderboard_source: ALL PASSED")
	else:
		printerr("=> test_ranking_leaderboard_source: SOME TESTS FAILED")
	get_tree().quit()


func _test_convert_rating_api_entries() -> void:
	print("\n--- convert_rating_api_entries() ---")
	var raw := [
		{"rank": 1, "puid": "p1", "rating": 2100, "tier_id": "master", "tier_name": "マスター", "matches_played": 30},
		{"rank": 2, "puid": "p2", "rating": 1980, "tier_id": "diamond", "tier_name": "ダイヤ", "matches_played": 12},
	]
	var result: Array = RankingDialogScript.convert_rating_api_entries(raw)

	_assert(result.size() == 2, "件数がそのまま渡る(2件)")
	if result.size() == 2:
		var e0: Dictionary = result[0]
		_assert(e0.get("rank") == 1, "rankがそのまま渡る")
		_assert(e0.get("puid") == "p1", "puidがそのまま渡る")
		_assert(e0.get("score") == 2100, "scoreはratingフィールドから変換される")
		_assert(e0.get("name") == "Player", "nameはEOS経路と同じ汎用\"Player\"固定になる")
		var e1: Dictionary = result[1]
		_assert(e1.get("rank") == 2, "2件目のrankもそのまま渡る")
		_assert(e1.get("score") == 1980, "2件目のscoreもratingフィールドから変換される")


func _test_convert_rating_api_entries_empty() -> void:
	print("\n--- convert_rating_api_entries() 空配列 ---")
	var result: Array = RankingDialogScript.convert_rating_api_entries([])
	_assert(result.is_empty(), "空配列を渡すと空配列を返す")
