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
	# 期待値は実効果時間から求める。0.6 を直書きしていた頃は BOOST_TIME=2.5 前提で、
	# パネル側の調整のたびにテストまで書き換える必要があった
	var expected := (duration - 1.0) / duration
	_check(is_equal_approx(_gauge_fraction(buffs, hud_duration), expected),
		"1秒後は残り時間に応じて%d%%" % roundi(expected * 100.0))

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

# --- 実セーブ(user://profile.json / settings.json)とクラウドセーブの保護 ---
# ラウンドを回さないテストでも、EOS にログインできる環境では起動時のクラウドセーブ同期が
# 実セーブを書き換える(2026-09-25 に boost_panel の実行中に実測)。どのテストが
# 踏むかを個別に見極めるより、全テストで一律に挟む。詳細は tests/save_guard.gd のヘッダ。
const _SaveGuard := preload("res://tests/save_guard.gd")
var _save_backup := {}


func _enter_tree() -> void:
	_save_backup = _SaveGuard.backup()


func _exit_tree() -> void:
	_SaveGuard.restore(_save_backup)
