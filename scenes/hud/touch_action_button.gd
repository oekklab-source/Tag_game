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
## [ダッシュは切り替え式(is_toggle、2026-09-30 スマホ実機の指摘で変更)]
## 押している間だけダッシュだと、右親指がボタンに取られて視点を回せない。
## そこでタッチ操作のダッシュは「1回押すとON、もう1回でOFF」にし、ONの間は
## action_press("dash") を保つ(player.gd は Input.is_action_pressed("dash") を読むだけなので無改修)。
## 自動でOFFにするのは: スタミナ切れ(exhausted)・スティックから指を離した
## (touch_controls.gd が VirtualJoystick.released で set_toggled(false) を呼ぶ)・
## TouchControls が非表示になった、の3つ。
##
## [当たり判定] 見た目の円より hit_padding だけ広い円(is_hit())。大きさと位置は
## touch_controls.gd の _apply_layout() が dp で決める(隣のボタンと当たり判定が重ならない配置)。
##
## [node順の制約] touch_look_zone.gd は「まだ誰にも捕まっていない指」を画面全域どこでも
## 拾う取りこぼし回収役で、本ノードの矩形は除外していない。Godot4の_input()は逆深さ優先
## (後の兄弟が先に呼ばれる、virtual_joystick.gdヘッダコメント参照)なので、本ノードは
## touch_controls.tscn内でTouchLookZoneより「後」(VirtualJoystickと同じかそれ以降)に
## 置くこと。そうしないとタップがまずTouchLookZoneに拾われ視点ドラッグ扱いになる。

@export var action_name: String = ""
@export var is_taunt_button: bool = false ## カモンボタンのみtrue。長押しサブメニューを持つ
@export var is_toggle: bool = false ## ダッシュのみtrue。押すたびにON/OFF(ヘッダ参照)
## ONの間の見た目(未設定なら見た目は変えない)
@export var toggled_style: StyleBox

const TAUNT_HOLD_TIME := 0.4 ## この秒数以上ホールドすると挑発サブメニューが開く

@onready var touch_controls: CanvasLayer = get_parent() as CanvasLayer
@onready var taunt_submenu: Control = $TauntSubmenu if is_taunt_button else null

var _active_finger: int = -1
var _hold_time: float = 0.0
var _submenu_open: bool = false
var _toggled: bool = false
var _normal_style: StyleBox
## 当たり判定を見た目より広げる量(画面の座標単位)。_apply_layout() が入れる
var hit_padding := 0.0


func _ready() -> void:
	_normal_style = get_theme_stylebox("panel")


func is_toggled() -> bool:
	return _toggled


## is_toggle のボタンのON/OFF。OFFにしたときは dash を確実に離す
func set_toggled(on: bool) -> void:
	if not is_toggle or on == _toggled:
		return
	_toggled = on
	if on:
		Input.action_press(action_name)
	else:
		Input.action_release(action_name)
	if toggled_style != null:
		add_theme_stylebox_override("panel", toggled_style if on else _normal_style)


## 当たり判定は見た目と同じ円で、hit_padding だけ外側まで。矩形にしないのは、
## 扇形に並べたボタン(斜め45°のカモンとダイブ)で矩形同士だと角が重なるため
func hit_center() -> Vector2:
	return get_global_rect().get_center()


func hit_radius() -> float:
	return size.x * 0.5 + hit_padding


func is_hit(p: Vector2) -> bool:
	return p.distance_to(hit_center()) <= hit_radius()


## _apply_layout() から大きさが変わるたびに呼ぶ。StyleBoxFlat の角丸は px 指定なので、
## 通常時と ON 時の両方のスタイルを新しい大きさの真円に作り直す
func apply_round(radius: float) -> void:
	_normal_style = _rounded(_normal_style, radius)
	toggled_style = _rounded(toggled_style, radius)
	add_theme_stylebox_override("panel", toggled_style if _toggled else _normal_style)


static func _rounded(sb: StyleBox, radius: float) -> StyleBox:
	if not sb is StyleBoxFlat:
		return sb
	var flat := (sb as StyleBoxFlat).duplicate() as StyleBoxFlat
	# ちょうど半分にしない理由は touch_controls.gd の _round_panel() 参照(中央に縦線が出る)
	flat.set_corner_radius_all(int(floor(radius * 0.93)))
	return flat


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
		if not is_hit(event.position):
			return
		_active_finger = event.index
		_hold_time = 0.0
		if is_toggle:
			set_toggled(not _toggled)
		elif not is_taunt_button:
			Input.action_press(action_name)
		get_viewport().set_input_as_handled()
	elif event.index == _active_finger:
		_release(event.position)
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _toggled:
		if not touch_controls.visible:
			set_toggled(false)
		else:
			var player: Node = touch_controls.get_local_player()
			if player != null and player.exhausted:
				set_toggled(false)
	if _active_finger == -1:
		return
	if not touch_controls.visible:
		# ホールド中に TouchControls が消えた場合の保険。経路は
		# (a) PLAYING 以外への状態遷移、(b) ポーズ(QuitMenu)が開いた、の2つ。
		# (b)は状態遷移ではなく QuitMenu.opened_changed 経由で visible が落ちる
		# (C-07 T-8、詳細は virtual_joystick.gd の同じ箇所)。
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
	elif not is_toggle:
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
	# TAUNT_STYLES と TauntSubmenu の子(Taunt1..3)は現状3対3で一致しているが、
	# player.gd 側にスタイルを足した瞬間に get_child() が範囲外で落ちる。
	# 少ない方に合わせる(足りない分はシーンに円を追加するまで選べないだけ)
	var selectable := mini(Player.TAUNT_STYLES.size(), taunt_submenu.get_child_count())
	for i in selectable:
		var circle: Control = taunt_submenu.get_child(i)
		if circle.get_global_rect().has_point(release_position):
			# taunt_style切替のみ(player.gdの_tick_taunt_style()がis_action_just_pressedで
			# 読む)。「カモン」自体は発火しない=挑発型を選んだだけでは呼びかけにならない。
			var taunt_action := "taunt_%d" % (i + 1)
			Input.action_press(taunt_action)
			Input.action_release(taunt_action)
			return
