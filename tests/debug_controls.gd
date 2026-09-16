extends Node

## CPU逃走者デバッグのアイテムキーとメイン画面復帰を実入力で確認する。
##
##   godot --headless --path . res://tests/debug_controls.tscn --quit-after 600

var _fails := 0

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const HUD_SCENE := preload("res://scenes/hud.tscn")


func _ready() -> void:
	await get_tree().process_frame
	var me: Player = PLAYER_SCENE.instantiate()
	me.name = "1"
	add_child(me)
	var hud: CanvasLayer = HUD_SCENE.instantiate()
	add_child(hud)
	for i in 3:
		await get_tree().physics_frame

	GameManager.set_debug_cpu_runner(true)
	for i in 2:
		await get_tree().process_frame
	_report("デバッグモードON", GameManager.debug_cpu_runner,
		"切替が反映されていない")

	var cases := [
		["debug_give_banana", Player.Item.BANANA, KEY_R, "Rでバナナ"],
		["debug_give_block", Player.Item.BLOCK, KEY_T, "Tでブロック"],
		["debug_give_rocket", Player.Item.ROCKET, KEY_Y, "Yでロケット"],
	]
	for entry in cases:
		_report("%sのキー設定" % entry[3], _action_has_key(entry[0], entry[2]),
			"InputMapの物理キーが違う")
		await _press_key(entry[2])
		_report("%sを即時取得" % entry[3],
			me.item == entry[1] and me.item_lock == 0.0,
			"item=%d / lock=%.2f" % [me.item, me.item_lock])

	await _press_key(KEY_E)
	_report("Eで取得アイテムを使用", me.item == Player.Item.NONE,
		"使用後もスロットに残っている")
	var info := hud.get_node_or_null("InfoLabel") as Label
	_report("左下に操作説明を表示", info != null
		and info.text.contains("R バナナ") and info.text.contains("Q メイン画面"),
		"デバッグ操作の説明が表示されていない")

	GameManager.set_debug_cpu_runner(false)
	me.item = Player.Item.NONE
	await _press_key(KEY_R)
	_report("通常モードでは取得無効", me.item == Player.Item.NONE,
		"デバッグOFFでもアイテムを取得した")

	GameManager.set_debug_cpu_runner(true)
	_report("Qのキー設定", _action_has_key("debug_return_main", KEY_Q),
		"InputMapの物理キーがQではない")
	var dummy_scene := Node.new()
	get_tree().root.add_child(dummy_scene)
	get_tree().current_scene = dummy_scene
	await _press_key(KEY_Q)
	for i in 5:
		await get_tree().process_frame
	_report("Qでメイン画面へ戻る", get_tree().current_scene != null
		and get_tree().current_scene.scene_file_path == NetworkManager.MAIN_SCENE
		and NetworkManager.mode == NetworkManager.Mode.NONE,
		"メイン画面へ遷移していない")
	_report("復帰後はデバッグOFF", not GameManager.debug_cpu_runner,
		"デバッグ設定が次回へ残っている")
	_finish()


func _press_key(key: Key) -> void:
	var pressed := InputEventKey.new()
	pressed.physical_keycode = key
	pressed.pressed = true
	Input.parse_input_event(pressed)
	await get_tree().physics_frame
	var released := InputEventKey.new()
	released.physical_keycode = key
	released.pressed = false
	Input.parse_input_event(released)
	await get_tree().physics_frame


func _action_has_key(action: String, key: Key) -> bool:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey and event.physical_keycode == key:
			return true
	return false


func _report(what: String, ok: bool, why: String) -> void:
	if not ok:
		_fails += 1
	print("  %s  %s" % [what, "OK" if ok else "FAIL（%s）" % why])


func _finish() -> void:
	print("=== debug_controls の結果: %s ===" % [
		"ALL OK" if _fails == 0 else "%d 件 FAIL" % _fails])
	get_tree().quit(_fails)
