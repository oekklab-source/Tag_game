extends Control

## ②③ショップ画面（専用シーン、①きせかえ画面と同じ画面遷移方式）。
## 通貨パック（ジェム、モック実装）の購入と、ジェムでのコスチューム/帽子購入、
## およびそれらの③プレゼント送付（同時オンラインのフレンドへ即時配信）を行う。

const TITLE_SCENE := "res://scenes/title.tscn"

@onready var gem_label: Label = $TopBar/GemBadge/HBox/GemLabel
@onready var back_btn: Button = $TopBar/BackButton
@onready var pack_row: HBoxContainer = $ContentMargin/Scroll/MainVBox/PackSection/PackRow
@onready var item_grid: GridContainer = $ContentMargin/Scroll/MainVBox/ItemSection/ItemGrid
@onready var status_label: Label = $ContentMargin/Scroll/MainVBox/StatusLabel

@onready var gift_overlay: Control = $GiftPickerOverlay
@onready var gift_friend_list: VBoxContainer = $GiftPickerOverlay/Panel/VBox/FriendListContainer
@onready var gift_cancel_btn: Button = $GiftPickerOverlay/Panel/VBox/CancelButton
@onready var gift_title_label: Label = $GiftPickerOverlay/Panel/VBox/TitleLabel

const RARITY_COLORS := {
	&"common": Color(0.6, 0.6, 0.65),
	&"rare": Color(0.35, 0.7, 1.0),
	&"epic": Color(0.75, 0.4, 0.95),
	&"legendary": Color(1.0, 0.75, 0.2),
}

var _pending_gift_kind: StringName = &""
var _pending_gift_id: StringName = &""


func _ready() -> void:
	back_btn.pressed.connect(_on_back_pressed)
	gift_cancel_btn.pressed.connect(_close_gift_picker)
	PurchaseManager.currency_changed.connect(_refresh_gem_label)
	PurchaseManager.purchase_failed.connect(_on_purchase_failed)
	GiftManager.gift_received.connect(_on_gift_received)
	gift_overlay.hide()
	refresh()


func refresh() -> void:
	_refresh_gem_label()
	_setup_pack_row()
	_setup_item_grid()
	status_label.text = ""


func _refresh_gem_label() -> void:
	gem_label.text = "💎 %d" % ProfileManager.premium_currency


func _setup_pack_row() -> void:
	for child in pack_row.get_children():
		child.queue_free()

	for id in CurrencyPackCatalog.ordered_ids():
		var def := CurrencyPackCatalog.get_def(id)
		var box := PanelContainer.new()
		box.custom_minimum_size = Vector2(180, 0)

		var vbox := VBoxContainer.new()
		vbox.add_theme_constant_override("separation", 6)

		var name_lbl := Label.new()
		name_lbl.text = String(def.get("name", ""))
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(name_lbl)

		var price_lbl := Label.new()
		price_lbl.text = String(def.get("display_price", ""))
		price_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		price_lbl.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
		vbox.add_child(price_lbl)

		var buy_btn := Button.new()
		buy_btn.text = "購入する"
		buy_btn.pressed.connect(_on_buy_pack_pressed.bind(id))
		vbox.add_child(buy_btn)

		box.add_child(vbox)
		pack_row.add_child(box)


func _on_buy_pack_pressed(pack_id: StringName) -> void:
	if PurchaseManager.buy_currency_pack(pack_id):
		var def := CurrencyPackCatalog.get_def(pack_id)
		status_label.text = "💎%d を獲得しました！" % int(def.get("gems", 0))


func _setup_item_grid() -> void:
	for child in item_grid.get_children():
		child.queue_free()

	for id in CostumeCatalog.purchasable_ids():
		item_grid.add_child(_build_item_card(&"costume", id, CostumeCatalog.get_def(id)))
	for id in HatCatalog.purchasable_ids():
		item_grid.add_child(_build_item_card(&"hat", id, HatCatalog.get_def(id)))


func _build_item_card(kind: StringName, id: StringName, def: Dictionary) -> Control:
	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(200, 0)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.15, 0.8)
	style.set_corner_radius_all(12)
	var rarity: StringName = def.get("rarity", &"common")
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = RARITY_COLORS.get(rarity, Color.WHITE)
	box.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)

	var name_lbl := Label.new()
	name_lbl.text = String(def.get("name", String(id)))
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(name_lbl)

	var owned := _owns(kind, id)
	var price := int(def.get("price", 0))

	var price_lbl := Label.new()
	price_lbl.text = "所持済み" if owned else "💎 %d" % price
	price_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	price_lbl.add_theme_color_override("font_color",
		Color(0.5, 0.9, 0.6) if owned else Color(0.9, 0.75, 0.4))
	vbox.add_child(price_lbl)

	var buy_btn := Button.new()
	buy_btn.text = "購入する"
	buy_btn.disabled = owned
	buy_btn.pressed.connect(_on_buy_item_pressed.bind(kind, id))
	vbox.add_child(buy_btn)

	var gift_btn := Button.new()
	gift_btn.text = "🎁 プレゼントする"
	gift_btn.pressed.connect(_open_gift_picker.bind(kind, id))
	vbox.add_child(gift_btn)

	box.add_child(vbox)
	return box


func _owns(kind: StringName, id: StringName) -> bool:
	match kind:
		&"costume":
			return ProfileManager.owns_costume(id)
		&"hat":
			return ProfileManager.owns_hat(id)
		_:
			return false


func _on_buy_item_pressed(kind: StringName, id: StringName) -> void:
	if PurchaseManager.purchase_item(kind, id):
		var def := CostumeCatalog.get_def(id) if kind == &"costume" else HatCatalog.get_def(id)
		status_label.text = "「%s」を購入しました！" % String(def.get("name", String(id)))
		_setup_item_grid()


func _on_purchase_failed(reason: String) -> void:
	status_label.text = reason


## ③プレゼント相手選択ピッカーを開く（オンラインのフレンドのみ表示）
func _open_gift_picker(kind: StringName, id: StringName) -> void:
	_pending_gift_kind = kind
	_pending_gift_id = id
	var def := CostumeCatalog.get_def(id) if kind == &"costume" else HatCatalog.get_def(id)
	gift_title_label.text = "「%s」を贈る相手を選択" % String(def.get("name", String(id)))

	for child in gift_friend_list.get_children():
		child.queue_free()

	var friends := FriendManager.get_friends()
	var online_friends := friends.filter(func(f): return f.get("online", false))
	if online_friends.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "オンラインのフレンドがいません。プレゼントは両者オンライン中のみ贈れます。"
		empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		gift_friend_list.add_child(empty_lbl)
	else:
		for f in online_friends:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 12)

			var name_lbl := Label.new()
			name_lbl.text = String(f.get("name", "Friend"))
			name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(name_lbl)

			var send_btn := Button.new()
			send_btn.text = "贈る"
			send_btn.pressed.connect(_on_send_gift_pressed.bind(int(f.get("steam_id", 0)), String(f.get("name", "Friend"))))
			row.add_child(send_btn)

			gift_friend_list.add_child(row)

	gift_overlay.show()


func _close_gift_picker() -> void:
	gift_overlay.hide()


func _on_send_gift_pressed(friend_steam_id: int, friend_name: String) -> void:
	var kind := _pending_gift_kind
	var id := _pending_gift_id
	_close_gift_picker()

	if not PurchaseManager.spend_for_gift(kind, id):
		status_label.text = "ジェムが足りません"
		return

	status_label.text = "%s さんに送信中..." % friend_name
	var ok: bool = await GiftManager.send_gift(friend_steam_id, kind, id)
	if ok:
		status_label.text = "%s さんにプレゼントを贈りました！" % friend_name
	else:
		PurchaseManager.refund_gift(kind, id)
		status_label.text = "%s さんに届けられませんでした（オフラインの可能性があります）。ジェムは返金されました。" % friend_name


func _on_gift_received(kind: StringName, id: StringName, from_name: String) -> void:
	var def := CostumeCatalog.get_def(id) if kind == &"costume" else HatCatalog.get_def(id)
	status_label.text = "%s さんから「%s」をプレゼントされました！" % [from_name, String(def.get("name", String(id)))]
	_setup_item_grid()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(TITLE_SCENE)
