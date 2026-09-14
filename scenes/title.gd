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

@onready var name_confirm_dialog: Control = $NameConfirmDialog
@onready var name_confirm_edit: LineEdit = $NameConfirmDialog/Panel/VBox/NameEdit
@onready var name_confirm_warning: Label = $NameConfirmDialog/Panel/VBox/WarningLabel
@onready var name_confirm_change_btn: Button = $NameConfirmDialog/Panel/VBox/Buttons/ChangeButton
@onready var name_confirm_join_btn: Button = $NameConfirmDialog/Panel/VBox/Buttons/JoinButton

@onready var penalty_notice_dialog: Control = $PenaltyNoticeDialog
@onready var penalty_notice_message: Label = $PenaltyNoticeDialog/Panel/VBox/MessageLabel
@onready var penalty_notice_close_btn: Button = $PenaltyNoticeDialog/Panel/VBox/Buttons/CloseButton

const COSTUME_SCENE := "res://scenes/costume_screen.tscn"
const SHOP_SCENE := "res://scenes/shop_screen.tscn"
const FRIEND_SCENE := "res://scenes/friend_screen.tscn"

## C-05: ?s= 経由の自動参加直前に挟む名前確認ダイアログの、参加先アドレスの一時退避
var _pending_join_server := ""


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
	name_confirm_change_btn.pressed.connect(_on_name_confirm_change_pressed)
	name_confirm_join_btn.pressed.connect(_on_name_confirm_join_pressed)
	penalty_notice_close_btn.pressed.connect(penalty_notice_dialog.hide)

	ProfileManager.profile_updated.connect(_update_badge)
	_update_badge()

	# H-01: 前回対戦中の切断ペナルティは起動後、EOS初期化完了(非同期)を待って反映されるため
	# ここで一度だけ購読しておけば、発火タイミングによらず必ず通知できる
	RankingManager.pending_penalty_applied.connect(_on_pending_penalty_applied)

	# Web版では Quit ボタンを非表示
	if OS.has_feature("web"):
		quit_button.visible = false

	# H-09: ボタン文言を実際の遷移先(Web=DirectConnectタブ既定, デスクトップ=ロビー全体)に合わせる
	play_button.text = "参加する（リンク/アドレス指定）" if OS.has_feature("web") else "オンラインプレイ（部屋を探す・作る）"

	# 初期状態ではダイアログを隠す（①きせかえは専用シーンへ遷移するため、
	# ここで隠すダイアログには含まれない）
	room_match_dialog.hide()
	ranking_dialog.hide()
	name_confirm_dialog.hide()
	penalty_notice_dialog.hide()

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
	_open_name_confirm_dialog(s)


## C-05: 自動参加の直前に、参加する名前を確認・変更する機会を挟む
## (?s= 経由の初回プレイヤーはデフォルト名のまま気づかず参加しがちなため)
func _open_name_confirm_dialog(server: String) -> void:
	_pending_join_server = server
	name_confirm_edit.text = ProfileManager.player_name
	var is_default := _is_default_name(ProfileManager.player_name)
	name_confirm_warning.text = "名前がまだ設定されていません。変更をおすすめします" if is_default else ""
	name_confirm_dialog.show()
	name_confirm_edit.grab_focus()
	name_confirm_edit.select_all()


## 初回自動生成名("Runner_1234"形式)か既定値("Player")のままかを判定する
## (「初回生成名か」を表す永続フラグが無いため、ProfileManager側の生成パターンで代用する)
func _is_default_name(n: String) -> bool:
	if n == "Player":
		return true
	if not n.begins_with("Runner_"):
		return false
	var suffix := n.substr(7)
	return suffix.length() == 4 and suffix.is_valid_int()


func _on_name_confirm_change_pressed() -> void:
	name_confirm_edit.grab_focus()
	name_confirm_edit.select_all()


func _on_name_confirm_join_pressed() -> void:
	var new_name := name_confirm_edit.text.strip_edges()
	if not new_name.is_empty() and new_name != ProfileManager.player_name:
		ProfileManager.update_profile(new_name)  # profile_updated経由でバッジ表示も自動更新される
	name_confirm_dialog.hide()
	status_label.text = "参加リンクからホストへ接続中..."
	# _ready() の最中はまだ親がこのシーンの子を追加中で、そこから change_scene すると
	# 「Parent node is busy adding/removing children」で失敗する。フレーム境界まで遅らせる
	NetworkManager.start_client.call_deferred(_pending_join_server)


func _update_badge() -> void:
	profile_badge_name.text = ProfileManager.player_name
	profile_badge_rating.text = "%s %d Pt" % [RankingManager.tier_name(ProfileManager.rating), ProfileManager.rating]
	profile_badge_color.color = RankingManager.tier_color(ProfileManager.rating)


## H-01: 前回対戦中に切断して課されたレートペナルティを起動時に一度だけ知らせる
func _on_pending_penalty_applied(delta: int) -> void:
	penalty_notice_message.text = "対戦中に切断したため、レートが%d Pt減少しました（現在%d Pt）。" % [abs(delta), ProfileManager.rating]
	penalty_notice_dialog.show()


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
	# H-06: 終了確認の経路を QuitMenu に統一(Web版はquit_buttonごと非表示のままなので、
	# ここに来るのは常にデスクトップ版。QuitMenu.open()のWeb分岐とは競合しない)
	QuitMenu.open()
