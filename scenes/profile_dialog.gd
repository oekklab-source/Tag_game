extends Control

## プロフィール設定ダイアログ。
## プレイヤー名、④コスチューム（部位別の塗り分け）の変更および戦績の確認を行う。

signal closed

@onready var name_edit: LineEdit = $Panel/VBox/NameRow/NameEdit
@onready var tabs: TabContainer = $Panel/VBox/CostumeTabs
@onready var costume_grid: GridContainer = $Panel/VBox/CostumeTabs/CostumeTab/Scroll/CostumeGrid
@onready var hint_label: Label = $Panel/VBox/CostumeTabs/CostumeTab/HintLabel
@onready var color_preview: ColorRect = $Panel/VBox/CostumeTabs/ColorTab/Header/ColorPreview
@onready var slots_container: VBoxContainer = $Panel/VBox/CostumeTabs/ColorTab/SlotsContainer
@onready var rating_val: Label = $Panel/VBox/StatsBox/Grid/RatingVal
@onready var matches_val: Label = $Panel/VBox/StatsBox/Grid/MatchesVal
@onready var winrate_val: Label = $Panel/VBox/StatsBox/Grid/WinRateVal
@onready var save_btn: Button = $Panel/VBox/ButtonRow/SaveButton
@onready var close_btn: Button = $Panel/VBox/ButtonRow/CloseButton

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

var _selected_costume_id: StringName = CostumeCatalog.DEFAULT_ID
var _selected_colors: PackedColorArray = PackedColorArray()


func _ready() -> void:
	save_btn.pressed.connect(_on_save_pressed)
	close_btn.pressed.connect(_on_close_pressed)
	tabs.set_tab_title(0, "コスチューム")
	tabs.set_tab_title(1, "カラー")
	refresh()


func refresh() -> void:
	name_edit.text = ProfileManager.player_name
	_selected_costume_id = ProfileManager.costume_id
	_selected_colors = ProfileManager.costume_colors.duplicate()
	_ensure_color_slot_count()
	_setup_costume_grid()
	_setup_color_slots()
	_update_preview()

	rating_val.text = "%d" % ProfileManager.rating
	matches_val.text = "%d" % ProfileManager.matches_played

	var total_wins = ProfileManager.runner_wins + ProfileManager.hunter_wins
	var rate = 0.0
	if ProfileManager.matches_played > 0:
		rate = (float(total_wins) / float(ProfileManager.matches_played)) * 100.0
	winrate_val.text = "%.1f%% (%d勝)" % [rate, total_wins]


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

		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 4)

		var btn := Button.new()
		btn.custom_minimum_size = Vector2(96, 64)
		btn.toggle_mode = true
		btn.button_pressed = (id == _selected_costume_id)
		btn.text = ("🔒 " if not owned else "") + String(def.get("name", String(id)))
		btn.modulate = Color(1, 1, 1, 1) if owned else Color(1, 1, 1, 0.5)

		var style := StyleBoxFlat.new()
		style.bg_color = _swatch_color(def)
		style.set_corner_radius_all(10)
		style.border_width_left = 2
		style.border_width_top = 2
		style.border_width_right = 2
		style.border_width_bottom = 2
		style.border_color = Color.WHITE if id == _selected_costume_id else Color(1, 1, 1, 0.3)
		btn.add_theme_stylebox_override("normal", style)
		btn.add_theme_stylebox_override("hover", style)
		btn.add_theme_stylebox_override("pressed", style)

		btn.pressed.connect(_on_costume_button_pressed.bind(id, owned))
		box.add_child(btn)
		costume_grid.add_child(box)


## コスチュームのボタン見本色（surfaces の最初の固定色 or 先頭スロット色）
func _swatch_color(def: Dictionary) -> Color:
	for surf in def.get("surfaces", []):
		if surf.get("role_tint", false):
			continue
		if surf.has("albedo"):
			return surf["albedo"]
	return Color(0.4, 0.45, 0.5)


func _on_costume_button_pressed(id: StringName, owned: bool) -> void:
	if not owned:
		hint_label.text = "「%s」は未所持です（準備中：今後のアップデートで解放予定）" % String(CostumeCatalog.get_def(id).get("name", String(id)))
		_setup_costume_grid()  # toggle が押し込まれたままにならないよう選択状態を描き直す
		return
	hint_label.text = ""
	_selected_costume_id = id
	_ensure_color_slot_count()
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
			btn.custom_minimum_size = Vector2(32, 32)
			btn.text = ""

			var style := StyleBoxFlat.new()
			style.bg_color = c
			style.set_corner_radius_all(16)
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


func _update_preview() -> void:
	if not _selected_colors.is_empty():
		color_preview.color = _selected_colors[0]


func _on_save_pressed() -> void:
	ProfileManager.update_profile(name_edit.text)
	ProfileManager.set_costume(_selected_costume_id, _selected_colors)
	closed.emit()
	hide()


func _on_close_pressed() -> void:
	closed.emit()
	hide()
