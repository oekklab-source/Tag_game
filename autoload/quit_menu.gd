extends CanvasLayer

## Esc で開く「終わりますか？」の確認。タイトルでも対戦中でも同じものを出すので Autoload にしている。
## 通信対戦は止められないので、開いている間もゲームは進む（ポーズしない）

@onready var dim: ColorRect = $Dim
@onready var question: Label = $Dim/Center/Box/Col/Question
@onready var yes_button: Button = $Dim/Center/Box/Col/Buttons/YesButton
@onready var leave_match_button: Button = $Dim/Center/Box/Col/Buttons/LeaveMatchButton
@onready var no_button: Button = $Dim/Center/Box/Col/Buttons/NoButton


func _ready() -> void:
	yes_button.pressed.connect(_on_yes_pressed)
	leave_match_button.pressed.connect(_on_leave_match_pressed)
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
	# H-06: 「アプリを終了」と「試合だけ退出してタイトルへ」を分離。試合中でなければ
	# 戻る先が無い(既にタイトル)ので出さない
	leave_match_button.visible = NetworkManager.mode != NetworkManager.Mode.NONE
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


## H-06: アプリは終了せず、試合だけ抜けてタイトルへ戻る
func _on_leave_match_pressed() -> void:
	close()
	NetworkManager.leave()


func _on_title() -> bool:
	var scene := get_tree().current_scene
	return scene != null and scene.scene_file_path == NetworkManager.MAIN_SCENE
