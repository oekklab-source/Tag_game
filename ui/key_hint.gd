extends RefCounted

## キー操作のヒントを文ではなく絵で出すための部品。
## 「キーの絵（刻印）＋そのキーでできることの絵」を1組として横に並べる。
##
##   const KeyHint := preload("res://ui/key_hint.gd")
##   row.add_child(KeyHint.pair("F", KeyHint.icon("emote"), 32))
##
## 刻印（W A S D や Esc）はキーボードに印字されている文字そのものなので訳さない。

const KEY := preload("res://ui/icons/key.png")
const KEY_WIDE := preload("res://ui/icons/key_wide.png")
const INK := Color(0.231, 0.114, 0.431)


static func icon(name: String) -> Texture2D:
	return load("res://ui/icons/%s.png" % name)


## 絵を1枚、px 四方（wide なら横2倍）で置く
static func image(texture: Texture2D, px: float, wide := false) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = texture
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.custom_minimum_size = Vector2(px * (2.0 if wide else 1.0), px)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


## 刻印つきのキー。2文字以上（Shift など）は横長のキーに載せる
static func key(legend: String, px: float) -> Control:
	var wide := legend.length() > 1
	var cap := image(KEY_WIDE if wide else KEY, px, wide)
	var label := Label.new()
	label.text = legend
	label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", int(px * 0.4))
	label.add_theme_color_override("font_color", INK)
	label.add_theme_constant_override("outline_size", 0)
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	# キーの絵は天面が少し上へずれた立体なので、刻印も同じだけ上へ寄せる
	label.offset_bottom = -px * 0.1
	cap.add_child(label)
	return cap


## 「入力 ＋ 動作」の1組。input は刻印の文字列か、マウスなどの絵(Texture2D)
static func pair(input: Variant, action: Texture2D, px: float) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if input is Texture2D:
		box.add_child(image(input, px))
	else:
		box.add_child(key(str(input), px))
	if action:
		box.add_child(image(action, px))
	return box
