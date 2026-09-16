extends Node

## 結果画面の文言が、逃走者の勝敗だけでなく見る側の役割にも合うことを確認する。

const HUD_SCRIPT := preload("res://scenes/hud.gd")

var _failures := 0


func _ready() -> void:
	_check_case(false, true, GameManager.EndReason.TIME_UP,
		"にげきられた…", "逃げる人をつかまえられなかった", "鬼・逃げ切られた")
	_check_case(false, false, GameManager.EndReason.TAGGED,
		"つかまえた！", "逃げる人をつかまえた", "鬼・捕まえた")
	_check_case(true, true, GameManager.EndReason.TIME_UP,
		"にげきった！", "最後まで逃げきった", "逃走者・逃げ切った")
	_check_case(true, false, GameManager.EndReason.TAGGED,
		"つかまった…", "鬼につかまってしまった", "逃走者・捕まった")
	_check_case(false, false, GameManager.EndReason.RUNNER_LEFT,
		"ちゅうだん", "逃げる人が抜けました", "逃走者の途中退出")

	print("=== result copy の結果: %s ===" % [
		"ALL OK" if _failures == 0 else "%d 件 FAIL" % _failures])
	get_tree().quit(_failures)


func _check_case(is_runner: bool, runner_won: bool, reason: int,
		expected_title: String, expected_sub: String, label: String) -> void:
	var copy: PackedStringArray = HUD_SCRIPT.result_copy(is_runner, runner_won, reason)
	var ok := copy.size() == 2 and copy[0] == expected_title and copy[1] == expected_sub
	if ok:
		print("OK: ", label)
	else:
		_failures += 1
		print("FAIL: %s -> %s" % [label, copy])
