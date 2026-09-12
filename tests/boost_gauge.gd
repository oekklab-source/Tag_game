extends Node

## ダッシュパネルの実効果時間とHUDの満タン基準が一致することを確認する。

const HUD_SCRIPT := preload("res://scenes/hud.gd")
const BOOST_PANEL_SCRIPT := preload("res://scenes/gimmicks/boost_panel.gd")

var _failures := 0


func _ready() -> void:
	var duration := float(BOOST_PANEL_SCRIPT.BOOST_TIME)
	var hud_duration := float(HUD_SCRIPT.BUFF_INFO[&"speed"][1])
	_check(is_equal_approx(hud_duration, duration), "HUDの満タン基準が実効果時間と一致")

	var buffs := BuffSet.new()
	buffs.add(&"speed", BOOST_PANEL_SCRIPT.BOOST_MULT, duration)
	_check(is_equal_approx(_gauge_fraction(buffs, hud_duration), 1.0),
		"ブースト開始時はゲージ100%")

	buffs.tick(1.0)
	_check(is_equal_approx(_gauge_fraction(buffs, hud_duration), 0.6),
		"1秒後は残り時間に応じて60%")

	buffs.add(&"speed", BOOST_PANEL_SCRIPT.BOOST_MULT, duration)
	_check(is_equal_approx(_gauge_fraction(buffs, hud_duration), 1.0),
		"効果中の再取得でゲージ100%へ戻る")

	print("=== boost gauge の結果: %s ===" % [
		"ALL OK" if _failures == 0 else "%d 件 FAIL" % _failures])
	get_tree().quit(_failures)


func _gauge_fraction(buffs: BuffSet, duration: float) -> float:
	return clampf(buffs.time_left(&"speed") / duration, 0.0, 1.0)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("OK: ", label)
	else:
		_failures += 1
		print("FAIL: ", label)
