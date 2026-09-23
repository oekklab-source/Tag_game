extends Panel

## C-07 T-5: アクションボタン(ダッシュ/ダイブ/アイテム使用/カモン)。単一スクリプトを
## touch_controls.tscn 内の4インスタンスにアタッチし、export var action_name で役割を渡す。
## virtual_joystick.gd と同じ生タッチイベント方式(合成マウス不使用)で、矩形内かつ
## 未捕捉(自分がまだ指を捕まえていない)のタッチだけを自前で掴む
## (touch_look_zone.gd のような is_input_handled() 依存の「取りこぼし回収」はしない)。
##
## 共通press/releaseロジック: dashはplayer.gdでInput.is_action_pressed()を毎フレーム
## 読む(ホールド系)。dive/use_itemはis_action_just_pressed()で1回だけ読む(タップ系、
## 押しっぱなし中action_pressed状態が続いても実害なし)。どちらも「押下でaction_press、
## 離してaction_release」で足りるため、この2種は指を置いた瞬間に押下扱いにする。
## emote(カモン)だけは長押し判定が終わるまで確定しないため例外的に離した瞬間に確定する
## (下記参照)。
##
## [node順の制約] touch_look_zone.gd は「まだ誰にも捕まっていない指」を画面全域どこでも
## 拾う取りこぼし回収役で、本ノードの矩形は除外していない。Godot4の_input()は逆深さ優先
## (後の兄弟が先に呼ばれる、virtual_joystick.gdヘッダコメント参照)なので、本ノードは
## touch_controls.tscn内でTouchLookZoneより「後」(VirtualJoystickと同じかそれ以降)に
## 置くこと。そうしないとタップがまずTouchLookZoneに拾われ視点ドラッグ扱いになる。

@export var action_name: String = ""
@export var is_taunt_button: bool = false ## カモンボタンのみtrue。長押しサブメニューを持つ

const TAUNT_HOLD_TIME := 0.4 ## この秒数以上ホールドすると挑発サブメニューが開く

@onready var touch_controls: CanvasLayer = get_parent() as CanvasLayer
@onready var taunt_submenu: Control = $TauntSubmenu if is_taunt_button else null

var _active_finger: int = -1
var _hold_time: float = 0.0
var _submenu_open: bool = false


func _input(event: InputEvent) -> void:
	# ロビー/リザルト中などTouchControlsが非表示の間は反応しない
	# (このノード自体のvisibleは常にtrueのまま変わらないため、親を見る)。
	if not touch_controls.visible:
		return
	if event is InputEventScreenTouch:
		_on_touch(event)


func _on_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if _active_finger != -1:
			return # 既に1本捕捉中(未捕捉のみ拾う)
		if not get_global_rect().has_point(event.position):
			return
		_active_finger = event.index
		_hold_time = 0.0
		if not is_taunt_button:
			Input.action_press(action_name)
		get_viewport().set_input_as_handled()
	elif event.index == _active_finger:
		_release(event.position)
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _active_finger == -1:
		return
	if not touch_controls.visible:
		# 例: ホールド中にポーズメニューが開いてPLAYING以外へ状態遷移した場合の保険。
		# 指を離すイベントが来ない可能性があるため、ここでも強制解放する
		# (releaseとして扱わないためposition=nullで、タップ発火/サブメニュー選択はしない)。
		_release(null)
		return
	if is_taunt_button and not _submenu_open:
		_hold_time += delta
		if _hold_time >= TAUNT_HOLD_TIME:
			_open_submenu()


func _release(release_position: Variant) -> void:
	if is_taunt_button:
		if _submenu_open:
			_select_submenu(release_position)
			_close_submenu()
		elif release_position != null:
			# 短押し(サブメニューを開く前に離した): 通常の「カモン」をタップとして発火。
			# 長押し確定前はaction_pressしていないので、ここで初めて押下→即解放する。
			Input.action_press(action_name)
			Input.action_release(action_name)
	else:
		Input.action_release(action_name)
	_active_finger = -1
	_hold_time = 0.0


func _open_submenu() -> void:
	_submenu_open = true
	taunt_submenu.visible = true
	taunt_submenu.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(taunt_submenu, "modulate:a", 1.0, 0.15)


func _close_submenu() -> void:
	_submenu_open = false
	taunt_submenu.visible = false
	taunt_submenu.modulate.a = 0.0


func _select_submenu(release_position: Variant) -> void:
	if release_position == null:
		return
	for i in Player.TAUNT_STYLES.size():
		var circle: Control = taunt_submenu.get_child(i)
		if circle.get_global_rect().has_point(release_position):
			# taunt_style切替のみ(player.gdの_tick_taunt_style()がis_action_just_pressedで
			# 読む)。「カモン」自体は発火しない=挑発型を選んだだけでは呼びかけにならない。
			var taunt_action := "taunt_%d" % (i + 1)
			Input.action_press(taunt_action)
			Input.action_release(taunt_action)
			return
