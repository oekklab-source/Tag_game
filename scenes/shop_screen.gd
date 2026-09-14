extends Control

## ②③ショップ画面（専用シーン、①きせかえ画面と同じ画面遷移方式）。
## 通貨パック（ジェム、モック実装）の購入と、ジェムでのコスチューム/帽子購入、
## およびそれらの③プレゼント送付（同時オンラインのフレンドへ即時配信）を行う。

const TITLE_SCENE := "res://scenes/title.tscn"

## hud.gdがロビー待機中にオーバーレイとして埋め込んだ場合に、閉じる操作の代わりに発火する。
## タイトルから専用シーンとして開かれた場合(get_tree().current_scene == self)は
## 従来通りタイトルへのシーン遷移を行うため、その場合は発火しない
signal closed

@onready var gem_label: Label = $TopBar/GemBadge/HBox/GemLabel
@onready var back_btn: Button = $TopBar/BackButton
@onready var pack_row: HBoxContainer = $ContentMargin/Scroll/MainVBox/PackSection/PackRow
@onready var item_grid: GridContainer = $ContentMargin/Scroll/MainVBox/ItemSection/ItemGrid
@onready var status_label: Label = $ContentMargin/Scroll/MainVBox/StatusLabel

@onready var gift_overlay: Control = $GiftPickerOverlay
@onready var gift_friend_list: VBoxContainer = $GiftPickerOverlay/Panel/VBox/FriendListContainer
@onready var gift_cancel_btn: Button = $GiftPickerOverlay/Panel/VBox/CancelButton
@onready var gift_title_label: Label = $GiftPickerOverlay/Panel/VBox/TitleLabel

@onready var confirm_overlay: Control = $ConfirmOverlay
@onready var confirm_message_label: Label = $ConfirmOverlay/Panel/VBox/MessageLabel
@onready var confirm_cancel_btn: Button = $ConfirmOverlay/Panel/VBox/Buttons/CancelButton
@onready var confirm_buy_btn: Button = $ConfirmOverlay/Panel/VBox/Buttons/BuyButton

const RARITY_COLORS := {
	&"common": Color(0.6, 0.6, 0.65),
	&"rare": Color(0.35, 0.7, 1.0),
	&"epic": Color(0.75, 0.4, 0.95),
	&"legendary": Color(1.0, 0.75, 0.2),
}

## ⑥PurchaseManagerが返す理由識別子(英語定数)を、画面表示用の日本語文言に変換する。
## 未知の識別子(purchase_item系が返す既存の生の日本語メッセージ等)はそのまま表示する
const FAILURE_MESSAGES := {
	"unknown_pack": "不明な通貨パックです",
	"network_error": "通信エラーが発生しました。時間をおいて再度お試しください",
	"user_cancelled": "購入がキャンセルされました",
	"purchase_timeout": "決済の確認がタイムアウトしました。次回起動時に自動的に再確認されます。",
}

var _pending_gift_kind: StringName = &""
var _pending_gift_id: StringName = &""

## C-02対策: 購入は必ずこの確認オーバーレイを経由させ、即時実行を防ぐ
var _pending_confirm_action: Callable


func _ready() -> void:
	back_btn.pressed.connect(_on_back_pressed)
	gift_cancel_btn.pressed.connect(_close_gift_picker)
	confirm_cancel_btn.pressed.connect(_close_confirm_overlay)
	confirm_buy_btn.pressed.connect(_on_confirm_buy_pressed)
	PurchaseManager.currency_changed.connect(_refresh_gem_label)
	PurchaseManager.purchase_failed.connect(_on_purchase_failed)
	GiftManager.gift_received.connect(_on_gift_received)
	# ⑥Stripe決済はOSブラウザ経由のため、決済完了直後はゲームウィンドウが
	# フォーカスを失ったままになりやすい。フォーカス復帰時に付与済みジェム残高で
	# 明示的に再同期し、「購入直後は表示が更新されず、画面を出入りするまで
	# 反映されない」症状(currency_changed自体は正しく発火・保存されているのに
	# 表示だけ古いまま、という実機報告)を防ぐ
	get_window().focus_entered.connect(_refresh_gem_label)
	gift_overlay.hide()
	confirm_overlay.hide()
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
	var msg := "『%s』を%sで購入します。よろしいですか？" % [
		String(def.get("name", "")), String(def.get("display_price", ""))]
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
	btn.text = "処理中...(キャンセル)"

	# H-10対策: OS.shell_open()がポップアップブロック等で実際にはチェックアウトページを
	# 開けていなくても、このゲーム側からは成否が分からない。検知は諦め、URLが分かり次第
	# 常に「開かない場合はこちら」の再試行リンクを出しておくことで逃げ道を作る
	var fallback_btn := Button.new()
	fallback_btn.text = "開かない場合はこちら"
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
		status_label.text = "💎%d を獲得しました！" % int(def.get("gems", 0))


func _on_cancel_pack_pressed(_btn: Button) -> void:
	PurchaseManager.cancel_pending_purchase()


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
	# M-03対策: プレゼントはEOSのP2Pメッシュ経由でしか配信できず、Web版では
	# EOSGが恒久的に動作しない(room_match_dialog.gd:57と同じ制約)ため、
	# 挑戦させて後から失敗理由を出すのではなく、ここで先に無効化して伝える
	if OS.has_feature("web"):
		gift_btn.disabled = true
		gift_btn.tooltip_text = "Web版ではプレゼント機能は利用できません（EOSのP2P接続が必要なため）"
	else:
		gift_btn.disabled = price <= 0
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
	var def := CostumeCatalog.get_def(id) if kind == &"costume" else HatCatalog.get_def(id)
	var price := int(def.get("price", 0))
	var after := ProfileManager.premium_currency - price
	var msg := "『%s』を💎%dで購入します。（購入後の残高: 💎%d）" % [
		String(def.get("name", String(id))), price, after]
	_open_confirm_overlay(msg, _do_buy_item_pressed.bind(kind, id))


func _do_buy_item_pressed(kind: StringName, id: StringName) -> void:
	if PurchaseManager.purchase_item(kind, id):
		var def := CostumeCatalog.get_def(id) if kind == &"costume" else HatCatalog.get_def(id)
		status_label.text = "「%s」を購入しました！" % String(def.get("name", String(id)))
		_setup_item_grid()


func _on_purchase_failed(reason: String) -> void:
	status_label.text = FAILURE_MESSAGES.get(reason, reason)


## ③プレゼント相手選択ピッカーを開く（登録済みフレンド全員を表示、送信結果で成否を判定する）
func _open_gift_picker(kind: StringName, id: StringName) -> void:
	_pending_gift_kind = kind
	_pending_gift_id = id
	var def := CostumeCatalog.get_def(id) if kind == &"costume" else HatCatalog.get_def(id)
	gift_title_label.text = "「%s」を贈る相手を選択" % String(def.get("name", String(id)))

	for child in gift_friend_list.get_children():
		child.queue_free()

	var friends := await FriendManager.get_friends()
	if friends.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "フレンドがいません。プレゼントを贈るにはまずフレンド登録してください。"
		empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		gift_friend_list.add_child(empty_lbl)
	else:
		for f in friends:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 12)

			var name_lbl := Label.new()
			name_lbl.text = String(f.get("name", "Friend"))
			name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(name_lbl)

			var send_btn := Button.new()
			send_btn.text = "贈る"
			send_btn.pressed.connect(_on_send_gift_pressed.bind(String(f.get("id", "")), String(f.get("name", "Friend"))))
			row.add_child(send_btn)

			gift_friend_list.add_child(row)

	gift_overlay.show()


func _close_gift_picker() -> void:
	gift_overlay.hide()


func _on_send_gift_pressed(friend_puid: String, friend_name: String) -> void:
	var kind := _pending_gift_kind
	var id := _pending_gift_id
	_close_gift_picker()

	# ⑥ジェムを消費する前に、相手が既に所持していないか問い合わせて確認する
	# (ギフト配信自体が既にP2P・オンライン限定なので、この確認だけ新しい制約が増えるわけではない)
	status_label.text = "%s さんの所持状況を確認中..." % friend_name
	var check: Dictionary = await GiftManager.query_owned(friend_puid, kind, id)
	if not check.get("reachable", false):
		status_label.text = "%s さんに届けられませんでした（相手が起動していないか接続できませんでした）。" % friend_name
		return
	if check.get("owned", false):
		status_label.text = "%s さんは既にこのアイテムを持っています。" % friend_name
		return

	if not PurchaseManager.spend_for_gift(kind, id):
		status_label.text = "ジェムが足りません"
		return

	status_label.text = "%s さんに送信中..." % friend_name
	var ok: bool = await GiftManager.send_gift(friend_puid, kind, id)
	if ok:
		status_label.text = "%s さんにプレゼントを贈りました！" % friend_name
	else:
		PurchaseManager.refund_gift(kind, id)
		status_label.text = "%s さんに届けられませんでした（相手が起動していないか接続できませんでした）。ジェムは返金されました。" % friend_name


func _on_gift_received(kind: StringName, id: StringName, from_name: String) -> void:
	var def := CostumeCatalog.get_def(id) if kind == &"costume" else HatCatalog.get_def(id)
	status_label.text = "%s さんから「%s」をプレゼントされました！" % [from_name, String(def.get("name", String(id)))]
	_setup_item_grid()


func _on_back_pressed() -> void:
	if get_tree().current_scene == self:
		get_tree().change_scene_to_file(TITLE_SCENE)
	else:
		closed.emit()
