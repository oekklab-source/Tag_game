extends Control

## ①きせかえ画面（専用シーン）。
## 旧 profile_dialog.gd（title.tscn に埋め込みのモーダルダイアログ）を、画面全体を
## 使った専用シーンへ昇格させたもの。プレイヤー名、④コスチューム（部位別の塗り分け）・
## ⑤帽子（新規部位）の変更（3Dプレビュー付き）、②所持ジェムの確認、戦績の確認を行う。

const TITLE_SCENE := "res://scenes/title.tscn"
const SHOP_SCENE := "res://scenes/shop_screen.tscn"

@onready var name_edit: LineEdit = $ContentMargin/ContentRow/RightPane/NameRow/NameEdit
@onready var preview: Control = $ContentMargin/ContentRow/PreviewPane/CostumePreview
@onready var category_costume_btn: Button = $ContentMargin/ContentRow/RightPane/CategoryRow/CategorySidebar/CostumeTabButton
@onready var category_color_btn: Button = $ContentMargin/ContentRow/RightPane/CategoryRow/CategorySidebar/ColorTabButton
@onready var category_hat_btn: Button = $ContentMargin/ContentRow/RightPane/CategoryRow/CategorySidebar/HatTabButton
@onready var costume_panel: Control = $ContentMargin/ContentRow/RightPane/CategoryRow/CategoryContent/CostumePanel
@onready var color_panel: Control = $ContentMargin/ContentRow/RightPane/CategoryRow/CategoryContent/ColorPanel
@onready var hat_panel: Control = $ContentMargin/ContentRow/RightPane/CategoryRow/CategoryContent/HatPanel
@onready var costume_grid: GridContainer = $ContentMargin/ContentRow/RightPane/CategoryRow/CategoryContent/CostumePanel/Scroll/CostumeGrid
@onready var slots_container: VBoxContainer = $ContentMargin/ContentRow/RightPane/CategoryRow/CategoryContent/ColorPanel/SlotsContainer
@onready var hat_grid: GridContainer = $ContentMargin/ContentRow/RightPane/CategoryRow/CategoryContent/HatPanel/Scroll/HatGrid
@onready var hint_label: Label = $ContentMargin/ContentRow/RightPane/HintLabel
@onready var rating_val: Label = $ContentMargin/ContentRow/RightPane/StatsBox/Grid/RatingVal
@onready var matches_val: Label = $ContentMargin/ContentRow/RightPane/StatsBox/Grid/MatchesVal
@onready var winrate_val: Label = $ContentMargin/ContentRow/RightPane/StatsBox/Grid/WinRateVal
@onready var gem_label: Label = $TopBar/GemBadge/HBox/GemLabel
@onready var save_btn: Button = $ContentMargin/ContentRow/RightPane/ButtonRow/SaveButton
@onready var back_btn: Button = $TopBar/BackButton
@onready var shop_btn: Button = $TopBar/ShopButton

# 色スロット編集用のプリセットパレット（コスチュームの色スロット共通）
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

var _selected_costume_id: StringName = CostumeCatalog.DEFAULT_ID
var _selected_colors: PackedColorArray = PackedColorArray()
var _selected_hat_id: StringName = HatCatalog.DEFAULT_ID


func _ready() -> void:
	save_btn.pressed.connect(_on_save_pressed)
	back_btn.pressed.connect(_on_back_pressed)
	shop_btn.pressed.connect(_on_shop_pressed)
	category_costume_btn.pressed.connect(_on_category_pressed.bind(0))
	category_color_btn.pressed.connect(_on_category_pressed.bind(1))
	category_hat_btn.pressed.connect(_on_category_pressed.bind(2))
	PurchaseManager.currency_changed.connect(_update_gem_label)
	refresh()


func refresh() -> void:
	name_edit.text = ProfileManager.player_name
	_selected_costume_id = ProfileManager.costume_id
	_selected_colors = ProfileManager.costume_colors.duplicate()
	_selected_hat_id = ProfileManager.hat_id
	_ensure_color_slot_count()
	_setup_costume_grid()
	_setup_color_slots()
	_setup_hat_grid()
	_on_category_pressed(0)
	preview.reset_view()
	_update_preview()
	_update_gem_label()

	rating_val.text = "%d" % ProfileManager.rating
	matches_val.text = "%d" % ProfileManager.matches_played

	var total_wins = ProfileManager.runner_wins + ProfileManager.hunter_wins
	var rate = 0.0
	if ProfileManager.matches_played > 0:
		rate = (float(total_wins) / float(ProfileManager.matches_played)) * 100.0
	winrate_val.text = "%.1f%% (%d勝)" % [rate, total_wins]


func _update_gem_label() -> void:
	gem_label.text = "💎 %d" % ProfileManager.premium_currency


## ①カテゴリの切り替え（縦サイドバー方式）。0=スキン柄, 1=カラー, 2=帽子
func _on_category_pressed(index: int) -> void:
	costume_panel.visible = index == 0
	color_panel.visible = index == 1
	hat_panel.visible = index == 2
	category_costume_btn.button_pressed = index == 0
	category_color_btn.button_pressed = index == 1
	category_hat_btn.button_pressed = index == 2


## _selected_colors のサイズを現在のコスチュームの color_slots に合わせる。
## 既存の色は保ち、足りない分だけプリセット先頭色で埋める
func _ensure_color_slot_count() -> void:
	var slots: int = int(CostumeCatalog.get_def(_selected_costume_id).get("color_slots", 1))
	while _selected_colors.size() < slots:
		_selected_colors.append(PALETTE_COLORS[_selected_colors.size() % PALETTE_COLORS.size()])
	if _selected_colors.size() > slots:
		_selected_colors.resize(slots)


func _setup_costume_grid() -> void:
	for child in costume_grid.get_children():
		child.queue_free()

	for id in CostumeCatalog.COSTUMES:
		var def: Dictionary = CostumeCatalog.COSTUMES[id]
		var owned := ProfileManager.owns_costume(id)
		costume_grid.add_child(_build_item_card(id, def, owned, _selected_costume_id, _swatch_color(def),
			_on_costume_button_pressed))


## コスチュームのカード見本色（surfaces の最初の固定色 or 先頭スロット色）
func _swatch_color(def: Dictionary) -> Color:
	for surf in def.get("surfaces", []):
		if surf.get("role_tint", false):
			continue
		if surf.has("albedo"):
			return surf["albedo"]
	return Color(0.4, 0.45, 0.5)


## ①大きめのアイテムカードを生成する（コスチューム・帽子で共通）。
## レア度で縁取り色を変え、未所持は🔒+価格バッジを表示する
func _build_item_card(id: StringName, def: Dictionary, owned: bool, selected_id: StringName,
		swatch: Color, on_pressed: Callable) -> Control:
	const CARD_SIZE := Vector2(148, 108)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var btn := Button.new()
	btn.custom_minimum_size = CARD_SIZE
	btn.toggle_mode = true
	btn.button_pressed = (id == selected_id)
	btn.text = String(def.get("name", String(id)))

	var style := StyleBoxFlat.new()
	style.bg_color = swatch
	style.set_corner_radius_all(14)
	var rarity: StringName = def.get("rarity", &"common")
	var border_color: Color = RARITY_COLORS.get(rarity, Color.WHITE)
	if id == selected_id:
		style.border_width_left = 4
		style.border_width_top = 4
		style.border_width_right = 4
		style.border_width_bottom = 4
	else:
		style.border_width_left = 2
		style.border_width_top = 2
		style.border_width_right = 2
		style.border_width_bottom = 2
	style.border_color = border_color
	btn.modulate = Color(1, 1, 1, 1) if owned else Color(1, 1, 1, 0.55)
	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("hover", style)
	btn.add_theme_stylebox_override("pressed", style)

	btn.pressed.connect(on_pressed.bind(id))
	box.add_child(btn)

	var caption := Label.new()
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if owned:
		caption.text = "所持済み"
		caption.add_theme_color_override("font_color", Color(0.5, 0.9, 0.6))
	else:
		var price := int(def.get("price", 0))
		caption.text = "🔒 未所持" if price <= 0 else "🔒 💎%d" % price
		caption.add_theme_color_override("font_color", Color(0.9, 0.75, 0.4))
	box.add_child(caption)

	return box


## 未所持でも選択・試着はできる（3Dプレビューに反映するだけ）。保存できるかは
## ProfileManager.owns_costume() の所持ガードに委ねる（_on_save_pressed 参照）
func _on_costume_button_pressed(id: StringName) -> void:
	_selected_costume_id = id
	_ensure_color_slot_count()
	_update_hint_label()
	_setup_costume_grid()
	_setup_color_slots()
	_update_preview()


func _setup_color_slots() -> void:
	for child in slots_container.get_children():
		child.queue_free()

	for slot in range(_selected_colors.size()):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		var label := Label.new()
		label.text = "色 %d:" % (slot + 1)
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
			style.border_width_left = 2
			style.border_width_top = 2
			style.border_width_right = 2
			style.border_width_bottom = 2
			style.border_color = Color.WHITE
			btn.add_theme_stylebox_override("normal", style)
			btn.add_theme_stylebox_override("hover", style)
			btn.add_theme_stylebox_override("pressed", style)

			btn.pressed.connect(_on_slot_color_pressed.bind(slot, c))
			palette.add_child(btn)
		row.add_child(palette)
		slots_container.add_child(row)


func _on_slot_color_pressed(slot: int, color: Color) -> void:
	if slot < _selected_colors.size():
		_selected_colors[slot] = color
		_update_preview()


## ⑤帽子カテゴリのグリッド。_setup_costume_grid() と同じパターン
func _setup_hat_grid() -> void:
	for child in hat_grid.get_children():
		child.queue_free()

	for id in HatCatalog.HATS:
		var def: Dictionary = HatCatalog.HATS[id]
		var owned := ProfileManager.owns_hat(id)
		hat_grid.add_child(_build_item_card(id, def, owned, _selected_hat_id, Color(0.4, 0.45, 0.5),
			_on_hat_button_pressed))


func _on_hat_button_pressed(id: StringName) -> void:
	_selected_hat_id = id
	_update_hint_label()
	_setup_hat_grid()
	_update_preview()


## スキン柄・帽子どちらのタブでも共通の「未所持です」ヒントを出す
func _update_hint_label() -> void:
	if not ProfileManager.owns_costume(_selected_costume_id):
		var name: String = String(CostumeCatalog.get_def(_selected_costume_id).get("name", String(_selected_costume_id)))
		hint_label.text = "「%s」は未所持です（試着のみ・保存では反映されません。ショップで購入できます）" % name
	elif not ProfileManager.owns_hat(_selected_hat_id):
		var name: String = String(HatCatalog.get_def(_selected_hat_id).get("name", String(_selected_hat_id)))
		hint_label.text = "「%s」は未所持です（試着のみ・保存では反映されません。ショップで購入できます）" % name
	else:
		hint_label.text = ""


func _update_preview() -> void:
	preview.show_costume(_selected_costume_id, _selected_colors)
	preview.show_hat(_selected_hat_id)
	var locked := not ProfileManager.owns_costume(_selected_costume_id) \
		or not ProfileManager.owns_hat(_selected_hat_id)
	preview.set_locked(locked)


func _on_save_pressed() -> void:
	ProfileManager.update_profile(name_edit.text)
	if ProfileManager.owns_costume(_selected_costume_id):
		ProfileManager.set_costume(_selected_costume_id, _selected_colors)
	if ProfileManager.owns_hat(_selected_hat_id):
		ProfileManager.set_hat(_selected_hat_id)
	get_tree().change_scene_to_file(TITLE_SCENE)


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(TITLE_SCENE)


func _on_shop_pressed() -> void:
	get_tree().change_scene_to_file(SHOP_SCENE)
