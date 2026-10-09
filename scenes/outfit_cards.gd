class_name OutfitCards
extends RefCounted

## きせかえ画面(costume_screen)とショップ(shop_screen)で共通の、着せ替え用カード部品。
## ショップを「試着しながら選ぶ」形にしたとき(2026-10-02)、両画面で同じカード・同じ
## パレットを見せるために costume_screen から切り出した。
## 純粋な部品なので tr() は呼ばない(RefCounted の static 関数からは使えない)。
## 表示文言は呼び出し側で訳してから渡すこと。

## 色スロット編集用のプリセットパレット（コスチュームの色スロット共通）。
## CostumeCatalog の preview_colors(ショップの見本色)もここから選ぶ決まり
const PALETTE_COLORS: Array[Color] = [
	Color(0.25, 0.65, 0.95), # スカイブルー
	Color(0.95, 0.35, 0.35), # コーラルレッド
	Color(0.35, 0.85, 0.45), # エメラルドグリーン
	Color(0.98, 0.75, 0.20), # サンフラワーイエロー
	Color(0.75, 0.40, 0.90), # パープル
	Color(1.00, 0.50, 0.75), # ピンク
	Color(0.20, 0.80, 0.80), # ターコイズ
	Color(0.30, 0.30, 0.35)  # ダークグレー
]

# レア度ごとの縁取り色（① 大きめカードで所持状況とあわせて見せる）
const RARITY_COLORS := {
	&"common": Color(0.6, 0.6, 0.65),
	&"rare": Color(0.35, 0.7, 1.0),
	&"epic": Color(0.75, 0.4, 0.95),
	&"legendary": Color(1.0, 0.75, 0.2),
}

const SKIN_SWATCHES: Array[Color] = [
	Color(0.35, 0.85, 0.55), # きょうりゅう
	Color(0.22, 0.30, 0.42), # しのび
	Color(0.95, 0.35, 0.35), # バスケ08（コーラル）
	Color(0.24, 0.40, 0.62), # オーバーオール（デニム）
]

const CARD_SIZE := Vector2(148, 108)
const HAT_SWATCH := Color(0.4, 0.45, 0.5)


## キャラクター(Humanoid.SKINS)のカード
static func skin_card(index: int, display_name: String, selected: bool, caption_text: String,
		on_pressed: Callable) -> Control:
	var swatch: Color = SKIN_SWATCHES[index] if index < SKIN_SWATCHES.size() else Color(0.4, 0.45, 0.5)
	return _card(display_name, swatch, Color(0.95, 0.95, 1.0), selected, true,
		caption_text, Color(0.5, 0.9, 0.6), on_pressed)


## ①大きめのアイテムカード（コスチューム・帽子で共通）。
## レア度で縁取り色を変え、未所持は半透明にする。キャプション(所持済み/価格等)は呼び出し側が決める
static func item_card(display_name: String, rarity: StringName, swatch: Color, selected: bool,
		owned: bool, caption_text: String, caption_color: Color, on_pressed: Callable) -> Control:
	return _card(display_name, swatch, RARITY_COLORS.get(rarity, Color.WHITE), selected, owned,
		caption_text, caption_color, on_pressed)


## コスチュームのカード見本色（surfaces の最初の固定色 or 先頭スロット色）
static func swatch_color(def: Dictionary) -> Color:
	for surf in def.get("surfaces", []):
		if surf.get("role_tint", false):
			continue
		if surf.has("albedo"):
			return surf["albedo"]
	return Color(0.4, 0.45, 0.5)


## 色スロットごとの「色 N: ●●●…」の行を作る。on_pick は (slot: int, color: Color)
static func color_slot_rows(slot_labels: Array[String], on_pick: Callable) -> Array[Control]:
	var rows: Array[Control] = []
	for slot in range(slot_labels.size()):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		var label := Label.new()
		label.text = slot_labels[slot]
		label.custom_minimum_size = Vector2(60, 0)
		row.add_child(label)

		var palette := HBoxContainer.new()
		palette.add_theme_constant_override("separation", 8)
		for c in PALETTE_COLORS:
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(36, 36)
			btn.text = ""

			var style := StyleBoxFlat.new()
			style.bg_color = c
			style.set_corner_radius_all(18)
			_set_border(style, 2, Color.WHITE)
			btn.add_theme_stylebox_override("normal", style)
			btn.add_theme_stylebox_override("hover", style)
			btn.add_theme_stylebox_override("pressed", style)

			btn.pressed.connect(on_pick.bind(slot, c))
			palette.add_child(btn)
		row.add_child(palette)
		rows.append(row)
	return rows


static func _card(display_name: String, swatch: Color, border_color: Color, selected: bool,
		owned: bool, caption_text: String, caption_color: Color, on_pressed: Callable) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var btn := Button.new()
	btn.custom_minimum_size = CARD_SIZE
	btn.toggle_mode = true
	btn.button_pressed = selected
	btn.text = display_name

	var style := StyleBoxFlat.new()
	style.bg_color = swatch
	style.set_corner_radius_all(14)
	_set_border(style, 4 if selected else 2, border_color)
	btn.modulate = Color(1, 1, 1, 1) if owned else Color(1, 1, 1, 0.55)
	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("hover", style)
	btn.add_theme_stylebox_override("pressed", style)

	btn.pressed.connect(on_pressed)
	box.add_child(btn)

	var caption := Label.new()
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.text = caption_text
	caption.add_theme_color_override("font_color", caption_color)
	box.add_child(caption)
	return box


static func _set_border(style: StyleBoxFlat, width: int, color: Color) -> void:
	style.border_width_left = width
	style.border_width_top = width
	style.border_width_right = width
	style.border_width_bottom = width
	style.border_color = color
