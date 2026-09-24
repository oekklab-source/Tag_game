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
@onready var settings_button: Button = $CenterMenu/VBox/SettingsButton
@onready var quit_button: Button = $CenterMenu/VBox/QuitButton
@onready var status_label: Label = $CenterMenu/VBox/StatusLabel

@onready var room_match_dialog: Control = $RoomMatchDialog
@onready var ranking_dialog: Control = $RankingDialog

@onready var name_confirm_dialog: Control = $NameConfirmDialog
@onready var name_confirm_edit: LineEdit = $NameConfirmDialog/Panel/VBox/NameEdit
@onready var name_confirm_warning: Label = $NameConfirmDialog/Panel/VBox/WarningLabel
@onready var name_confirm_cancel_btn: Button = $NameConfirmDialog/Panel/VBox/Buttons/CancelButton
@onready var name_confirm_join_btn: Button = $NameConfirmDialog/Panel/VBox/Buttons/JoinButton

## C-03 R-4: 起動時のサーバーレート同期通知
@onready var rating_sync_dialog: Control = $RatingSyncDialog
@onready var rating_sync_message: Label = $RatingSyncDialog/Panel/VBox/MessageLabel
@onready var rating_sync_close_btn: Button = $RatingSyncDialog/Panel/VBox/Buttons/CloseButton

## M-07/M-08: エラー履歴・再探索導線
@onready var find_another_room_btn: Button = $CenterMenu/VBox/ErrorActionsRow/FindAnotherRoomButton
@onready var error_history_btn: Button = $CenterMenu/VBox/ErrorActionsRow/ErrorHistoryButton

@onready var error_log_dialog: Control = $ErrorLogDialog
@onready var error_log_list_label: Label = $ErrorLogDialog/Panel/VBox/Scroll/ListLabel
@onready var error_log_close_btn: Button = $ErrorLogDialog/Panel/VBox/Buttons/CloseButton

const COSTUME_SCENE := "res://scenes/costume_screen.tscn"
const SHOP_SCENE := "res://scenes/shop_screen.tscn"
const FRIEND_SCENE := "res://scenes/friend_screen.tscn"
const SETTINGS_SCENE := "res://scenes/settings_screen.tscn"

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
	settings_button.pressed.connect(_on_settings_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	profile_badge_btn.pressed.connect(_on_profile_pressed)
	name_confirm_cancel_btn.pressed.connect(_close_name_confirm_dialog)
	name_confirm_join_btn.pressed.connect(_on_name_confirm_join_pressed)
	# Enter でそのまま参加できるようにする(RV-09。LineEditにフォーカスがある状態で
	# Enterを押しても何も起きないのは、この画面では行き止まりに感じる)
	name_confirm_edit.text_submitted.connect(_on_name_confirm_text_submitted)
	rating_sync_close_btn.pressed.connect(rating_sync_dialog.hide)
	find_another_room_btn.pressed.connect(_on_find_another_room_pressed)
	error_history_btn.pressed.connect(_on_error_history_pressed)
	error_log_close_btn.pressed.connect(error_log_dialog.hide)

	ProfileManager.profile_updated.connect(_update_badge)
	_update_badge()

	# H-01/C-03 R-4: 前回対戦中のサーバー補正(切断ペナルティ含む、R-5でrating-apiへ統合)は
	# 起動後、EOS初期化完了(非同期)を待って反映されるため、ここで一度だけ購読しておけば
	# 発火タイミングによらず必ず通知できる
	RankingManager.server_rating_corrected.connect(_on_server_rating_corrected)

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
	rating_sync_dialog.hide()
	error_log_dialog.hide()

	# 直前の切断理由（ホストが落ちた等）があれば表示する。
	# 以前は旧ロビー画面(main.gd、削除済み)がこれを表示していたが、
	# エントリーシーンが title.tscn に変わってから表示先が無くなっていた
	if not NetworkManager.last_error.is_empty():
		status_label.text = NetworkManager.last_error
		NetworkManager.last_error = ""
	# M-07/M-08: エラー表示・エラー履歴の有無に応じてアクションボタンの表示を更新
	_update_error_action_buttons()

	# Web版: 参加リンク（.../?s=xxxx.trycloudflare.com）から開かれた場合はそのまま参加する。
	# 以前は旧ロビー画面(main.gd、削除済み)だけが対応しており、エントリーシーンの変更で
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
## (?s= 経由の初回プレイヤーはデフォルト名のまま気づかず参加しがちなため)。
##
## **出口は3つある(RV-09で追加)**: 「この名前で参加」/ Enter / 「やめる」・Esc。
## 当初は「変更する」と「この名前で参加」の2択しか無く、参加以外の出口が存在しなかった。
## Escも効かない——QuitMenu は Web かつタイトルでは open() が即 return するため
## (autoload/quit_menu.gd 参照)、招待リンクで開いた Web 版プレイヤーは
## このダイアログから抜けられなかった。
## なお「変更する」ボタンは grab_focus()+select_all() しかしておらず、
## ダイアログを開いた時点と同じ処理＝実質ノーオペだったので「やめる」に置き換えた
## (名前の変更は、開いた時点で既にフォーカス済み・全選択済みの LineEdit で直接できる)。
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


## 「やめる」/ Esc。ダイアログを閉じてタイトルに留まる。
## **NetworkManager.auto_join_done は立てたまま触らない**——「?s= による自動参加は
## 1回だけ」という既存仕様(network_manager.gd の同変数のコメント参照。接続失敗時に
## 同じアドレスへ無限再接続しに行くのを防ぐためのガード)を壊さないため。
## 参加し直したい場合はタイトルのメニューからアドレスを指定して入る
func _close_name_confirm_dialog() -> void:
	if not name_confirm_dialog.visible:
		return
	name_confirm_dialog.hide()
	_pending_join_server = ""
	status_label.text = "参加リンクからの自動参加をやめました。メニューから参加できます。"


## Esc でも閉じられるようにする(RV-09)。
##
## **`_unhandled_input()` ではなく `_input()` でなければ動かない。**
## このダイアログは開いた瞬間に `name_confirm_edit.grab_focus()` するが、
## Godot 4 の LineEdit はフォーカス(編集)中の Esc を「編集終了」として消費するため、
## イベントが `_unhandled_input()` まで降りてこない。実際、headless検証で Esc を流しても
## このハンドラも QuitMenu の `_unhandled_input()` も両方とも発火しないことを確認した。
## `_input()` は GUI(`_gui_input`)より前に呼ばれるので、ここでだけ確実に拾える。
## ダイアログ表示中の Esc しか横取りしないので、他の画面の Esc(QuitMenu)には影響しない。
func _input(event: InputEvent) -> void:
	if not name_confirm_dialog.visible:
		return
	if not event.is_action_pressed("ui_cancel"):
		return
	get_viewport().set_input_as_handled()
	_close_name_confirm_dialog()


## LineEdit で Enter を押したときも「この名前で参加」と同じ扱いにする
func _on_name_confirm_text_submitted(_text: String) -> void:
	_on_name_confirm_join_pressed()


func _on_name_confirm_join_pressed() -> void:
	var new_name := name_confirm_edit.text.strip_edges()
	if not new_name.is_empty() and new_name != ProfileManager.player_name:
		# profile_updated経由でバッジ表示も自動更新される
		var err := ProfileManager.update_profile(new_name)
		if not err.is_empty():
			name_confirm_warning.text = err
			name_confirm_edit.grab_focus()
			name_confirm_edit.select_all()
			return
	name_confirm_dialog.hide()
	status_label.text = "参加リンクからホストへ接続中..."
	# L-06検討時の判断: ここにローディングスピナーは付けない。start_client()は
	# awaitなしで即座にchange_scene_to_file(world.tscn)するため、このシーンごと
	# 次フレームで破棄されアニメーションが一切目に映らない(付け忘れではない)
	# _ready() の最中はまだ親がこのシーンの子を追加中で、そこから change_scene すると
	# 「Parent node is busy adding/removing children」で失敗する。フレーム境界まで遅らせる
	NetworkManager.start_client.call_deferred(_pending_join_server)


func _update_badge() -> void:
	profile_badge_name.text = ProfileManager.player_name
	profile_badge_rating.text = "%s %d Pt" % [RankingManager.tier_name(ProfileManager.rating), ProfileManager.rating]
	profile_badge_color.color = RankingManager.tier_color(ProfileManager.rating)


## C-03 R-4: 起動時、サーバー権威のレートとローカル値に差があった場合の同期通知
## (C-03 R-5で切断ペナルティもrating-apiへ統合したため、対戦中の切断で課された
## レートペナルティもこのダイアログが拾う。H-01の専用PenaltyNoticeDialogは廃止した)
func _on_server_rating_corrected(_old_rating: int, new_rating: int, delta: int) -> void:
	rating_sync_message.text = rating_sync_dialog_text(delta, new_rating)
	rating_sync_dialog.show()


## C-03 R-4: 起動時レート同期ダイアログの本文(純粋関数、tests/で直接検証)
static func rating_sync_dialog_text(delta: int, new_rating: int) -> String:
	var sign_str := "+" if delta >= 0 else ""
	return "前回の対戦時には確定していなかったレートがサーバーと同期され、%s%d Pt 補正されました（現在 %d Pt）。" \
		% [sign_str, delta, new_rating]


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


## H-07: 設定画面への遷移
func _on_settings_pressed() -> void:
	get_tree().change_scene_to_file(SETTINGS_SCENE)


func _on_quit_pressed() -> void:
	# H-06: 終了確認の経路を QuitMenu に統一(Web版はquit_buttonごと非表示のままなので、
	# ここに来るのは常にデスクトップ版。QuitMenu.open()のWeb分岐とは競合しない)
	QuitMenu.open()


## M-07/M-08: 直前のエラー表示・エラー履歴に応じてアクションボタンの表示を切り替える。
## 「別の部屋をさがす」: status_label.textが非空の時だけ
## 「接続エラーの履歴」: error_logが空でない時だけ(見るべき履歴が無いのに常に見える
## クラッターを避けるため)
func _update_error_action_buttons() -> void:
	find_another_room_btn.visible = not status_label.text.is_empty()
	error_history_btn.visible = not NetworkManager.error_log.is_empty()


func _on_find_another_room_pressed() -> void:
	room_match_dialog.open()


func _on_error_history_pressed() -> void:
	_refresh_error_log_dialog()
	error_log_dialog.show()


## 新しいエラーを上に表示する(error_logは古い→新しい順の配列のため反転する)
func _refresh_error_log_dialog() -> void:
	if NetworkManager.error_log.is_empty():
		error_log_list_label.text = "エラー履歴はありません。"
		return
	var reversed := NetworkManager.error_log.duplicate()
	reversed.reverse()
	var lines: Array[String] = []
	for i in reversed.size():
		lines.append("%d. %s" % [i + 1, reversed[i]])
	error_log_list_label.text = "\n\n".join(lines)
