extends CanvasLayer

## C-07 T-2: タッチコントロール土台。現時点ではポーズボタンのみ実装。
## T-3(仮想スティック)/T-5(アクションボタン)がこの下に子ノードを追加していく前提のシーンなので、
## 削除・大規模な構造変更をせず、素直に子ノードを足していくこと。
##
## hud.gd の _ignore_mouse() は self (HUD) 配下を再帰的に MOUSE_FILTER_IGNORE 化するが、
## TouchControls は world.tscn 上で HUD の兄弟(別CanvasLayer)なのでこの再帰に一切
## 巻き込まれない。ポーズボタンは Control の既定 mouse_filter (STOP) のままでよい。

@onready var pause_button: Button = $PauseButton


func _ready() -> void:
	pause_button.pressed.connect(_on_pause_pressed)
	# hud.gdの_on_state_changed()と同じ「状態が変わった瞬間だけ処理する」方式。
	# 現状SettingsManagerに変更通知シグナルが無く、かつtouch_controls_modeを
	# PLAYING中に変更できる導線も無い(設定画面はタイトルからしか開けない)ため、
	# 毎フレームのポーリングは不要。GameManager.state_changedだけで十分
	GameManager.state_changed.connect(_on_state_changed)
	# T-8(RV-06): QuitMenuはポーズも状態遷移もしない(autoload/quit_menu.gd参照)ので、
	# state_changedだけではポーズ中もTouchControlsがvisibleのままになり、
	# ダイアログの裏で移動・視点回転・ダッシュが発火していた。専用シグナルで拾う
	QuitMenu.opened_changed.connect(_on_quit_menu_toggled)
	_refresh_visibility()


func _on_state_changed(_new_state: int) -> void:
	_refresh_visibility()


func _on_quit_menu_toggled(_is_open: bool) -> void:
	_refresh_visibility()


## 配下の virtual_joystick / touch_look_zone / touch_action_button は
## いずれもこの CanvasLayer の visible だけを見て _input() を処理するので、
## 「触らせたくない状況」はすべてここに集約する
func _refresh_visibility() -> void:
	visible = (
		SettingsManager.should_show_touch_controls()
		and GameManager.state == GameManager.State.PLAYING
		and not QuitMenu.is_open())


func _on_pause_pressed() -> void:
	QuitMenu.open()
