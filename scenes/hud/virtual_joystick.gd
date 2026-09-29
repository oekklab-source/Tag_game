extends Control

## C-07 T-3: 仮想スティック(移動)。
## 生タッチイベント方式(合成マウス不使用)。InputEventScreenTouch/InputEventScreenDrag を
## _input() で直接処理し、_stick_vec を move_left/move_right/move_forward/move_back の
## 4アクションへ Input.action_press()/action_release() で変換する。player.gd 側は
## Input.get_vector("move_left","move_right","move_forward","move_back") を読むだけなので
## 無改修で動く(既存 deadzone:0.2 もそのまま効く)。
##
## 自分自身(Panel)がベース円の見た目も兼ね、子Knob(Panel)がノブの見た目を兼ねる
## (PauseButtonと同じ「1ノード=見た目+ロジック」方式)。中心・半径は touch_controls.tscn
## 側のアンカー/オフセットで決まる(1920x1080基準で直径200、中心(140,940))。
##
## [重要・将来セッションへの申し送り]
## Godot 4の _input()/_unhandled_input() はシーンツリーを「逆深さ優先」
## (後から追加された兄弟ほど先)で呼ばれる(公式ドキュメント "Using InputEvent":
## reverse depth-first order, starting with the node at the bottom of the scene tree)。
## つまり本ノードより後の兄弟の方が本ノードより先に _input() を受け取る。
## T-4(touch_look_zone.gd)は「まだ誰にも捕まっていない指」だけを拾う設計
## (get_viewport().is_input_handled() を見る)なので、本ノードが先に捕まえて
## set_input_as_handled() を呼べる必要がある。
## → T-4/T-5で is_input_handled() に依存するノードは、本ノードより「前」
## (兄弟リストで上、インデックスが小さい位置)に挿入すること。末尾に追加すると
## 本ノードより先に _input() が呼ばれてしまい、ベース円内のタッチを奪われる。
## (ロードマップ本文のT-4節は逆に書かれているが、上記の理由により実装時に訂正すること)

const MAX_RADIUS := 100.0 ## ベース円半径=捕捉ヒット半径=ドラッグ最大クランプ半径(px、1920x1080基準)
const ACTIONS := ["move_left", "move_right", "move_forward", "move_back"]

@onready var knob: Panel = $Knob
## CanvasLayerはCanvasItemではないため is_visible_in_tree() では
## TouchControls.visible=false を検出できない。親を直接参照して見る。
@onready var touch_controls: CanvasLayer = get_parent() as CanvasLayer

var _active_finger: int = -1
var _stick_vec := Vector2.ZERO
var _knob_rest_position: Vector2


func _ready() -> void:
	_knob_rest_position = knob.position


func _input(event: InputEvent) -> void:
	# ロビー/リザルト中などTouchControlsが非表示の間は反応しない
	# (このノード自体のvisibleは常にtrueのまま変わらないため、親を見る)。
	if not touch_controls.visible:
		return
	if event is InputEventScreenTouch:
		_on_touch(event)
	elif event is InputEventScreenDrag:
		_on_drag(event)


func _on_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if _active_finger != -1:
			return # 既に1本捕捉中(未捕捉のみ拾う)
		var center := _base_center()
		if event.position.distance_to(center) > MAX_RADIUS:
			return # ベース円外は無視して他へ素通りさせる
		_active_finger = event.index
		_update_stick(event.position, center)
		get_viewport().set_input_as_handled()
	elif event.index == _active_finger:
		_force_release()
		get_viewport().set_input_as_handled()


func _on_drag(event: InputEventScreenDrag) -> void:
	if event.index != _active_finger:
		return
	_update_stick(event.position, _base_center())
	get_viewport().set_input_as_handled()


func _base_center() -> Vector2:
	# event.position は canvas_items+expand ストレッチ済みのビューポート座標系
	# (Controlのanchor/offsetと同じ空間)。global_positionもTouchControlsに
	# 変形が無いため同じ空間なので、そのまま距離比較できる。
	return global_position + size * 0.5


func _update_stick(touch_position: Vector2, center: Vector2) -> void:
	var offset := touch_position - center
	if offset.length() > MAX_RADIUS:
		offset = offset.normalized() * MAX_RADIUS
	_stick_vec = offset / MAX_RADIUS # 正規化(各軸-1.0〜1.0、合成長は最大1.0)
	knob.position = _knob_rest_position + offset


func _process(_delta: float) -> void:
	if _active_finger == -1:
		return
	if not touch_controls.visible:
		# ドラッグ中に TouchControls が消えた場合の保険。
		# 起こる経路は (a) ラウンドが終わって PLAYING 以外へ状態遷移した、
		# (b) ポーズ(QuitMenu)が開いた、の2つ。**(b)は状態遷移ではない**——
		# QuitMenu は get_tree().paused も GameManager.state も変えないので、
		# touch_controls.gd が QuitMenu.opened_changed を購読して
		# visible を落としている(C-07 T-8)。どちらの経路でも指を離すイベントは
		# 来ないので、ここで強制解放する。
		_force_release()
		return
	Input.action_press("move_right", maxf(_stick_vec.x, 0.0))
	Input.action_press("move_left", maxf(-_stick_vec.x, 0.0))
	Input.action_press("move_back", maxf(_stick_vec.y, 0.0))
	Input.action_press("move_forward", maxf(-_stick_vec.y, 0.0))


func _force_release() -> void:
	_active_finger = -1
	_stick_vec = Vector2.ZERO
	knob.position = _knob_rest_position
	for action_name in ACTIONS:
		Input.action_release(action_name)
