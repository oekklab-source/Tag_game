extends Node

## C-03 R-4: hud.gd/title.gd のレート同期通知(トースト/ダイアログ)文言を
## ネットワーク無しで直接検証するスクリプト

const HudScript := preload("res://scenes/hud.gd")
const TitleScript := preload("res://scenes/title.gd")

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
	print("【TEST】C-03 R-4: レート同期通知の文言検証")
	print("==================================================")

	_test_rating_sync_toast_text()
	_test_rating_sync_dialog_text()

	print("==================================================")
	print("test_rating_sync_wording 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> test_rating_sync_wording: ALL PASSED")
	else:
		printerr("=> test_rating_sync_wording: SOME TESTS FAILED")
	get_tree().quit()


func _test_rating_sync_toast_text() -> void:
	print("\n--- hud.gd.rating_sync_toast_text() ---")
	_assert(HudScript.rating_sync_toast_text(8, 1512) == "レートがサーバーと同期され、+8 Pt 補正されました（現在 1512 Pt）",
		"正の補正(+8)の文言")
	_assert(HudScript.rating_sync_toast_text(-5, 1495) == "レートがサーバーと同期され、-5 Pt 補正されました（現在 1495 Pt）",
		"負の補正(-5)の文言")
	_assert(HudScript.rating_sync_toast_text(0, 1500) == "レートがサーバーと同期され、+0 Pt 補正されました（現在 1500 Pt）",
		"差分0でも符号は+として整形される(呼び出し側がdelta!=0をガードするため実際には呼ばれない値)")


func _test_rating_sync_dialog_text() -> void:
	print("\n--- title.gd.rating_sync_dialog_text() ---")
	_assert(TitleScript.rating_sync_dialog_text(8, 1512) ==
		"前回の対戦時には確定していなかったレートがサーバーと同期され、+8 Pt 補正されました（現在 1512 Pt）。",
		"正の補正(+8)の文言")
	_assert(TitleScript.rating_sync_dialog_text(-5, 1495) ==
		"前回の対戦時には確定していなかったレートがサーバーと同期され、-5 Pt 補正されました（現在 1495 Pt）。",
		"負の補正(-5)の文言")
