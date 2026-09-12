extends Control

## タイトル画面。
## メインメニュー、プロフィールバッジ、ルームマッチ、ランキング、ソロ練習への遷移を統括する。

@onready var profile_badge_name: Label = $TopRightBadge/HBox/NameLabel
@onready var profile_badge_rating: Label = $TopRightBadge/HBox/RatingLabel
@onready var profile_badge_color: ColorRect = $TopRightBadge/HBox/ColorBox
@onready var profile_badge_btn: Button = $TopRightBadge/BadgeButton

@onready var play_button: Button = $CenterMenu/VBox/PlayButton
@onready var solo_button: Button = $CenterMenu/VBox/SoloButton
@onready var profile_button: Button = $CenterMenu/VBox/ProfileButton
@onready var shop_button: Button = $CenterMenu/VBox/ShopButton
@onready var friend_button: Button = $CenterMenu/VBox/FriendButton
@onready var ranking_button: Button = $CenterMenu/VBox/RankingButton
@onready var quit_button: Button = $CenterMenu/VBox/QuitButton
@onready var status_label: Label = $CenterMenu/VBox/StatusLabel

@onready var room_match_dialog: Control = $RoomMatchDialog
@onready var ranking_dialog: Control = $RankingDialog

const COSTUME_SCENE := "res://scenes/costume_screen.tscn"
const SHOP_SCENE := "res://scenes/shop_screen.tscn"
const FRIEND_SCENE := "res://scenes/friend_screen.tscn"


func _ready() -> void:
	# ボタン接続
	play_button.pressed.connect(_on_play_pressed)
	solo_button.pressed.connect(_on_solo_pressed)
	profile_button.pressed.connect(_on_profile_pressed)
	shop_button.pressed.connect(_on_shop_pressed)
	friend_button.pressed.connect(_on_friend_pressed)
	ranking_button.pressed.connect(_on_ranking_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	profile_badge_btn.pressed.connect(_on_profile_pressed)

	ProfileManager.profile_updated.connect(_update_badge)
	_update_badge()

	# Web版では Quit ボタンを非表示
	if OS.has_feature("web"):
		quit_button.visible = false

	# 初期状態ではダイアログを隠す（①きせかえは専用シーンへ遷移するため、
	# ここで隠すダイアログには含まれない）
	room_match_dialog.hide()
	ranking_dialog.hide()

	# 直前の切断理由（ホストが落ちた等）があれば表示する。
	# 以前は scenes/main.gd がロビー画面としてこれを表示していたが、
	# エントリーシーンが title.tscn に変わってから表示先が無くなっていた
	if not NetworkManager.last_error.is_empty():
		status_label.text = NetworkManager.last_error
		NetworkManager.last_error = ""

	# Web版: 参加リンク（.../?s=xxxx.trycloudflare.com）から開かれた場合はそのまま参加する。
	# 以前は scenes/main.gd だけが対応しており、エントリーシーンの変更で
	# リンク共有機能（tools/serve.ps1 が組み立てる参加リンク）が機能しなくなっていた
	_try_auto_join_from_query()


## Web でのみ有効。URL の ?s=<host> をゲームサーバのアドレスとして読む。
## トンネルの URL は起動ごとに変わるので、友達には「リンク1本」で渡せるようにする
func _server_from_query() -> String:
	if not OS.has_feature("web"):
		return ""
	var q: Variant = JavaScriptBridge.eval(
		"new URLSearchParams(location.search).get('s') || ''", true)
	if typeof(q) != TYPE_STRING:
		return ""
	return (q as String).strip_edges()


func _try_auto_join_from_query() -> void:
	var s := _server_from_query()
	if s.is_empty() or NetworkManager.auto_join_done:
		return
	NetworkManager.auto_join_done = true
	status_label.text = "参加リンクからホストへ接続中..."
	# _ready() の最中はまだ親がこのシーンの子を追加中で、そこから change_scene すると
	# 「Parent node is busy adding/removing children」で失敗する。フレーム境界まで遅らせる
	NetworkManager.start_client.call_deferred(s)


func _update_badge() -> void:
	profile_badge_name.text = ProfileManager.player_name
	profile_badge_rating.text = "%s %d Pt" % [RankingManager.tier_name(ProfileManager.rating), ProfileManager.rating]
	profile_badge_color.color = RankingManager.tier_color(ProfileManager.rating)


func _on_play_pressed() -> void:
	room_match_dialog.open()


func _on_solo_pressed() -> void:
	# ソロモードでホスト開始（CPU鬼が出現、①レート変動なし）
	NetworkManager.start_host(false)


## ①きせかえ画面は専用シーンへの画面遷移で開く（旧: 埋め込みダイアログのshow()）
func _on_profile_pressed() -> void:
	get_tree().change_scene_to_file(COSTUME_SCENE)


## ②ショップ画面への遷移
func _on_shop_pressed() -> void:
	get_tree().change_scene_to_file(SHOP_SCENE)


## ④フレンド画面への遷移
func _on_friend_pressed() -> void:
	get_tree().change_scene_to_file(FRIEND_SCENE)


func _on_ranking_pressed() -> void:
	ranking_dialog.open()


func _on_quit_pressed() -> void:
	get_tree().quit()
