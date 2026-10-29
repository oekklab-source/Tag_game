extends Button

## 絵だけのボタン。文字の代わりに icon を1枚載せ、意味は tooltip_text で補う。
## text を入れると絵の下に短い名前として出す（タイトル画面。ツールチップの出ないタッチ端末向け）。
## 乗せると少し膨らみ、押すと沈む（Tween で scale を動かすだけ）。
##
## 板の色と余白はテーマ(ui/pop_theme.tres)の Button を元に、このボタンのぶんだけ上書きする。
## テーマ側の余白は文字のボタン向けで、そのままだと絵が小さくなりすぎるため。

## 板の色。透明のままならテーマの色を使う
@export var base_color := Color(0, 0, 0, 0)
## 絵のまわりの余白（px）
@export var icon_margin := 12

const HOVER_SCALE := 1.06
const PRESS_SCALE := 0.94
## pressed の板は下の影が短くなる。そのぶん絵も下げて、板ごと沈んだように見せる
const PRESS_SHIFT := 4

var _tween: Tween


func _ready() -> void:
	expand_icon = true
	icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# expand_icon のまま上寄せにすると、絵が文字の上の残りを埋める
	if not text.is_empty():
		vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	for state: String in ["normal", "hover", "pressed", "disabled"]:
		var box := get_theme_stylebox(state).duplicate() as StyleBoxFlat
		if box == null:
			continue
		if base_color.a > 0.0 and state != "disabled":
			box.bg_color = base_color
			if state == "hover":
				box.bg_color = base_color.lightened(0.18)
			elif state == "pressed":
				box.bg_color = base_color.darkened(0.12)
		var shift := PRESS_SHIFT if state == "pressed" else 0
		box.content_margin_left = icon_margin
		box.content_margin_right = icon_margin
		box.content_margin_top = icon_margin + shift
		box.content_margin_bottom = icon_margin - shift
		add_theme_stylebox_override(state, box)
	resized.connect(_center_pivot)
	_center_pivot()
	mouse_entered.connect(_scale_to.bind(HOVER_SCALE))
	mouse_exited.connect(_scale_to.bind(1.0))
	button_down.connect(_scale_to.bind(PRESS_SCALE))
	button_up.connect(_on_button_up)


func _center_pivot() -> void:
	pivot_offset = size / 2.0


func _on_button_up() -> void:
	_scale_to(HOVER_SCALE if is_hovered() else 1.0)


func _scale_to(target: float) -> void:
	if disabled:
		target = 1.0
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "scale", Vector2(target, target), 0.12) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
