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
	_refresh_visibility()


func _on_state_changed(_new_state: int) -> void:
	_refresh_visibility()


func _refresh_visibility() -> void:
	visible = (
		SettingsManager.should_show_touch_controls()
		and GameManager.state == GameManager.State.PLAYING)


func _on_pause_pressed() -> void:
	QuitMenu.open()
