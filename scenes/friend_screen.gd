extends Control

## ⑤フレンド画面(専用シーン、①きせかえ画面と同じ画面遷移方式)。
## EOS PUIDキーの自前フレンドリストをオンライン/オフラインで表示し、オンラインの
## 友達は自分がロビー中であれば接続先アドレスをコピーして招待できる。プレゼント
## 送付自体は③ショップ画面から行う(アイテムを選んでから相手を選ぶ導線のため)。
##
## フレンドコードの表示・コードでの追加・保留中リクエストの承諾/拒否は、既存の
## 一覧行と同じ「コードでノードを組み立てる」流儀で、.tscnを編集せず_ready()内で
## MainVBoxの先頭に動的に挿入する。

const TITLE_SCENE := "res://scenes/title.tscn"
const SHOP_SCENE := "res://scenes/shop_screen.tscn"

## hud.gdがロビー待機中にオーバーレイとして埋め込んだ場合に、閉じる操作の代わりに発火する。
## タイトルから専用シーンとして開かれた場合(get_tree().current_scene == self)は
## 従来通りタイトルへのシーン遷移を行うため、その場合は発火しない
signal closed

@onready var back_btn: Button = $TopBar/BackButton
@onready var shop_btn: Button = $TopBar/ShopButton
@onready var main_vbox: VBoxContainer = $ContentMargin/Scroll/MainVBox
@onready var online_list: VBoxContainer = $ContentMargin/Scroll/MainVBox/OnlineSection/List
@onready var offline_list: VBoxContainer = $ContentMargin/Scroll/MainVBox/OfflineSection/List
@onready var status_label: Label = $ContentMargin/Scroll/MainVBox/StatusLabel

var _my_code_label: Label
var _code_input: LineEdit
var _requests_list: VBoxContainer
var _remove_confirm_dialog: ConfirmationDialog
var _pending_remove_puid: String = ""
var _pending_remove_name: String = ""


func _ready() -> void:
	back_btn.pressed.connect(_on_back_pressed)
	shop_btn.pressed.connect(_on_shop_pressed)
	# オーバーレイ埋め込み時はショップへのシーン遷移が待機中の部屋を巻き込んで壊すため
	# 導線ごと隠す(閉じてからhud側の「ショップ」ボタンで開き直せば良い)
	if get_tree().current_scene != self:
		shop_btn.hide()
	_build_code_section()
	_build_requests_section()
	_build_remove_confirm_dialog()
	await _sync_my_code()
	await refresh()


func refresh() -> void:
	for child in online_list.get_children():
		child.queue_free()
	for child in offline_list.get_children():
		child.queue_free()

	var friends := await FriendManager.get_friends()
	var any_online := false
	var any_offline := false
	for f in friends:
		if f.get("online", false):
			any_online = true
			online_list.add_child(_build_friend_row(f))
		else:
			any_offline = true
			offline_list.add_child(_build_friend_row(f))

	if not any_online:
		online_list.add_child(_build_empty_label("オンラインのフレンドはいません"))
	if not any_offline:
		offline_list.add_child(_build_empty_label("オフラインのフレンドはいません"))

	if not EosManager.is_eos_available:
		status_label.text = "EOSに接続されていないため、フレンド一覧はサンプル表示です。"
	else:
		status_label.text = ""

	await _refresh_requests()


func _build_code_section() -> void:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 10)

	var code_row := HBoxContainer.new()
	code_row.add_theme_constant_override("separation", 16)
	var code_title := Label.new()
	code_title.text = "マイフレンドコード:"
	code_row.add_child(code_title)
	_my_code_label = Label.new()
	_my_code_label.text = "----"
	_my_code_label.add_theme_color_override("font_color", Color(0.35, 0.8, 1, 1))
	code_row.add_child(_my_code_label)
	var copy_btn := Button.new()
	copy_btn.text = "コピー"
	copy_btn.pressed.connect(_on_copy_code_pressed)
	code_row.add_child(copy_btn)
	section.add_child(code_row)

	var add_row := HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 16)
	_code_input = LineEdit.new()
	_code_input.placeholder_text = "フレンドコードを入力"
	_code_input.custom_minimum_size = Vector2(200, 0)
	add_row.add_child(_code_input)
	var add_btn := Button.new()
	add_btn.text = "フレンドを追加"
	add_btn.pressed.connect(_on_add_friend_pressed)
	add_row.add_child(add_btn)
	section.add_child(add_row)

	main_vbox.add_child(section)
	main_vbox.move_child(section, 0)


func _sync_my_code() -> void:
	var code := await FriendManager.sync_with_backend()
	_my_code_label.text = code if not code.is_empty() else "取得失敗"


func _build_requests_section() -> void:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 10)
	var title := Label.new()
	title.text = "届いているリクエスト"
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.4, 1))
	title.add_theme_font_size_override("font_size", 20)
	section.add_child(title)
	_requests_list = VBoxContainer.new()
	_requests_list.add_theme_constant_override("separation", 10)
	section.add_child(_requests_list)

	main_vbox.add_child(section)
	main_vbox.move_child(section, 1)


## 削除ボタン押下時に出す「本当に削除しますか？」確認ダイアログ。
## OK/Cancelを1つ使い回し、対象は_pending_remove_puid/nameに保持する
func _build_remove_confirm_dialog() -> void:
	_remove_confirm_dialog = ConfirmationDialog.new()
	_remove_confirm_dialog.title = "フレンド削除の確認"
	_remove_confirm_dialog.ok_button_text = "削除する"
	_remove_confirm_dialog.cancel_button_text = "キャンセル"
	_remove_confirm_dialog.confirmed.connect(_on_remove_confirmed)
	add_child(_remove_confirm_dialog)


func _refresh_requests() -> void:
	for child in _requests_list.get_children():
		child.queue_free()

	var requests := await FriendManager.get_pending_requests()
	if requests.is_empty():
		_requests_list.add_child(_build_empty_label("届いているリクエストはありません"))
		return

	for r in requests:
		_requests_list.add_child(_build_request_row(r))


func _build_request_row(r: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)

	var name_lbl := Label.new()
	name_lbl.text = String(r.get("from_name", "Friend"))
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)

	var request_id := String(r.get("request_id", ""))
	var accept_btn := Button.new()
	accept_btn.text = "承諾"
	accept_btn.pressed.connect(_on_respond_pressed.bind(request_id, true))
	row.add_child(accept_btn)

	var decline_btn := Button.new()
	decline_btn.text = "拒否"
	decline_btn.pressed.connect(_on_respond_pressed.bind(request_id, false))
	row.add_child(decline_btn)

	return row


func _build_empty_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	return lbl


func _build_friend_row(f: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)

	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(14, 14)
	dot.color = Color(0.4, 0.9, 0.5) if f.get("online", false) else Color(0.4, 0.4, 0.45)
	row.add_child(dot)

	var name_lbl := Label.new()
	name_lbl.text = String(f.get("name", "Friend"))
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)

	if f.get("online", false):
		var invite_btn := Button.new()
		invite_btn.text = "ロビーに招待"
		invite_btn.disabled = EosManager.current_lobby_id.is_empty()
		invite_btn.pressed.connect(_on_invite_pressed.bind(String(f.get("name", "Friend"))))
		row.add_child(invite_btn)

	var remove_btn := Button.new()
	remove_btn.text = "削除"
	remove_btn.pressed.connect(_confirm_remove_friend.bind(String(f.get("id", "")), String(f.get("name", "Friend"))))
	row.add_child(remove_btn)

	return row


func _on_invite_pressed(friend_name: String) -> void:
	if await FriendManager.invite_to_lobby():
		status_label.text = "接続先をコピーしました。%s さんにDirectConnectタブへ貼り付けてもらってください。" % friend_name
	else:
		status_label.text = "招待に失敗しました(ロビーに参加していないか、接続先アドレスがまだ準備できていません)。"


func _confirm_remove_friend(friend_puid: String, friend_name: String) -> void:
	_pending_remove_puid = friend_puid
	_pending_remove_name = friend_name
	_remove_confirm_dialog.dialog_text = "%s さんをフレンドから削除しますか？" % friend_name
	_remove_confirm_dialog.popup_centered()


func _on_remove_confirmed() -> void:
	var friend_puid := _pending_remove_puid
	var friend_name := _pending_remove_name
	if await FriendManager.remove_friend(friend_puid):
		status_label.text = "%s さんをフレンドから削除しました。" % friend_name
		await refresh()
	else:
		status_label.text = "%s さんの削除に失敗しました。" % friend_name


func _on_add_friend_pressed() -> void:
	var code := _code_input.text.strip_edges()
	var res := await FriendManager.send_friend_request(code)
	if res.get("ok", false):
		status_label.text = "%s さんにリクエストを送りました。" % String(res.get("target_name", "フレンド"))
		_code_input.text = ""
	else:
		status_label.text = "リクエストの送信に失敗しました(コードが正しいか確認してください)。"


func _on_respond_pressed(request_id: String, accept: bool) -> void:
	await FriendManager.respond_to_request(request_id, accept)
	await refresh()


func _on_copy_code_pressed() -> void:
	DisplayServer.clipboard_set(_my_code_label.text)
	status_label.text = "フレンドコードをコピーしました。"


func _on_shop_pressed() -> void:
	if get_tree().current_scene == self:
		get_tree().change_scene_to_file(SHOP_SCENE)


func _on_back_pressed() -> void:
	if get_tree().current_scene == self:
		get_tree().change_scene_to_file(TITLE_SCENE)
	else:
		closed.emit()
