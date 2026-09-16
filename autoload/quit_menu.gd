extends CanvasLayer

## Esc で開く「終わりますか？」の確認。タイトルでも対戦中でも同じものを出すので Autoload にしている。
## 通信対戦は止められないので、開いている間もゲームは進む（ポーズしない）

@onready var dim: ColorRect = $Dim
@onready var question: Label = $Dim/Center/Box/Col/Question
@onready var yes_button: Button = $Dim/Center/Box/Col/Buttons/YesButton
@onready var no_button: Button = $Dim/Center/Box/Col/Buttons/NoButton


func _ready() -> void:
	yes_button.pressed.connect(_on_yes_pressed)
	no_button.pressed.connect(close)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	get_viewport().set_input_as_handled()
	if dim.visible:
		close()
	else:
		open()


func open() -> void:
	# ブラウザはタブを閉じられない（quit() が効かない）ので、「終わる」はタイトルへ戻ることにする。
	# タイトルにいるなら戻る先が無いので開かない
	if OS.has_feature("web"):
		if _on_title():
			return
		question.text = "タイトルにもどりますか？"
	else:
		question.text = "ゲームを終わりますか？"
	dim.visible = true
	# マウスキャプチャ中だとボタンを押せない
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# 誤って Enter で終わらないよう、既定は「いいえ」
	no_button.grab_focus()


func close() -> void:
	dim.visible = false


func _on_yes_pressed() -> void:
	close()
	if OS.has_feature("web"):
		NetworkManager.leave()
	else:
		get_tree().quit()


func _on_title() -> bool:
	var scene := get_tree().current_scene
	return scene != null and scene.scene_file_path == NetworkManager.MAIN_SCENE
