extends Node

## C-07 T-8: タッチ操作UIの「出していい/いけない」条件の回帰テスト。
##
## 実行方法:
##   pwsh tools/run_headless_test.ps1 res://tests/touch_controls_pause.tscn
##
## ここで守りたいのは RV-06 の再発防止:
## autoload/quit_menu.gd は **ポーズしない**(get_tree().paused も GameManager.state も
## 変えない)ため、TouchControls が GameManager.state_changed だけを見ていると
## 確認ダイアログの裏で移動・視点回転・ダッシュが発火してしまう。
## 配下の virtual_joystick / touch_look_zone / touch_action_button はいずれも
## 親 CanvasLayer の visible だけを見て _input() を処理するので、
## 「親の visible が正しく落ちること」を押さえれば3つまとめて担保できる。
##
## アンカーの実配置(RV-05)は headless ではビューポート寸法が信用できないため、
## tests/uishot.tscn(windowed)の touch_landscape / touch_portrait で見る。

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
	print("【TEST】C-07 T-8: タッチUIの可視条件とポーズ中の入力封鎖")
	print("==================================================")
	await get_tree().process_frame

	var prev_mode: String = SettingsManager.touch_controls_mode
	var prev_state: int = GameManager.state

	SettingsManager.touch_controls_mode = "on"
	GameManager.state = GameManager.State.PLAYING
	var touch: CanvasLayer = load("res://scenes/hud/touch_controls.tscn").instantiate()
	get_tree().root.add_child(touch)
	await get_tree().process_frame

	_assert(touch.visible, "タッチON + PLAYING + ポーズ閉 -> 表示")

	QuitMenu.open()
	await get_tree().process_frame
	_assert(QuitMenu.is_open(), "QuitMenu.is_open() が開いている間 true")
	_assert(not touch.visible, "ポーズ中はTouchControlsが非表示(RV-06の再発防止)")

	QuitMenu.close()
	await get_tree().process_frame
	_assert(not QuitMenu.is_open(), "QuitMenu.is_open() が閉じたら false")
	_assert(touch.visible, "ポーズを閉じると表示に戻る")

	# 状態遷移による従来の出し分けも壊れていないこと
	GameManager.state = GameManager.State.RESULT
	GameManager.state_changed.emit(GameManager.state)
	await get_tree().process_frame
	_assert(not touch.visible, "PLAYING以外では非表示(従来動作)")
	GameManager.state = GameManager.State.PLAYING
	GameManager.state_changed.emit(GameManager.state)
	await get_tree().process_frame

	# 設定OFFなら状態に関わらず出さない
	SettingsManager.touch_controls_mode = "off"
	touch._refresh_visibility()
	_assert(not touch.visible, "設定OFFならPLAYINGでも非表示")
	SettingsManager.touch_controls_mode = "on"
	touch._refresh_visibility()

	# opened_changed が開閉の瞬間にだけ発火すること(閉→閉の空振りを作らない)
	var emits := {"n": 0}
	var cb := func(_o: bool) -> void: emits["n"] += 1
	QuitMenu.opened_changed.connect(cb)
	QuitMenu.close() # 既に閉じている
	_assert(emits["n"] == 0, "閉→閉では opened_changed が発火しない")
	QuitMenu.open()
	QuitMenu.close()
	_assert(emits["n"] == 2, "開→閉で2回だけ発火する")
	QuitMenu.opened_changed.disconnect(cb)

	# RV-15: TauntSubmenu の子が TAUNT_STYLES より少なくても範囲外アクセスしない
	var emote: Node = touch.get_node("ActionEmote")
	var submenu: Control = emote.get_node("TauntSubmenu")
	_assert(submenu.get_child_count() == Player.TAUNT_STYLES.size(),
		"TauntSubmenuの子とTAUNT_STYLESは現状同数")
	var removed: Node = submenu.get_child(submenu.get_child_count() - 1)
	submenu.remove_child(removed)
	emote._select_submenu(Vector2(-9999, -9999)) # どの円にも当たらない位置
	_assert(true, "子が足りなくても _select_submenu() が範囲外で落ちない(RV-15)")
	submenu.add_child(removed)

	touch.queue_free()
	SettingsManager.touch_controls_mode = prev_mode
	GameManager.state = prev_state
	await get_tree().process_frame

	print("==================================================")
	print("touch_controls_pause 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> touch_controls_pause: ALL PASSED")
	else:
		printerr("=> touch_controls_pause: SOME TESTS FAILED")
	get_tree().quit(1 if failed_count > 0 else 0)
