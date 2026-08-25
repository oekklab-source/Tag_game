extends Control

## Steam P2P ルームマッチダイアログ。
## Steam ロビーの作成、検索（②レート帯フィルタ・おまかせマッチ）、参加
## および WebSocket 直結（従来のトンネル/LAN接続）をサポート。

signal closed

@onready var room_list_container: VBoxContainer = $Panel/VBox/TabContainer/LobbyList/Scroll/ListContainer
@onready var refresh_btn: Button = $Panel/VBox/TabContainer/LobbyList/TopRow/RefreshButton
@onready var tier_filter: OptionButton = $Panel/VBox/TabContainer/LobbyList/TopRow/TierFilter
@onready var quick_match_btn: Button = $Panel/VBox/TabContainer/LobbyList/TopRow/QuickMatchButton
@onready var create_open_btn: Button = $Panel/VBox/TabContainer/LobbyList/TopRow/CreateOpenButton
@onready var status_label: Label = $Panel/VBox/StatusLabel

# ルーム作成タブ
@onready var room_name_edit: LineEdit = $Panel/VBox/TabContainer/CreateRoom/NameRow/RoomNameEdit
@onready var max_members_spin: SpinBox = $Panel/VBox/TabContainer/CreateRoom/MaxRow/MaxMembersSpin
@onready var my_tier_label: Label = $Panel/VBox/TabContainer/CreateRoom/TierRow/MyTierLabel
@onready var tier_lock_check: CheckBox = $Panel/VBox/TabContainer/CreateRoom/TierRow/TierLockCheck
@onready var do_create_btn: Button = $Panel/VBox/TabContainer/CreateRoom/CreateButton

# ダイレクト接続タブ (WebSocket / LAN)
@onready var direct_addr_edit: LineEdit = $Panel/VBox/TabContainer/DirectConnect/AddrRow/DirectAddrEdit
@onready var direct_join_btn: Button = $Panel/VBox/TabContainer/DirectConnect/DirectJoinButton
@onready var direct_host_btn: Button = $Panel/VBox/TabContainer/DirectConnect/DirectHostButton

@onready var close_btn: Button = $Panel/VBox/BottomRow/CloseButton
@onready var tabs: TabContainer = $Panel/VBox/TabContainer

## TierFilter の選択肢。0=自分の帯のみ, 1=自分の帯±1, 2=すべて
const FILTER_LABELS := ["自分のレート帯のみ", "近いレート帯まで(±1)", "すべて表示"]

var _all_lobbies: Array = []


func _ready() -> void:
	refresh_btn.pressed.connect(_on_refresh_pressed)
	create_open_btn.pressed.connect(func(): tabs.current_tab = 1)
	do_create_btn.pressed.connect(_on_do_create_pressed)
	direct_join_btn.pressed.connect(_on_direct_join_pressed)
	direct_host_btn.pressed.connect(_on_direct_host_pressed)
	close_btn.pressed.connect(_on_close_pressed)
	quick_match_btn.pressed.connect(_on_quick_match_pressed)
	tier_filter.item_selected.connect(func(_i): _render_lobbies())

	for label in FILTER_LABELS:
		tier_filter.add_item(label)

	SteamManager.lobby_match_list.connect(_on_lobbies_received)
	SteamManager.lobby_created.connect(_on_lobby_created)
	SteamManager.lobby_joined.connect(_on_lobby_joined)

	# ③SteamworksはブラウザのWASMサンドボックス上では動作しない（恒久的な制約）。
	# Web版では「ルームマッチ」タブを操作できないようにし、代わりに従来通り機能する
	# DirectConnectタブを既定にして、空のタブに取り残されないようにする
	if OS.has_feature("web"):
		quick_match_btn.disabled = true
		refresh_btn.disabled = true
		create_open_btn.disabled = true
		status_label.text = "Web版では Steam マッチメイキングは利用できません。「DirectConnect」タブをご利用ください。"
		tabs.current_tab = 2


func open() -> void:
	show()
	room_name_edit.text = "%sの部屋" % ProfileManager.player_name
	my_tier_label.text = "あなたのレート帯: %s" % RankingManager.tier_name(ProfileManager.rating)
	tier_lock_check.button_pressed = false
	if not OS.has_feature("web"):
		_on_refresh_pressed()


func _on_refresh_pressed() -> void:
	status_label.text = "ロビーを検索中..."
	SteamManager.request_lobby_list()


func _on_lobbies_received(lobbies: Array) -> void:
	status_label.text = "ロビー一覧を更新しました (%d件)" % lobbies.size()
	_all_lobbies = lobbies
	_render_lobbies()


## ②選択中のフィルタとレート差で絞り込み・並べ替えて描画する
func _render_lobbies() -> void:
	for child in room_list_container.get_children():
		child.queue_free()

	var my_rating := ProfileManager.rating
	var tolerance := tier_filter.selected  # 0=自分の帯のみ, 1=±1帯, 2=すべて(実質無制限)

	var visible_lobbies: Array = []
	for lobby in _all_lobbies:
		var host_rating := int(lobby.get("host_rating", 1500))
		if tolerance < 2 and not RankingManager.is_rating_compatible(host_rating, my_rating, tolerance):
			continue
		visible_lobbies.append(lobby)
	visible_lobbies.sort_custom(func(a, b):
		return absi(int(a.get("host_rating", 1500)) - my_rating) < absi(int(b.get("host_rating", 1500)) - my_rating)
	)

	if visible_lobbies.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "条件に合うロビーがありません。フィルタを緩めるか「部屋を作成」してください。"
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		room_list_container.add_child(empty_lbl)
		return

	for lobby in visible_lobbies:
		room_list_container.add_child(_build_lobby_row(lobby, my_rating))


func _build_lobby_row(lobby: Dictionary, my_rating: int) -> Control:
	var host_rating := int(lobby.get("host_rating", 1500))
	var tier_name := RankingManager.tier_name(host_rating)
	var tier_color := RankingManager.tier_color(host_rating)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var tier_lbl := Label.new()
	tier_lbl.text = "[%s]" % tier_name
	tier_lbl.custom_minimum_size = Vector2(72, 0)
	tier_lbl.add_theme_color_override("font_color", tier_color)

	var name_lbl := Label.new()
	name_lbl.text = str(lobby.get("name", "Room"))
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var count_lbl := Label.new()
	count_lbl.text = "%d / %d人" % [lobby.get("members", 1), lobby.get("max_members", 8)]

	var gap_lbl := Label.new()
	var gap := host_rating - my_rating
	if absi(gap) >= 50:
		gap_lbl.text = "レート差 %+d" % gap
		gap_lbl.add_theme_color_override("font_color", Color(1.0, 0.75, 0.4))
	if lobby.get("tier_lock", false):
		gap_lbl.text += " 🔒同帯限定" if not gap_lbl.text.is_empty() else "🔒同帯限定"

	var join_btn := Button.new()
	join_btn.text = "参加"
	var lobby_id := int(lobby.get("id", 0))
	join_btn.pressed.connect(func():
		status_label.text = "ロビーに参加中..."
		SteamManager.join_lobby(lobby_id)
	)

	row.add_child(tier_lbl)
	row.add_child(name_lbl)
	row.add_child(count_lbl)
	row.add_child(gap_lbl)
	row.add_child(join_btn)
	return row


## ②近いレート帯・空きのある部屋へ自動参加する。無ければ自分の帯で新規作成する
func _on_quick_match_pressed() -> void:
	var my_rating := ProfileManager.rating
	var best = null
	var best_gap := 999999
	for lobby in _all_lobbies:
		if int(lobby.get("members", 1)) >= int(lobby.get("max_members", 8)):
			continue
		var host_rating := int(lobby.get("host_rating", 1500))
		if not RankingManager.is_rating_compatible(host_rating, my_rating, 0):
			continue
		var gap := absi(host_rating - my_rating)
		if gap < best_gap:
			best_gap = gap
			best = lobby
	if best != null:
		status_label.text = "近いレート帯の部屋に参加中..."
		SteamManager.join_lobby(int(best.get("id", 0)))
	else:
		status_label.text = "空いている部屋が無いので新規作成します..."
		GameManager.tier_lock_enabled = false
		SteamManager.create_lobby(2, 8, "%sの部屋(%s)" % [ProfileManager.player_name, RankingManager.tier_name(my_rating)])


func _on_do_create_pressed() -> void:
	var r_name := room_name_edit.text.strip_edges()
	var max_m := int(max_members_spin.value)
	status_label.text = "ロビーを作成中..."
	GameManager.tier_lock_enabled = tier_lock_check.button_pressed
	SteamManager.create_lobby(2, max_m, r_name) # 2 = Public


func _on_lobby_created(connect_status: int, _lobby_id: int) -> void:
	if connect_status == 1:
		status_label.text = "ロビーを作成しました！ゲームを開始します。"
		NetworkManager.start_host(true)
	else:
		status_label.text = "ロビーの作成に失敗しました。"


func _on_lobby_joined(lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	# ホストがロビーを作成した際にも Steam から lobby_joined が発火するため、ホストは無視する
	if SteamManager.is_host:
		return
	if response != 1:
		status_label.text = "ロビーへの参加に失敗しました。"
		return
	status_label.text = "ロビーに参加しました！ゲームへ接続中..."
	if SteamManager.is_steam_available:
		var addr := await SteamManager.await_host_addr(lobby_id)
		if addr.is_empty():
			status_label.text = "ホストの準備が完了していません。少し待ってから再度お試しください。"
			return
		NetworkManager.start_client(addr)
	else:
		# オフラインモック（Steam無効時）。同一マシンでのUI動作確認用に127.0.0.1へ接続する
		var addr := SteamManager.get_lobby_data(lobby_id, "host_addr")
		NetworkManager.start_client(addr if not addr.is_empty() else "127.0.0.1")


func _on_direct_join_pressed() -> void:
	var addr = direct_addr_edit.text.strip_edges()
	if addr.is_empty():
		status_label.text = "アドレスを入力してください"
		return
	NetworkManager.start_client(addr)


func _on_direct_host_pressed() -> void:
	GameManager.tier_lock_enabled = false
	if NetworkManager.start_host(true):
		hide()
	else:
		status_label.text = NetworkManager.last_error


func _on_close_pressed() -> void:
	closed.emit()
	hide()
