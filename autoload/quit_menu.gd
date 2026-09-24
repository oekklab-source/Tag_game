extends CanvasLayer

## Esc で開く「終わりますか？」の確認。タイトルでも対戦中でも同じものを出すので Autoload にしている。
## 通信対戦は止められないので、開いている間もゲームは進む（ポーズしない）。
## **「ポーズしない」＝ get_tree().paused も GameManager.state も変えない**ので、
## 「この確認が開いている間は反応させたくない」入力系は、状態遷移ではなく
## 下の is_open() / opened_changed を見ること（C-07 T-8。実際、タッチ操作系が
## GameManager.state_changed だけを見ていたせいで、ダイアログの裏でキャラが
## 動いてしまっていた）

## 開閉した瞬間に発火する。GameManager.state_changed は QuitMenu では発火しないため、
## 「開いている間だけ止めたい」側はこちらを購読する
signal opened_changed(is_open: bool)

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
	opened_changed.emit(true)


func close() -> void:
	# 既に閉じているなら何もしない(_unhandled_input以外からも呼ばれるため、
	# 閉→閉でシグナルが空振りするのを避ける)
	if not dim.visible:
		return
	dim.visible = false
	opened_changed.emit(false)


## この確認ダイアログが開いているか。Web＋タイトルでは open() が何もせず
## 戻る(戻る先が無いため)ので、その場合もここは false のままになる
func is_open() -> bool:
	return dim.visible


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
	return scene != null and scene.scene_file_path == NetworkManager.TITLE_SCENE
