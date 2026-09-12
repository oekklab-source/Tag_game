extends Node

## Esc の終了確認メニュー（autoload/quit_menu）の開閉を検証する。
##
##   godot --headless --path . res://tests/quit_menu.tscn
##   godot --path . res://tests/quit_menu.tscn -- --shots tests/shots/quit_menu
##
## 「はい」は本当に終了してしまうので押さない。つながっていることだけ見る

var _fail := 0


func _ready() -> void:
	print("=== 終了確認メニューの検証 ===")
	var shots := ""
	var args := OS.get_cmdline_user_args()
	var i := args.find("--shots")
	if i >= 0 and i + 1 < args.size():
		shots = args[i + 1]
		DirAccess.make_dir_recursive_absolute(shots)
	# _ready() の最中は root が子を追加中で add_child できない
	await get_tree().process_frame

	var title: Node = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child(title)
	get_tree().current_scene = title
	await get_tree().process_frame

	_ok("最初は閉じている", not QuitMenu.dim.visible)
	await _press_esc()
	_ok("Esc で開く", QuitMenu.dim.visible)
	_ok("文言が「ゲームを終わりますか？」", QuitMenu.question.text == "ゲームを終わりますか？",
		QuitMenu.question.text)
	_ok("マウスが見える", Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)
	_ok("既定のフォーカスは「いいえ」", QuitMenu.no_button.has_focus())
	_ok("「はい」が終了処理につながっている",
		QuitMenu.yes_button.pressed.is_connected(QuitMenu._on_yes_pressed))
	if not shots.is_empty():
		await _shot(shots, "quit_menu")

	await _press_esc()
	_ok("もう一度 Esc で閉じる", not QuitMenu.dim.visible)

	await _press_esc()
	QuitMenu.no_button.pressed.emit()
	_ok("「いいえ」で閉じる", not QuitMenu.dim.visible)
	# 押しっぱなしの自動リピートで開閉がばたつかないこと
	await _press_esc(true)
	_ok("キーリピートでは開かない", not QuitMenu.dim.visible)

	print("=== %s ===" % ("すべての検証に合格しました" if _fail == 0
		else "%d 件の検証に失敗しました" % _fail))
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(label: String, cond: bool, extra := "") -> void:
	if not cond:
		_fail += 1
	print("  %s: %s%s" % [label, "OK" if cond else "FAIL",
		"" if extra.is_empty() else "  (%s)" % extra])


## 実キーと同じ経路（InputMap の ui_cancel 判定）を通すため、アクションではなくキーを流す
func _press_esc(echo := false) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = KEY_ESCAPE
		ev.physical_keycode = KEY_ESCAPE
		ev.pressed = pressed
		ev.echo = echo and pressed
		Input.parse_input_event(ev)
		await get_tree().process_frame
		await get_tree().process_frame


func _shot(out: String, name: String) -> void:
	for i in 4:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [out, name])
	print("saved %s.png" % name)
