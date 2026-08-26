extends Control

## ④フレンド画面（専用シーン、①きせかえ画面と同じ画面遷移方式）。
## Steamフレンド一覧をオンライン/オフラインで表示し、オンラインの友達は
## 自分がロビー中であればロビーへ招待できる。プレゼント送付自体は
## ③ショップ画面から行う（アイテムを選んでから相手を選ぶ導線のため）。

const TITLE_SCENE := "res://scenes/title.tscn"
const SHOP_SCENE := "res://scenes/shop_screen.tscn"

@onready var back_btn: Button = $TopBar/BackButton
@onready var shop_btn: Button = $TopBar/ShopButton
@onready var online_list: VBoxContainer = $ContentMargin/Scroll/MainVBox/OnlineSection/List
@onready var offline_list: VBoxContainer = $ContentMargin/Scroll/MainVBox/OfflineSection/List
@onready var status_label: Label = $ContentMargin/Scroll/MainVBox/StatusLabel


func _ready() -> void:
	back_btn.pressed.connect(_on_back_pressed)
	shop_btn.pressed.connect(_on_shop_pressed)
	refresh()


func refresh() -> void:
	for child in online_list.get_children():
		child.queue_free()
	for child in offline_list.get_children():
		child.queue_free()

	var friends := FriendManager.get_friends()
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

	if not SteamManager.is_steam_available:
		status_label.text = "Steamに接続されていないため、フレンド一覧はサンプル表示です。"
	else:
		status_label.text = ""


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
		invite_btn.disabled = SteamManager.current_lobby_id == 0
		invite_btn.pressed.connect(_on_invite_pressed.bind(int(f.get("steam_id", 0)), String(f.get("name", "Friend"))))
		row.add_child(invite_btn)

	return row


func _on_invite_pressed(friend_steam_id: int, friend_name: String) -> void:
	if FriendManager.invite_to_lobby(friend_steam_id):
		status_label.text = "%s さんをロビーに招待しました。" % friend_name
	else:
		status_label.text = "招待に失敗しました（ロビーに参加していないか、フレンドがオフラインです）。"


func _on_shop_pressed() -> void:
	get_tree().change_scene_to_file(SHOP_SCENE)


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(TITLE_SCENE)
