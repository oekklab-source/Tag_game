extends Control

## ②③ショップ画面（専用シーン、①きせかえ画面と同じ画面遷移方式）。
## 通貨パック（ジェム、モック実装）の購入と、ジェムでのコスチューム/帽子購入、
## およびそれらの③プレゼント送付（同時オンラインのフレンドへ即時配信）を行う。
##
## 2026-10-02 に「アイテムのカードを一覧に並べて1つずつ買う」形から、「お店の中で
## 試着しながらコーデを組み、未所持の物をまとめて買ってそのまま着る」形に作り直した。
## 一覧のままだと小さなプレビューが並ぶだけで、組み合わせを楽しめなかったため。
## 右側のタブとカードはきせかえ画面と同じ部品(OutfitCards)で、左側の舞台(shop_stage)では
## 店員さんが試着や購入に反応する。

const TITLE_SCENE := "res://scenes/title.tscn"
const FRIEND_SCENE := "res://scenes/friend_screen.tscn"

## hud.gdがロビー待機中にオーバーレイとして埋め込んだ場合に、閉じる操作の代わりに発火する。
## タイトルから専用シーンとして開かれた場合(get_tree().current_scene == self)は
## 従来通りタイトルへのシーン遷移を行うため、その場合は発火しない
signal closed

## カテゴリの並び(きせかえ画面と同じ)
enum Tab { SKIN, COSTUME, COLOR, HAT }

@onready var gem_label: Label = $TopBar/GemBadge/HBox/GemLabel
@onready var add_gem_btn: Button = $TopBar/GemBadge/HBox/AddGemButton
@onready var back_btn: Button = $TopBar/BackButton
@onready var stage: Control = $ContentMargin/ContentRow/StagePane/StageRoot/ShopStage
@onready var speech_bubble: Control = $ContentMargin/ContentRow/StagePane/StageRoot/SpeechBubble
@onready var speech_label: Label = $ContentMargin/ContentRow/StagePane/StageRoot/SpeechBubble/SpeechLabel
@onready var hint_label: Label = $ContentMargin/ContentRow/RightPane/HintLabel
@onready var tab_buttons: Array[Button] = [
	$ContentMargin/ContentRow/RightPane/CategoryRow/CategorySidebar/SkinTabButton,
	$ContentMargin/ContentRow/RightPane/CategoryRow/CategorySidebar/CostumeTabButton,
	$ContentMargin/ContentRow/RightPane/CategoryRow/CategorySidebar/ColorTabButton,
	$ContentMargin/ContentRow/RightPane/CategoryRow/CategorySidebar/HatTabButton,
]
@onready var tab_panels: Array[Control] = [
	$ContentMargin/ContentRow/RightPane/CategoryRow/CategoryContent/SkinPanel,
	$ContentMargin/ContentRow/RightPane/CategoryRow/CategoryContent/CostumePanel,
	$ContentMargin/ContentRow/RightPane/CategoryRow/CategoryContent/ColorPanel,
	$ContentMargin/ContentRow/RightPane/CategoryRow/CategoryContent/HatPanel,
]
@onready var skin_grid: GridContainer = $ContentMargin/ContentRow/RightPane/CategoryRow/CategoryContent/SkinPanel/SkinGrid
@onready var costume_grid: GridContainer = $ContentMargin/ContentRow/RightPane/CategoryRow/CategoryContent/CostumePanel/CostumeGrid
@onready var color_panel: VBoxContainer = $ContentMargin/ContentRow/RightPane/CategoryRow/CategoryContent/ColorPanel
@onready var hat_grid: GridContainer = $ContentMargin/ContentRow/RightPane/CategoryRow/CategoryContent/HatPanel/HatGrid
@onready var cart_list: VBoxContainer = $ContentMargin/ContentRow/RightPane/CartBox/VBox/CartList
@onready var status_label: Label = $ContentMargin/ContentRow/RightPane/StatusLabel
@onready var gift_btn: Button = $ContentMargin/ContentRow/RightPane/ButtonRow/GiftButton
@onready var reset_btn: Button = $ContentMargin/ContentRow/RightPane/ButtonRow/ResetButton
@onready var checkout_btn: Button = $ContentMargin/ContentRow/RightPane/ButtonRow/CheckoutButton

@onready var gem_overlay: Control = $GemPackOverlay
@onready var pack_row: HBoxContainer = $GemPackOverlay/Panel/VBox/PackRow
@onready var pack_status_label: Label = $GemPackOverlay/Panel/VBox/PackStatusLabel
@onready var gem_close_btn: Button = $GemPackOverlay/Panel/VBox/CloseButton

@onready var gift_overlay: Control = $GiftPickerOverlay
@onready var gift_friend_list: VBoxContainer = $GiftPickerOverlay/Panel/VBox/FriendListContainer
@onready var gift_cancel_btn: Button = $GiftPickerOverlay/Panel/VBox/CancelButton
@onready var gift_title_label: Label = $GiftPickerOverlay/Panel/VBox/TitleLabel

@onready var confirm_overlay: Control = $ConfirmOverlay
@onready var confirm_message_label: Label = $ConfirmOverlay/Panel/VBox/MessageLabel
@onready var confirm_cancel_btn: Button = $ConfirmOverlay/Panel/VBox/Buttons/CancelButton
@onready var confirm_buy_btn: Button = $ConfirmOverlay/Panel/VBox/Buttons/BuyButton

## コスチューム(柄・カラー)が効く唯一のキャラ(Humanoid.SKINS の添字)。humanoid.gd の
## apply_costume() は他のキャラだと何も塗らないので、コスチュームを選んだら
## このキャラに着替えさせて試着する(2026-10-02「全部同じアバターに見える」報告)
const COSTUME_SKIN := 0

## ⑥PurchaseManagerが返す理由識別子(英語定数)を、画面表示用の日本語文言に変換する。
## 文言は表示する時点で tr() する(L-09)。L-09 で purchase_item 系も生の日本語から
## 識別子に揃えたので、未知の識別子はサーバー由来の想定外の値だけになる(そのまま表示する)
const FAILURE_MESSAGES := {
	"unknown_pack": "不明な通貨パックです",
	"network_error": "通信エラーが発生しました。時間をおいて再度お試しください",
	"user_cancelled": "購入がキャンセルされました",
	"purchase_timeout": "決済の確認がタイムアウトしました。次回起動時に自動的に再確認されます。",
	"unknown_item": "不明なアイテムです",
	"already_owned": "すでに所持しています",
	"not_enough_gems": "ジェムが足りません",
}

## 試着中のコーデ。「元に戻す」かコーデを確定するまで保存しない
var _sel_skin := 0
var _sel_costume: StringName = CostumeCatalog.DEFAULT_ID
var _sel_colors := PackedColorArray()
var _sel_hat: StringName = HatCatalog.DEFAULT_ID

## プレゼントの対象。コーデ全体は贈れないので、最後に選んだコスチューム/帽子1品にする
var _focus_kind: StringName = &""
var _focus_id: StringName = &""

var _pending_gift_kind: StringName = &""
var _pending_gift_id: StringName = &""

## C-02対策: 購入は必ずこの確認オーバーレイを経由させ、即時実行を防ぐ
var _pending_confirm_action: Callable

var _speech_tween: Tween


func _ready() -> void:
	back_btn.pressed.connect(_on_back_pressed)
	add_gem_btn.pressed.connect(_open_gem_overlay)
	gem_close_btn.pressed.connect(_close_gem_overlay)
	gift_cancel_btn.pressed.connect(_close_gift_picker)
	confirm_cancel_btn.pressed.connect(_close_confirm_overlay)
	confirm_buy_btn.pressed.connect(_on_confirm_buy_pressed)
	gift_btn.pressed.connect(func(): _open_gift_picker(_focus_kind, _focus_id))
	reset_btn.pressed.connect(_on_reset_pressed)
	checkout_btn.pressed.connect(_on_checkout_pressed)
	for i in tab_buttons.size():
		tab_buttons[i].pressed.connect(_on_category_pressed.bind(i))
	tab_panels[Tab.COSTUME].get_parent().resized.connect(_fit_grid_columns)
	PurchaseManager.currency_changed.connect(_refresh_gem_label)
	PurchaseManager.purchase_failed.connect(_on_purchase_failed)
	GiftManager.gift_received.connect(_on_gift_received)
	# ⑥Stripe決済はOSブラウザ経由のため、決済完了直後はゲームウィンドウが
	# フォーカスを失ったままになりやすい。フォーカス復帰時に付与済みジェム残高で
	# 明示的に再同期し、「購入直後は表示が更新されず、画面を出入りするまで
	# 反映されない」症状(currency_changed自体は正しく発火・保存されているのに
	# 表示だけ古いまま、という実機報告)を防ぐ
	get_window().focus_entered.connect(_refresh_gem_label)
	gem_overlay.hide()
	gift_overlay.hide()
	confirm_overlay.hide()
	refresh()
	_say(tr("いらっしゃいませ！ 気になるものは、なんでも試着してみてくださいね♪"))
	stage.beckon()


func refresh() -> void:
	_refresh_gem_label()
	_setup_pack_row()
	_load_saved_outfit()
	_on_category_pressed(Tab.COSTUME)
	status_label.text = ""


func _refresh_gem_label() -> void:
	gem_label.text = "💎 %d" % ProfileManager.premium_currency
	# 残高が変わると「ジェムが足りるか」も変わるので、ボタンの表示も合わせる
	_update_checkout()


# --- 試着(コーデの組み立て) ---------------------------------------------

## 今保存されているコーデから試着を始める(入店時と「元に戻す」)
func _load_saved_outfit() -> void:
	_sel_skin = ProfileManager.skin
	_sel_costume = ProfileManager.costume_id
	_sel_colors = ProfileManager.costume_colors.duplicate()
	_sel_hat = ProfileManager.hat_id
	_focus_kind = &""
	_focus_id = &""
	_rebuild()


func _rebuild() -> void:
	_setup_skin_grid()
	_setup_costume_grid()
	_setup_color_slots()
	_setup_hat_grid()
	_refresh_outfit()
	_fit_grid_columns.call_deferred()


## カードの列数を、実際に入る数に合わせる。固定の3列だと、文字サイズ「特大」や英語で
## カードが広がったときに右端の列が切れて横スクロールになった(2026-10-02 に撮って確認)
func _fit_grid_columns() -> void:
	var avail: float = tab_panels[Tab.COSTUME].get_parent().size.x
	for grid: GridContainer in [skin_grid, costume_grid, hat_grid]:
		var card_w := 0.0
		for child in grid.get_children():
			card_w = maxf(card_w, child.get_combined_minimum_size().x)
		if card_w <= 0.0:
			continue
		var sep := float(grid.get_theme_constant("h_separation"))
		grid.columns = clampi(int((avail + sep) / (card_w + sep)), 1, 3)


## 舞台・コーデの内容・ボタンなど、選択が変わるたびに変わる部分だけを更新する
## (カラー変更のようにカードの並びが変わらない操作はここだけ呼ぶ)
func _refresh_outfit() -> void:
	stage.show_outfit(_sel_skin, _sel_costume, _sel_colors, _sel_hat)
	stage.set_locked(not _cart_items().is_empty())
	# カラーはきょうりゅう専用(きせかえ画面の _update_category_availability と同じ)
	var fixed_design := _sel_skin != COSTUME_SKIN
	tab_buttons[Tab.COLOR].disabled = fixed_design
	tab_buttons[Tab.COLOR].tooltip_text = tr("このキャラクターは固定デザインです") if fixed_design else ""
	if fixed_design and tab_panels[Tab.COLOR].visible:
		_on_category_pressed(Tab.COSTUME)
	hint_label.text = tr("%sは固定デザインです。帽子は変更できます") % tr(Humanoid.SKINS[_sel_skin]["name"]) \
		if fixed_design else ""
	_update_cart_list()
	_update_checkout()
	_update_gift_button()


func _on_category_pressed(index: int) -> void:
	for i in tab_panels.size():
		tab_panels[i].visible = i == index
		tab_buttons[i].button_pressed = i == index


func _setup_skin_grid() -> void:
	for child in skin_grid.get_children():
		child.queue_free()
	for index in range(Humanoid.SKINS.size()):
		var display_name := tr(String(Humanoid.SKINS[index].get("name", tr("キャラクター"))))
		skin_grid.add_child(OutfitCards.skin_card(index, display_name, index == _sel_skin,
			tr("使用できます"), _on_skin_pressed.bind(index)))


func _setup_costume_grid() -> void:
	for child in costume_grid.get_children():
		child.queue_free()
	for id in CostumeCatalog.COSTUMES:
		var def: Dictionary = CostumeCatalog.COSTUMES[id]
		# カードの色は、そのコスチュームを選んだときの見本の体色にする(舞台で見える色と一致させる)
		var swatch: Color = CostumeCatalog.preview_colors(id)[0]
		costume_grid.add_child(_build_item_card(&"costume", id, def, swatch,
			id == _sel_costume and _sel_skin == COSTUME_SKIN, _on_costume_pressed))


func _setup_hat_grid() -> void:
	for child in hat_grid.get_children():
		child.queue_free()
	for id in HatCatalog.HATS:
		hat_grid.add_child(_build_item_card(&"hat", id, HatCatalog.HATS[id], OutfitCards.HAT_SWATCH,
			id == _sel_hat, _on_hat_pressed))


func _setup_color_slots() -> void:
	for child in color_panel.get_children():
		child.queue_free()
	var labels: Array[String] = []
	for slot in range(_sel_colors.size()):
		labels.append(tr("色 %d:") % (slot + 1))
	for row in OutfitCards.color_slot_rows(labels, _on_slot_color_pressed):
		color_panel.add_child(row)


func _build_item_card(kind: StringName, id: StringName, def: Dictionary, swatch: Color,
		selected: bool, on_pressed: Callable) -> Control:
	var owned := _owns(kind, id)
	return OutfitCards.item_card(tr(String(def.get("name", String(id)))), def.get("rarity", &"common"),
		swatch, selected, owned, _price_caption(owned, int(def.get("price", 0))),
		Color(0.5, 0.9, 0.6) if owned else Color(0.9, 0.75, 0.4), on_pressed.bind(id))


## 所持状況と値段の表記。値段0の未所持品(レート報酬扱い等)もショップでは
## 0ジェムで入手できる(PurchaseManager.purchase_item の既存仕様)ので「無料」と出す
func _price_caption(owned: bool, price: int) -> String:
	if owned:
		return tr("所持済み")
	return tr("無料") if price <= 0 else "💎 %d" % price


func _on_skin_pressed(index: int) -> void:
	_sel_skin = clampi(index, 0, Humanoid.SKINS.size() - 1)
	_rebuild()


func _on_costume_pressed(id: StringName) -> void:
	_sel_costume = id
	# 今着ているコスチュームなら自分の色、それ以外は見本色で試着する。見本色は
	# きせかえ画面と同じパレットの色なので、そのまま買って着ても同じ見た目になる
	_sel_colors = ProfileManager.costume_colors.duplicate() if id == ProfileManager.costume_id \
		else CostumeCatalog.preview_colors(id)
	var switched := _sel_skin != COSTUME_SKIN
	_sel_skin = COSTUME_SKIN
	_focus_kind = &"costume"
	_focus_id = id
	if switched:
		_say(tr("スキン柄はきょうりゅう専用なので、きょうりゅうで試着しますね"))
	else:
		_react_to_item(&"costume", id)
	_rebuild()


func _on_hat_pressed(id: StringName) -> void:
	_sel_hat = id
	_focus_kind = &"hat" if id != HatCatalog.DEFAULT_ID else &""
	_focus_id = id if id != HatCatalog.DEFAULT_ID else &""
	if id != HatCatalog.DEFAULT_ID:
		_react_to_item(&"hat", id)
	_rebuild()


func _on_slot_color_pressed(slot: int, color: Color) -> void:
	if slot < _sel_colors.size():
		_sel_colors[slot] = color
		_refresh_outfit()


func _react_to_item(kind: StringName, id: StringName) -> void:
	var item_name := _item_name(kind, id)
	if _owns(kind, id):
		_say(tr("「%s」はもうお持ちですね。いろいろ合わせてみましょう！") % item_name)
		return
	if kind == &"hat":
		_say(tr("「%s」、人気なんですよ♪") % item_name)
	else:
		_say(tr("「%s」、とってもお似合いです！") % item_name)
	stage.cheer()


func _on_reset_pressed() -> void:
	_load_saved_outfit()
	stage.reset_view()
	status_label.text = ""


# --- コーデの内容とまとめ買い ---------------------------------------------

## 試着中のコーデのうち、まだ持っていない物(=買うと着られる物)。
## コスチュームはきょうりゅうで試着しているときだけ数える(他のキャラでは効かないので)
func _cart_items() -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	if _sel_skin == COSTUME_SKIN and not ProfileManager.owns_costume(_sel_costume):
		items.append({"kind": &"costume", "id": _sel_costume,
			"price": int(CostumeCatalog.get_def(_sel_costume).get("price", 0))})
	if not ProfileManager.owns_hat(_sel_hat):
		items.append({"kind": &"hat", "id": _sel_hat,
			"price": int(HatCatalog.get_def(_sel_hat).get("price", 0))})
	return items


func _cart_total(items: Array[Dictionary]) -> int:
	var total := 0
	for it in items:
		total += int(it["price"])
	return total


## 保存すると今の見た目から何か変わるか。保存されない物(他のキャラで試着中の
## 未所持コスチューム)の違いは数えない
func _outfit_differs() -> bool:
	if _sel_skin != ProfileManager.skin or _sel_hat != ProfileManager.hat_id:
		return true
	var costume_counts := _sel_skin == COSTUME_SKIN or ProfileManager.owns_costume(_sel_costume)
	return costume_counts and (_sel_costume != ProfileManager.costume_id
		or _sel_colors != ProfileManager.costume_colors)


func _update_cart_list() -> void:
	for child in cart_list.get_children():
		child.queue_free()
	_add_cart_row(tr("キャラクター"), tr(String(Humanoid.SKINS[_sel_skin]["name"])), "")
	if _sel_skin == COSTUME_SKIN:
		var owned := ProfileManager.owns_costume(_sel_costume)
		_add_cart_row(tr("スキン柄"), _item_name(&"costume", _sel_costume),
			_price_caption(owned, int(CostumeCatalog.get_def(_sel_costume).get("price", 0))))
	var hat_owned := ProfileManager.owns_hat(_sel_hat)
	_add_cart_row(tr("帽子"), _item_name(&"hat", _sel_hat),
		_price_caption(hat_owned, int(HatCatalog.get_def(_sel_hat).get("price", 0))))


func _add_cart_row(category: String, item_name: String, caption: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var cat_lbl := Label.new()
	cat_lbl.text = category
	cat_lbl.custom_minimum_size = Vector2(110, 0)
	cat_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	row.add_child(cat_lbl)
	var name_lbl := Label.new()
	name_lbl.text = item_name
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)
	var cap_lbl := Label.new()
	cap_lbl.text = caption
	cap_lbl.add_theme_color_override("font_color",
		Color(0.5, 0.9, 0.6) if caption == tr("所持済み") else Color(0.9, 0.75, 0.4))
	row.add_child(cap_lbl)
	cart_list.add_child(row)


## 確定ボタンは状態で3通り: 未所持があれば「まとめて買う」、全部持っていて見た目が
## 変わるなら「着替える」、何も変わらなければ押せない
func _update_checkout() -> void:
	var items := _cart_items()
	if not items.is_empty():
		checkout_btn.text = tr("このコーデで買う（💎%d）") % _cart_total(items)
		checkout_btn.disabled = false
	elif _outfit_differs():
		checkout_btn.text = tr("このコーデに着替える")
		checkout_btn.disabled = false
	else:
		checkout_btn.text = tr("いまのコーデです")
		checkout_btn.disabled = true


func _on_checkout_pressed() -> void:
	var items := _cart_items()
	if items.is_empty():
		_wear_selected_outfit()
		_say(tr("おきがえ完了です！ よくお似合いです♪"))
		stage.cheer()
		_rebuild()
		return
	var total := _cart_total(items)
	if total > ProfileManager.premium_currency:
		_say(tr("ジェムが少し足りないみたいです…"))
		status_label.text = tr(FAILURE_MESSAGES["not_enough_gems"])
		_open_gem_overlay()
		return
	var lines := PackedStringArray()
	for it in items:
		lines.append("• %s  %s" % [_item_name(it["kind"], it["id"]), _price_caption(false, int(it["price"]))])
	var msg := tr("次のアイテムを購入して、このコーデに着替えます。") + "\n" + "\n".join(lines) + "\n" \
		+ tr("合計 💎%d（購入後の残高: 💎%d）") % [total, ProfileManager.premium_currency - total]
	_open_confirm_overlay(msg, _do_checkout.bind(items))


func _do_checkout(items: Array[Dictionary]) -> void:
	for it in items:
		# 失敗理由は purchase_failed → _on_purchase_failed() が出す。途中まで買えた物は
		# 所持品として残る(ジェムと引き換え済み)ので、表示だけ最新にして止める
		if not PurchaseManager.purchase_item(it["kind"], it["id"]):
			_rebuild()
			return
	_wear_selected_outfit()
	status_label.text = tr("%d点のアイテムを購入して着替えました！") % items.size()
	_say(tr("お買い上げありがとうございます！ そのまま着ていってくださいね♪"))
	stage.cheer()
	_rebuild()


## 試着中のコーデを保存する。ProfileManager の各 setter は未所持なら何もしない
## (所持ガード)ので、買っていない物が紛れても保存されることはない
func _wear_selected_outfit() -> void:
	ProfileManager.set_skin(_sel_skin)
	if ProfileManager.owns_costume(_sel_costume):
		# PackedColorArray は参照渡し。そのまま渡すと、保存後にカラーを試着しただけで
		# ProfileManager 側の色まで(保存せずに)書き換わる(tests/shop_fitting で実際に検出)
		ProfileManager.set_costume(_sel_costume, _sel_colors.duplicate())
	if ProfileManager.owns_hat(_sel_hat):
		ProfileManager.set_hat(_sel_hat)


# --- 店員さんのひとこと -----------------------------------------------------

func _say(text: String) -> void:
	speech_label.text = text
	speech_bubble.show()
	if _speech_tween:
		_speech_tween.kill()
	speech_bubble.modulate.a = 0.0
	_speech_tween = create_tween()
	_speech_tween.tween_property(speech_bubble, "modulate:a", 1.0, 0.18)


# --- ジェム(通貨パック) ---------------------------------------------------

func _open_gem_overlay() -> void:
	pack_status_label.text = ""
	gem_overlay.show()
	gem_close_btn.grab_focus()


func _close_gem_overlay() -> void:
	gem_overlay.hide()


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
		name_lbl.text = tr(String(def.get("name", "")))
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(name_lbl)

		var price_lbl := Label.new()
		price_lbl.text = String(def.get("display_price", ""))
		price_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		price_lbl.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
		vbox.add_child(price_lbl)

		var buy_btn := Button.new()
		buy_btn.text = tr("購入する")
		buy_btn.pressed.connect(_on_buy_pack_pressed.bind(id, buy_btn))
		vbox.add_child(buy_btn)

		box.add_child(vbox)
		pack_row.add_child(box)


## C-02対策: 購入確認モーダルを開く(パック/アイテム共通)。「購入する」を押すまで
## on_confirmは実行されない
func _open_confirm_overlay(message: String, on_confirm: Callable) -> void:
	confirm_message_label.text = message
	_pending_confirm_action = on_confirm
	confirm_overlay.show()
	# 誤ってEnterで即購入しないよう、既定は「やめる」(quit_menu.gdと同じ思想)
	confirm_cancel_btn.grab_focus()


func _close_confirm_overlay() -> void:
	confirm_overlay.hide()
	_pending_confirm_action = Callable()


func _on_confirm_buy_pressed() -> void:
	var action := _pending_confirm_action
	_close_confirm_overlay()
	if action.is_valid():
		action.call()


func _on_buy_pack_pressed(pack_id: StringName, btn: Button) -> void:
	var def := CurrencyPackCatalog.get_def(pack_id)
	var msg := tr("『%s』を%sで購入します。よろしいですか？") % [
		tr(String(def.get("name", ""))), String(def.get("display_price", ""))]
	_open_confirm_overlay(msg, _do_buy_pack_pressed.bind(pack_id, btn))


## ⑥実課金プロバイダはブラウザでのStripe決済を挟むため、処理中(最大約31分)は
## 二重購入防止のため元のボタンを一時的にキャンセルボタンへ差し替える
## (無効化するだけだと、長い待ち時間の間ユーザーが購入を諦める手段が無くなるため)
func _do_buy_pack_pressed(pack_id: StringName, btn: Button) -> void:
	var original_text := btn.text
	var buy_callable := _on_buy_pack_pressed.bind(pack_id, btn)
	var cancel_callable := _on_cancel_pack_pressed.bind(btn)
	btn.pressed.disconnect(buy_callable)
	btn.pressed.connect(cancel_callable)
	btn.text = tr("処理中...(キャンセル)")

	# H-10対策: OS.shell_open()がポップアップブロック等で実際にはチェックアウトページを
	# 開けていなくても、このゲーム側からは成否が分からない。検知は諦め、URLが分かり次第
	# 常に「開かない場合はこちら」の再試行リンクを出しておくことで逃げ道を作る
	var fallback_btn := Button.new()
	fallback_btn.text = tr("開かない場合はこちら")
	fallback_btn.visible = false
	var fallback_url := ""
	var on_checkout_opened := func(pid: StringName, url: String) -> void:
		if pid != pack_id or not is_instance_valid(fallback_btn):
			return
		fallback_url = url
		fallback_btn.visible = true
	fallback_btn.pressed.connect(func(): OS.shell_open(fallback_url))
	PurchaseManager.checkout_url_ready.connect(on_checkout_opened)
	btn.get_parent().add_child(fallback_btn)

	var ok: bool = await PurchaseManager.buy_currency_pack(pack_id)

	PurchaseManager.checkout_url_ready.disconnect(on_checkout_opened)
	if is_instance_valid(fallback_btn):
		fallback_btn.queue_free()
	if is_instance_valid(btn):
		btn.pressed.disconnect(cancel_callable)
		btn.pressed.connect(buy_callable)
		btn.text = original_text
	# ⑥決済待ち(最大約31分)の間にユーザーが画面を離れてこのインスタンス自体が
	# queue_free()されている場合があるため、status_labelへのアクセス前にガードする
	if ok and is_instance_valid(status_label):
		var def := CurrencyPackCatalog.get_def(pack_id)
		var msg := tr("💎%d を獲得しました！") % int(def.get("gems", 0))
		status_label.text = msg
		pack_status_label.text = msg


func _on_cancel_pack_pressed(_btn: Button) -> void:
	PurchaseManager.cancel_pending_purchase()


# --- 共通 -------------------------------------------------------------------

func _owns(kind: StringName, id: StringName) -> bool:
	match kind:
		&"costume":
			return ProfileManager.owns_costume(id)
		&"hat":
			return ProfileManager.owns_hat(id)
		_:
			return false


func _item_def(kind: StringName, id: StringName) -> Dictionary:
	return CostumeCatalog.get_def(id) if kind == &"costume" else HatCatalog.get_def(id)


func _item_name(kind: StringName, id: StringName) -> String:
	return tr(String(_item_def(kind, id).get("name", String(id))))


func _on_purchase_failed(reason: String) -> void:
	status_label.text = tr(FAILURE_MESSAGES.get(reason, reason))


# --- ③プレゼント -------------------------------------------------------------

## プレゼントできるのは、最後に選んだ有料のコスチューム/帽子1品
func _update_gift_button() -> void:
	# M-03対策: プレゼントはEOSのP2Pメッシュ経由でしか配信できず、Web版では
	# EOSGが恒久的に動作しない(room_match_dialog.gd:57と同じ制約)ため、
	# 挑戦させて後から失敗理由を出すのではなく、ここで先に無効化して伝える
	if OS.has_feature("web"):
		gift_btn.disabled = true
		gift_btn.tooltip_text = tr("Web版ではプレゼント機能は利用できません（EOSのP2P接続が必要なため）")
		return
	var price := int(_item_def(_focus_kind, _focus_id).get("price", 0)) if _focus_id != &"" else 0
	gift_btn.disabled = price <= 0
	gift_btn.tooltip_text = tr("「%s」をフレンドに贈ります") % _item_name(_focus_kind, _focus_id) \
		if price > 0 else tr("贈りたい有料のアイテムを選んでください")


## ③プレゼント相手選択ピッカーを開く（登録済みフレンド全員を表示、送信結果で成否を判定する）
func _open_gift_picker(kind: StringName, id: StringName) -> void:
	_pending_gift_kind = kind
	_pending_gift_id = id
	gift_title_label.text = tr("「%s」を贈る相手を選択") % _item_name(kind, id)

	for child in gift_friend_list.get_children():
		child.queue_free()

	var friends := await FriendManager.get_friends()
	if friends.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = tr("フレンドがいません。プレゼントを贈るにはまずフレンド登録してください。")
		empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		gift_friend_list.add_child(empty_lbl)

		# ロビー内オーバーレイ表示中(get_tree().current_scene != self)は、試合を離れる遷移に
		# なってしまうため導線を出さない(_on_back_pressed()と同じ判定、friend_screen.gd:57-58の
		# shop_btn.hide()と同じ確立済みイディオム)
		if get_tree().current_scene == self:
			var add_friend_btn := Button.new()
			add_friend_btn.text = tr("フレンドを追加する")
			add_friend_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			add_friend_btn.pressed.connect(_on_add_friend_pressed)
			gift_friend_list.add_child(add_friend_btn)
	else:
		for f in friends:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 12)

			var name_lbl := Label.new()
			name_lbl.text = String(f.get("name", "Friend"))
			name_lbl.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED  # プレイヤー名は利用者の入力(L-09)
			name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(name_lbl)

			var send_btn := Button.new()
			send_btn.text = tr("贈る")
			send_btn.pressed.connect(_on_send_gift_pressed.bind(String(f.get("id", "")), String(f.get("name", "Friend"))))
			row.add_child(send_btn)

			gift_friend_list.add_child(row)

	gift_overlay.show()


func _close_gift_picker() -> void:
	gift_overlay.hide()


## L-05: フレンドが0人の状態から「フレンドを追加する」を押したときの導線。
## 常にget_tree().current_scene == selfの状態でしか出さないため、埋め込み時の
## closed.emit()経路は考慮不要(専用シーン遷移のみでよい)
func _on_add_friend_pressed() -> void:
	_close_gift_picker()
	get_tree().change_scene_to_file(FRIEND_SCENE)


func _on_send_gift_pressed(friend_puid: String, friend_name: String) -> void:
	var kind := _pending_gift_kind
	var id := _pending_gift_id
	_close_gift_picker()

	# ⑥ジェムを消費する前に、相手が既に所持していないか問い合わせて確認する
	# (ギフト配信自体が既にP2P・オンライン限定なので、この確認だけ新しい制約が増えるわけではない)
	status_label.text = tr("%s さんの所持状況を確認中...") % friend_name
	var check: Dictionary = await GiftManager.query_owned(friend_puid, kind, id)
	if not check.get("reachable", false):
		status_label.text = tr("%s さんに届けられませんでした（相手が起動していないか接続できませんでした）。") % friend_name
		return
	if check.get("owned", false):
		status_label.text = tr("%s さんは既にこのアイテムを持っています。") % friend_name
		return

	if not PurchaseManager.spend_for_gift(kind, id):
		status_label.text = tr("ジェムが足りません")
		return

	status_label.text = tr("%s さんに送信中...") % friend_name
	var ok: bool = await GiftManager.send_gift(friend_puid, kind, id)
	if ok:
		status_label.text = tr("%s さんにプレゼントを贈りました！") % friend_name
		_say(tr("プレゼント、きっと喜ばれますよ♪"))
		stage.cheer()
	else:
		PurchaseManager.refund_gift(kind, id)
		status_label.text = tr("%s さんに届けられませんでした（相手が起動していないか接続できませんでした）。ジェムは返金されました。") % friend_name


func _on_gift_received(kind: StringName, id: StringName, from_name: String) -> void:
	status_label.text = tr("%s さんから「%s」をプレゼントされました！") % [from_name, _item_name(kind, id)]
	_rebuild()


func _on_back_pressed() -> void:
	if get_tree().current_scene == self:
		get_tree().change_scene_to_file(TITLE_SCENE)
	else:
		closed.emit()
