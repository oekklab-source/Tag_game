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
## ⑥フレンド詳細ダイアログのスキンプレビュー。scenes/hud/lobby_panel.gdの
## _roster_preview()と同じ部品・同じ静止表示の流儀(request_static_render)を使う
const COSTUME_PREVIEW_SCENE := preload("res://scenes/costume_preview.tscn")
const DETAIL_PREVIEW_SIZE := 96

## hud.gdがロビー待機中にオーバーレイとして埋め込んだ場合に、閉じる操作の代わりに発火する。
## タイトルから専用シーンとして開かれた場合(get_tree().current_scene == self)は
## 従来通りタイトルへのシーン遷移を行うため、その場合は発火しない
signal closed

@onready var back_btn: Button = $TopBar/BackButton
@onready var shop_btn: Button = $TopBar/ShopButton
@onready var refresh_btn: Button = $TopBar/RefreshButton
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

var _search_mode: OptionButton
var _search_input: LineEdit
var _search_results: VBoxContainer
var _detail_dialog: AcceptDialog
var _detail_preview: Control
var _detail_name_lbl: Label
var _detail_online_lbl: Label
var _detail_rating_lbl: Label
var _detail_record_lbl: Label
var _detail_last_seen_lbl: Label


func _ready() -> void:
	back_btn.pressed.connect(_on_back_pressed)
	shop_btn.pressed.connect(_on_shop_pressed)
	refresh_btn.pressed.connect(refresh)
	# オーバーレイ埋め込み時はショップへのシーン遷移が待機中の部屋を巻き込んで壊すため
	# 導線ごと隠す(閉じてからhud側の「ショップ」ボタンで開き直せば良い)
	if get_tree().current_scene != self:
		shop_btn.hide()
	_build_code_section()
	_build_search_section()
	_build_requests_section()
	_build_remove_confirm_dialog()
	_build_friend_detail_dialog()
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


## ⑤フレンド検索セクション。名前完全一致/コード完全一致の2モードで、検索結果の
## 行から個別に追加できる。元の設計(friend-api)が意図的に列挙・部分一致を許さないため、
## 検索結果は「一致した本人」に限られる(見つからない場合はその旨を表示するだけ)
func _build_search_section() -> void:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 10)
	var title := Label.new()
	title.text = "フレンドを検索"
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.4, 1))
	title.add_theme_font_size_override("font_size", 20)
	section.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	_search_mode = OptionButton.new()
	_search_mode.add_item("名前で検索")
	_search_mode.add_item("コードで検索")
	row.add_child(_search_mode)
	_search_input = LineEdit.new()
	_search_input.placeholder_text = "名前 or コードを入力(完全一致)"
	_search_input.custom_minimum_size = Vector2(220, 0)
	row.add_child(_search_input)
	var search_btn := Button.new()
	search_btn.text = "検索"
	search_btn.pressed.connect(_on_search_pressed)
	row.add_child(search_btn)
	section.add_child(row)

	_search_results = VBoxContainer.new()
	_search_results.add_theme_constant_override("separation", 10)
	section.add_child(_search_results)

	main_vbox.add_child(section)
	main_vbox.move_child(section, 1)


func _on_search_pressed() -> void:
	for c in _search_results.get_children():
		c.queue_free()
	var query := _search_input.text.strip_edges()
	if query.is_empty():
		return
	var mode := "name" if _search_mode.selected == 0 else "code"
	var res := await FriendManager.search_user(query, mode)
	if not res.get("found", false):
		var reason := String(res.get("reason", ""))
		var msg := "検索回数の上限に達しました。しばらくしてから試してください。" \
			if reason == "rate_limited" else "見つかりませんでした。"
		_search_results.add_child(_build_empty_label(msg))
		return
	for m in res.get("matches", []):
		_search_results.add_child(_build_search_result_row(m))


## 検索結果1件の行。表示名は入力側の呼称(相手が変更していても検索クエリのまま)なので
## nameモードでの複数一致時は「コード表記」で本人を見分けてもらう
func _build_search_result_row(m: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var name_lbl := Label.new()
	name_lbl.text = "%s（コード: %s）" % [String(m.get("name", "")), String(m.get("code", ""))]
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)
	var add_btn := Button.new()
	add_btn.text = "追加"
	var code := String(m.get("code", ""))
	add_btn.pressed.connect(_on_add_from_search_pressed.bind(code, add_btn))
	row.add_child(add_btn)
	return row


func _on_add_from_search_pressed(code: String, source_btn: Button) -> void:
	var res := await FriendManager.send_friend_request(code)
	if res.get("ok", false):
		status_label.text = "%s さんにリクエストを送りました。" % String(res.get("target_name", "フレンド"))
		source_btn.disabled = true
		source_btn.text = "送信済み"
	else:
		status_label.text = "リクエストの送信に失敗しました。"


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
	main_vbox.move_child(section, 2)


## 削除ボタン押下時に出す「本当に削除しますか？」確認ダイアログ。
## OK/Cancelを1つ使い回し、対象は_pending_remove_puid/nameに保持する
func _build_remove_confirm_dialog() -> void:
	_remove_confirm_dialog = ConfirmationDialog.new()
	_remove_confirm_dialog.title = "フレンド削除の確認"
	_remove_confirm_dialog.ok_button_text = "削除する"
	_remove_confirm_dialog.cancel_button_text = "キャンセル"
	_remove_confirm_dialog.confirmed.connect(_on_remove_confirmed)
	add_child(_remove_confirm_dialog)


## ⑤⑥フレンド1人の詳細(オンライン状態・戦績・レート・最終ログイン・スキン)を見る
## ダイアログ。1つ使い回し、_show_friend_detail_dialog()が内容を書き換えて開く
func _build_friend_detail_dialog() -> void:
	_detail_dialog = AcceptDialog.new()
	_detail_dialog.title = "フレンド情報"
	_detail_dialog.ok_button_text = "閉じる"

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.custom_minimum_size = Vector2(320, 0)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	_detail_preview = COSTUME_PREVIEW_SCENE.instantiate()
	_detail_preview.custom_minimum_size = Vector2(DETAIL_PREVIEW_SIZE, DETAIL_PREVIEW_SIZE)
	head.add_child(_detail_preview)
	var head_col := VBoxContainer.new()
	_detail_name_lbl = Label.new()
	_detail_name_lbl.add_theme_font_size_override("font_size", 20)
	head_col.add_child(_detail_name_lbl)
	_detail_online_lbl = Label.new()
	head_col.add_child(_detail_online_lbl)
	_detail_last_seen_lbl = Label.new()
	_detail_last_seen_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	head_col.add_child(_detail_last_seen_lbl)
	head.add_child(head_col)
	col.add_child(head)

	_detail_rating_lbl = Label.new()
	col.add_child(_detail_rating_lbl)
	_detail_record_lbl = Label.new()
	col.add_child(_detail_record_lbl)

	_detail_dialog.add_child(col)
	add_child(_detail_dialog)


func _on_show_detail_pressed(friend_puid: String) -> void:
	var profile := await FriendManager.get_friend_profile(friend_puid)
	if not profile.get("ok", false):
		status_label.text = "フレンド情報の取得に失敗しました。"
		return
	_detail_name_lbl.text = String(profile.get("name", "Friend"))
	var online := bool(profile.get("online", false))
	_detail_online_lbl.text = "オンライン" if online else "オフライン"
	_detail_online_lbl.add_theme_color_override("font_color",
		Color(0.4, 0.9, 0.5) if online else Color(0.6, 0.6, 0.65))
	_detail_last_seen_lbl.text = _format_last_seen(int(profile.get("last_seen", 0)), online)

	if profile.get("stats_available", false):
		var rating := int(profile.get("rating", 1500))
		_detail_rating_lbl.text = "レート: [%s] %d Pt" % [RankingManager.tier_name(rating), rating]
		var matches := int(profile.get("matches_played", 0))
		_detail_record_lbl.text = "戦績: %d戦（にげる勝ち %d / おに勝ち %d）" % \
			[matches, int(profile.get("runner_wins", 0)), int(profile.get("hunter_wins", 0))]
		var costume_id := StringName(profile.get("costume_id", "default"))
		var colors := ProfileManager.colors_from_html(profile.get("costume_colors", []))
		var hat_id := StringName(profile.get("hat_id", "none"))
		_detail_preview.call_deferred("set_interactive", false)
		_detail_preview.call_deferred("show_costume", costume_id, colors)
		_detail_preview.call_deferred("show_hat", hat_id)
		_detail_preview.call_deferred("request_static_render")
	else:
		_detail_rating_lbl.text = "戦績データがまだありません。"
		_detail_record_lbl.text = ""
		# ダイアログは使い回しなので、前回開いた別のフレンドの見た目が残らないよう
		# きほん姿にリセットする
		_detail_preview.call_deferred("set_interactive", false)
		_detail_preview.call_deferred("show_costume", CostumeCatalog.DEFAULT_ID,
			CostumeCatalog.default_colors(CostumeCatalog.DEFAULT_ID))
		_detail_preview.call_deferred("show_hat", HatCatalog.DEFAULT_ID)
		_detail_preview.call_deferred("request_static_render")

	_detail_dialog.popup_centered()


## last_seenは-api側のミリ秒UNIX時刻。オンライン中/未取得(0)は個別に文言を出す
func _format_last_seen(last_seen_ms: int, online: bool) -> String:
	if online:
		return ""
	if last_seen_ms <= 0:
		return "最終ログイン: 不明"
	var elapsed_sec := int(Time.get_unix_time_from_system()) - int(last_seen_ms / 1000)
	if elapsed_sec < 60:
		return "最終ログイン: たった今"
	if elapsed_sec < 3600:
		return "最終ログイン: %d分前" % (elapsed_sec / 60)
	if elapsed_sec < 86400:
		return "最終ログイン: %d時間前" % (elapsed_sec / 3600)
	return "最終ログイン: %d日前" % (elapsed_sec / 86400)


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

	var detail_btn := Button.new()
	detail_btn.text = "詳細"
	detail_btn.pressed.connect(_on_show_detail_pressed.bind(String(f.get("id", ""))))
	row.add_child(detail_btn)

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
