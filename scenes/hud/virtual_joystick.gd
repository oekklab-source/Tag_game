extends Control

## C-07 T-3: 仮想スティック(移動)。
## 生タッチイベント方式(合成マウス不使用)。InputEventScreenTouch/InputEventScreenDrag を
## _input() で直接処理し、_stick_vec を move_left/move_right/move_forward/move_back の
## 4アクションへ Input.action_press()/action_release() で変換する。player.gd 側は
## Input.get_vector("move_left","move_right","move_forward","move_back") を読むだけなので
## 無改修で動く(既存 deadzone:0.2 もそのまま効く)。
##
## 自分自身(Panel)がベース円の見た目も兼ね、子Knob(Panel)がノブの見た目を兼ねる
## (PauseButtonと同じ「1ノード=見た目+ロジック」方式)。
##
## [追従スティック(2026-09-30 スマホ実機の指摘で変更)]
## 大きさと置き場所は touch_controls.gd の _apply_layout() が dp(実寸)で決めて渡す
## (以前は 1920x1080 基準の固定値で、スマホでは直径約 72dp まで縮んで押しづらかった)。
## 指を置ける範囲は見た目の円ではなく capture_rect(画面左下の広い範囲)で、
## 置いた位置がそのままスティックの中心になる。離すと元の位置(rest)へ戻る。
## 画面を見ずに左親指を置いても動けるようにするため。
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

const ACTIONS := ["move_left", "move_right", "move_forward", "move_back"]

## 指を離した瞬間(強制解放を含む)。touch_controls.gd がダッシュの自動OFFに使う
signal released

## ベース円半径=ドラッグ最大クランプ半径(画面の座標単位)。_apply_layout() が dp から換算して入れる
var max_radius := 100.0
## 指を掴む範囲(画面の座標単位)。空なら見た目の円の中だけ(_apply_layout() 前の保険)
var capture_rect := Rect2()
## 指が離れているときのパネルの位置
var rest_position := Vector2.ZERO

@onready var knob: Panel = $Knob
## CanvasLayerはCanvasItemではないため is_visible_in_tree() では
## TouchControls.visible=false を検出できない。親を直接参照して見る。
@onready var touch_controls: CanvasLayer = get_parent() as CanvasLayer

var _active_finger: int = -1
var _stick_vec := Vector2.ZERO
var _knob_rest_position: Vector2


func _ready() -> void:
	_knob_rest_position = knob.position
	rest_position = position


## touch_controls.gd の _apply_layout() から呼ぶ。ドラッグ中に呼ばれても(回転など)
## 指を離したものとして扱い、新しい大きさで作り直す
func configure(radius: float, rest_center: Vector2, capture: Rect2) -> void:
	if _active_finger != -1:
		_force_release()
	max_radius = radius
	capture_rect = capture
	size = Vector2.ONE * radius * 2.0
	rest_position = rest_center - size * 0.5
	position = rest_position
	var knob_size := size * 0.42
	knob.size = knob_size
	_knob_rest_position = (size - knob_size) * 0.5
	knob.position = _knob_rest_position
	# StyleBoxFlat の角丸は px 指定なので、大きさに合わせて真円を保つ
	_set_round(self, radius)
	_set_round(knob, knob_size.x * 0.5)


static func _set_round(panel: Control, radius: float) -> void:
	var sb := panel.get_theme_stylebox("panel")
	if sb is StyleBoxFlat:
		var flat := (sb as StyleBoxFlat).duplicate() as StyleBoxFlat
		# ちょうど半分にしない理由は touch_controls.gd の _round_panel() 参照(中央に縦線が出る)
		flat.set_corner_radius_all(int(floor(radius * 0.93)))
		panel.add_theme_stylebox_override("panel", flat)


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
		if not _can_capture(event.position):
			return # 範囲外は無視して他へ素通りさせる
		_active_finger = event.index
		# 追従: 置いた位置をスティックの中心にする(円が画面外へはみ出さない範囲で)
		position = _clamped_center(event.position) - size * 0.5
		_update_stick(event.position, _base_center())
		get_viewport().set_input_as_handled()
	elif event.index == _active_finger:
		_force_release()
		get_viewport().set_input_as_handled()


func _on_drag(event: InputEventScreenDrag) -> void:
	if event.index != _active_finger:
		return
	_update_stick(event.position, _base_center())
	get_viewport().set_input_as_handled()


func _can_capture(p: Vector2) -> bool:
	if capture_rect.has_area():
		return capture_rect.has_point(p)
	return p.distance_to(_base_center()) <= max_radius


func _clamped_center(p: Vector2) -> Vector2:
	var vis := get_viewport().get_visible_rect().size
	var r := max_radius
	return Vector2(clampf(p.x, r, maxf(vis.x - r, r)), clampf(p.y, r, maxf(vis.y - r, r)))


func _base_center() -> Vector2:
	# event.position は canvas_items+expand ストレッチ済みのビューポート座標系
	# (Controlのanchor/offsetと同じ空間)。global_positionもTouchControlsに
	# 変形が無いため同じ空間なので、そのまま距離比較できる。
	return global_position + size * 0.5


func _update_stick(touch_position: Vector2, center: Vector2) -> void:
	var offset := touch_position - center
	if offset.length() > max_radius:
		offset = offset.normalized() * max_radius
	_stick_vec = offset / max_radius # 正規化(各軸-1.0〜1.0、合成長は最大1.0)
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
	position = rest_position
	knob.position = _knob_rest_position
	for action_name in ACTIONS:
		Input.action_release(action_name)
	released.emit()


func is_held() -> bool:
	return _active_finger != -1
