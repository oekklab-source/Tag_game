extends Control

## C-07 T-4: タッチドラッグ視点操作。
## virtual_joystick.gd と同じ生タッチイベント方式(合成マウス不使用)。ただしベース円のような
## 当たり判定は無く画面全域が対象。InputEventScreenDrag の event.relative を
## player.gd の apply_look_delta() へそのまま渡すだけ(感度計算はplayer.gd側に一本化)。
##
## ノード順(virtual_joystick.gd のヘッダコメント参照): Godot4の _input() は逆深さ優先
## (後の兄弟が先)で呼ばれるため、本ノードは touch_controls.tscn 内で VirtualJoystick より
## 「前」(兄弟リストで上)に置くこと。そうすることで VirtualJoystick が先に _input() を受け取り
## 円内のタッチを set_input_as_handled() できる。本ノードはその後に呼ばれ、
## get_viewport().is_input_handled() が false の指(=誰にも捕まっていない指)だけを拾う。
##
## [PauseButtonとの矩形重なりに注意]
## 本ノードは画面全域を覆う初めてのタッチ要素で、左上のPauseButton(T-2)と物理的に重なる。
## mouse_filter=IGNORE(touch_controls.tscn側で設定)に加え、ここでも矩形を明示除外する
## 二重防御にしている(タッチのGUI合成マウス経路とrawタッチ経路のどちらが優先されるか
## ドキュメントで断定できないため)。

@onready var touch_controls: CanvasLayer = get_parent() as CanvasLayer

var _active_finger: int = -1
var _local_player: Player = null


func _input(event: InputEvent) -> void:
	if not touch_controls.visible:
		return
	if event is InputEventScreenTouch:
		_on_touch(event)
	elif event is InputEventScreenDrag:
		_on_drag(event)


func _on_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if get_viewport().is_input_handled():
			return # VirtualJoystick等が既に捕まえた指
		if _active_finger != -1:
			return # 既に1本捕捉中(未捕捉のみ拾う)
		if touch_controls.pause_button.get_global_rect().has_point(event.position):
			return # PauseButtonとの矩形重なりの明示除外(ヘッダコメント参照)
		_active_finger = event.index
		get_viewport().set_input_as_handled()
	elif event.index == _active_finger:
		_active_finger = -1
		get_viewport().set_input_as_handled()


func _on_drag(event: InputEventScreenDrag) -> void:
	if event.index != _active_finger:
		return
	var player := _get_local_player()
	if player != null:
		player.apply_look_delta(event.relative)
	get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if _active_finger != -1 and not touch_controls.visible:
		# 例: ドラッグ中にポーズメニューが開いてPLAYING以外へ状態遷移した場合の保険。
		# 指を離すイベントが来ない可能性があるため、ここでも強制解放する。
		_active_finger = -1


func _get_local_player() -> Player:
	if is_instance_valid(_local_player):
		return _local_player
	var my_name := str(multiplayer.get_unique_id())
	for p in get_tree().get_nodes_in_group("players"):
		if p.name == my_name:
			_local_player = p
			return p
	return null
