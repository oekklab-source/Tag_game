extends CenterContainer

## HUD の子（$Lobby）にアタッチ。待機中のロビー一覧・定員変更・役割ボタン等を持つ。
## HUD で唯一クリックできる UI（hud.gd._ignore_mouse() がこのノード以下を対象外にしている）。
##
## 着せ替え/ショップ/フレンドのオーバーレイの開閉自体は scenes/hud.gd(ルート)側に残す
## (フルスクリーン表示のため HUD の CanvasLayer 直下に追加する必要があり、
## このノードは CenterContainer なので直接の子にすると中央寄せで縮められてしまう)。
## ボタンが押されたことだけ signal で root に伝える

signal open_overlay_requested(key: String)

## scenes/hud.gd(ルート)の同名定数と値を揃えておくこと(役割バッジの色と一致させる)
const COLOR_RUNNER := Color(0.35, 1.0, 0.55)
const COLOR_HUNTER := Color(1.0, 0.45, 0.4)

## ⑥参加者一覧の見た目プレビュー。着せ替え/ショップ画面と同じ3Dプレビュー部品を再利用する。
## SubViewportContainer.stretch(costume_preview.tscn側で有効)により、内部の描画解像度も
## このコンテナの実サイズへ自動追従するので、別途レンダリング解像度を落とす必要はない
const COSTUME_PREVIEW_SCENE := preload("res://scenes/costume_preview.tscn")
const PREVIEW_SIZE := 64

@onready var status: Label = $Box/Col/Status
@onready var list: VBoxContainer = $Box/Col/ListBox/List
@onready var role_button: Button = $Box/Col/RoleButton
@onready var open_costume_button: Button = $Box/Col/OverlayButtonsRow/OpenCostumeButton
@onready var open_shop_button: Button = $Box/Col/OverlayButtonsRow/OpenShopButton
@onready var open_friend_button: Button = $Box/Col/OverlayButtonsRow/OpenFriendButton
@onready var debug_cpu_runner_button: CheckButton = $Box/Col/DebugCpuRunnerButton
@onready var start_button: Button = $Box/Col/StartButton
@onready var max_members_row: HBoxContainer = $Box/Col/MaxMembersRow
@onready var max_members_spin: SpinBox = $Box/Col/MaxMembersRow/MaxMembersSpin
@onready var max_members_apply_button: Button = $Box/Col/MaxMembersRow/MaxMembersApplyButton
@onready var leave_button: Button = $Box/Col/LeaveButton
@onready var hint: Label = $Box/Col/Hint

var _roster_key := ""
var _max_members_row_was_visible := false
var _sb_row: StyleBoxFlat


func _ready() -> void:
	_sb_row = _row_style()
	role_button.pressed.connect(GameManager.toggle_my_role)
	open_costume_button.pressed.connect(func(): open_overlay_requested.emit("costume"))
	open_shop_button.pressed.connect(func(): open_overlay_requested.emit("shop"))
	open_friend_button.pressed.connect(func(): open_overlay_requested.emit("friend"))
	debug_cpu_runner_button.toggled.connect(GameManager.set_debug_cpu_runner)
	# Enterキーはworld.gdの独自アクション"start_round"にも直接バインドされている。
	# このボタンがキーボードフォーカスを持ったままだと、Enter一発で
	# 標準ui_accept(ボタン発火)と独自アクション(_unhandled_input)の二重発火になり、
	# request_start_round()が1回の入力で2回走ってCPU鬼が二重湧きする
	start_button.focus_mode = Control.FOCUS_NONE
	start_button.pressed.connect(GameManager.request_start_round)
	max_members_apply_button.pressed.connect(_on_max_members_apply_pressed)
	# なかま待ち中は接続を切ってタイトルへ戻れる唯一の手段。
	# ホストが押すと全員切断されるが、それは server_disconnected 経由で
	# 各参加者が自動的に NetworkManager.leave() されるので既存動作のまま
	leave_button.pressed.connect(NetworkManager.leave)


## ロビーの一覧の行。コードで作る行にも .tscn 側と同じ角丸を効かせる
func _row_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.07)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb


## HUD で唯一クリックできる UI。誰が逃げる役かをひと目で分かるようにして、
## 「開始のしかたが分からない」を無くすのがここの役目。キー操作（R / Enter）も同じことができる。
## overlay_open は root(hud.gd)が管理するオーバーレイ表示中かどうか
## (表示中はロビーパネル自体を隠す。接続・GameManagerの状態には一切触れないので、部屋は裏で生きたまま)
func update_lobby(overlay_open: bool) -> void:
	var waiting := GameManager.state == GameManager.State.WAITING
	visible = waiting and not overlay_open
	if not waiting:
		return

	var me := multiplayer.get_unique_id()
	var ids := GameManager.player_ids()
	var is_host := multiplayer.is_server()
	# ②EOSロビー経由(見知らぬ相手とのレーティング戦)は鬼を必ずランダムに決めるため、
	# 立候補UI(役割ボタン・ホストの指名クリック)自体を出さない。DirectConnect
	# (フレンドのみのプライベート対戦)は従来通り立候補制のまま
	var is_eos_matched := NetworkManager.matched_via_eos_lobby
	_update_max_members_row(is_host)
	# 版数を出しておくと、古いビルドが混ざったときに見ただけで分かる。
	# 定員は常に4人（逃走者1 + 鬼3）で、足りない鬼は CPU が埋めることも書いておく
	var humans_on_hunt: int = maxi(ids.size() - 1, 0)
	var cpu_fill: int = maxi(GameManager.MAX_HUNTERS - humans_on_hunt, 0)
	if GameManager.debug_cpu_runner:
		cpu_fill = 0  # デバッグ（CPU逃走者）は1対1の検証用で CPU 鬼を足さない
	var fill_text := "" if cpu_fill <= 0 else "（うち CPU の鬼 %d人）" % cpu_fill
	status.text = "%s ／ 4人であそぶ: %d人が参加中%s ／ v%d" % ["ホスト（あなた）" if is_host
		else "参加中（ホストは別の人）", ids.size(), fill_text, GameManager.PROTOCOL_VERSION]

	_rebuild_roster(ids, me, is_host, is_eos_matched)

	var debug_available := is_host and ids.size() == 1
	if is_host and GameManager.debug_cpu_runner and not debug_available:
		GameManager.set_debug_cpu_runner(false)
	debug_cpu_runner_button.visible = debug_available
	debug_cpu_runner_button.set_pressed_no_signal(GameManager.debug_cpu_runner)
	debug_cpu_runner_button.text = "デバッグ: CPU逃走者 ON" if GameManager.debug_cpu_runner else "デバッグ: CPU逃走者 OFF"
	var i_am_runner := GameManager.wanted_runner == me
	role_button.text = "デバッグ中: あなたは鬼" if GameManager.debug_cpu_runner else ("おにに戻る" if i_am_runner else "逃げる役になる")
	role_button.disabled = GameManager.debug_cpu_runner
	role_button.visible = not is_eos_matched
	start_button.visible = is_host
	start_button.disabled = ids.is_empty()
	if not GameManager.peer_notice.is_empty():
		# ビルドの食い違いなど、放っておくと原因の分からない不具合になるものを出す
		hint.text = GameManager.peer_notice
		hint.modulate = Color(1.0, 0.55, 0.4)
	elif is_eos_matched:
		hint.text = "この対戦は鬼がランダムで決まります（立候補不可）%s" \
			% ("　Enter キー: 開始" if is_host else "　― ホストが始めるのを待っています")
		hint.modulate = Color.WHITE
	elif is_host and GameManager.debug_cpu_runner:
		hint.text = "デバッグ中: あなたが鬼、CPUが逃げる役です。Enter キー: 開始"
		hint.modulate = Color.WHITE
	elif is_host:
		hint.text = "R キー: 役割を切りかえ　Tab キー: 逃げる役を指名　Enter キー: 開始"
		hint.modulate = Color.WHITE
	else:
		hint.text = "R キー: 役割を切りかえ　― ホストが始めるのを待っています"
		hint.modulate = Color.WHITE


## 定員変更UIはホストかつEOSロビー経由(公開ロビーを持っている)の時だけ意味を持つ。
## DirectConnectにはEOSロビーという概念自体が無い。
## 毎フレーム値を上書きすると入力中のSpinBoxと喧嘩するので、非表示→表示に
## 変わった瞬間だけ現在値を反映する
func _update_max_members_row(is_host: bool) -> void:
	var show := is_host and not EosManager.current_lobby_id.is_empty()
	if show and not _max_members_row_was_visible:
		max_members_spin.value = EosManager.get_current_lobby_max_members()
	max_members_row.visible = show
	_max_members_row_was_visible = show


## update_lobby()が毎フレームhint.textを上書きするため、ここでの
## メッセージ表示は意味を持たない。失敗時はSpinBoxの表示を実際の値に戻すことで
## 「変更が反映されていないのに反映されたように見える」食い違いだけは防ぐ
func _on_max_members_apply_pressed() -> void:
	var new_max := int(max_members_spin.value)
	var ok: bool = await EosManager.update_max_members(new_max)
	if not ok:
		max_members_spin.value = EosManager.get_current_lobby_max_members()


## 一覧は毎フレーム作り直さず、中身が変わったときだけ組み直す。
## ②⑥GameManager.peer_profiles(レート/コスチューム/帽子)はプロフィール到着とids/名前の
## 変化が同フレームとは限らないため、キーにも含めて到着後の再構築を保証する
## (含めないと profiles_changed を購読していないこの関数は後から届いたプロフィールに
## 気づけず、レートバッジ/見た目プレビューが空のまま固まって見えることがある)
func _rebuild_roster(ids: Array[int], me: int, is_host: bool, is_eos_matched: bool) -> void:
	var names := ids.map(func(id): return _display_name(id, me))
	var profile_stamp := ids.map(func(id): return GameManager.peer_profiles.get(id, {}))
	var key := "%s|%s|%d|%d|%d|%s" % [ids, names, GameManager.wanted_runner, int(is_host),
		int(is_eos_matched), profile_stamp]
	if key == _roster_key:
		return
	_roster_key = key
	for c in list.get_children():
		list.remove_child(c)
		c.queue_free()
	if ids.is_empty():
		list.add_child(_roster_note("だれもいません"))
		return
	for id in ids:
		list.add_child(_roster_row(id, me, is_host, is_eos_matched))
	if is_eos_matched:
		list.add_child(_roster_note("鬼は開始時にランダムで決まります（立候補不可）"))
	elif GameManager.wanted_runner < 0:
		list.add_child(_roster_note("逃げる役が未定です（開始時にランダムで決まります）"))


## 1行 = 名前 + 役割バッジ。ホストなら行ごとクリックして指名できる
## (ただしEOSロビー経由=レーティング戦では鬼をランダム化するため指名UIは出さない)
func _roster_row(id: int, me: int, is_host: bool, is_eos_matched: bool) -> Control:
	var is_runner := id == GameManager.wanted_runner
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", _sb_row)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	h.add_child(_roster_preview(id))
	var name_label := Label.new()
	name_label.text = _display_name(id, me)
	name_label.add_theme_font_size_override("font_size", 19)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# ②相手のレート帯バッジ（peer_profiles が届くまでは表示しない）
	var tier_badge := Label.new()
	if GameManager.peer_profiles.has(id):
		var rating := int(GameManager.peer_profiles[id].get("rating", 1500))
		tier_badge.text = "[%s]" % RankingManager.tier_name(rating)
		tier_badge.modulate = RankingManager.tier_color(rating)
		tier_badge.add_theme_font_size_override("font_size", 15)
	var badge := Label.new()
	badge.text = "にげる" if is_runner else "おに"
	badge.add_theme_font_size_override("font_size", 19)
	badge.modulate = COLOR_RUNNER if is_runner else COLOR_HUNTER
	h.add_child(name_label)
	h.add_child(tier_badge)
	h.add_child(badge)
	row.add_child(h)
	if not is_host or is_eos_matched:
		return row
	# ホストだけ、行を押して逃げる役を付け替えられる
	var btn := Button.new()
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.tooltip_text = "この人を逃げる役にする"
	btn.pressed.connect(func() -> void: GameManager.set_wanted_runner_to(id))
	btn.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.add_child(btn)
	return row


## ⑥見た目プレビュー(costume_preview.tscnの小型埋め込み)。peer_profilesが届くまでは
## きほん姿のまま表示する(player.gd._apply_peer_costume()と同じフォールバック先)。
## ドラッグ回転は行の役割指名クリックと競合するため無効化し、固定アングルで静止させる
func _roster_preview(id: int) -> Control:
	var preview: Control = COSTUME_PREVIEW_SCENE.instantiate()
	preview.custom_minimum_size = Vector2(PREVIEW_SIZE, PREVIEW_SIZE)
	preview.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	preview.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var costume_id := CostumeCatalog.DEFAULT_ID
	var colors := CostumeCatalog.default_colors(costume_id)
	var hat_id := HatCatalog.DEFAULT_ID
	if GameManager.peer_profiles.has(id):
		var info: Dictionary = GameManager.peer_profiles[id]
		costume_id = StringName(info.get("costume", costume_id))
		colors = ProfileManager.colors_from_html(info.get("colors", []))
		hat_id = StringName(info.get("hat", hat_id))

	# ②この時点ではまだシーンツリーに未接続(_rebuild_roster側でlist.add_child(row)するまで、
	# rowもhもこのpreviewも宙に浮いた状態)。costume_preview.gdの@onready参照は
	# _ready()(ツリー接続時)で解決されるため、ここで直接呼ぶと_viewport_container/_humanoid
	# がまだnullでクラッシュする。call_deferredで1フレーム遅らせ、接続後に実行させる
	preview.call_deferred("set_interactive", false)
	preview.call_deferred("show_costume", costume_id, colors)
	preview.call_deferred("show_hat", hat_id)
	return preview


## ローカルニックネーム(GameManager.nickname_for)を優先し、未設定なら
## ②GameManager.peer_profiles のEOSプロフィール名、それも無ければ id 表示にする
func _display_name(id: int, me: int) -> String:
	var nickname := GameManager.nickname_for(id)
	var has_nickname := nickname != "プレイヤー %d" % id
	if id == me:
		return "あなた（%s）" % nickname if has_nickname else "あなた"
	if has_nickname:
		return nickname
	if GameManager.peer_profiles.has(id):
		var pname := String(GameManager.peer_profiles[id].get("name", ""))
		if not pname.is_empty():
			return pname
	return "プレイヤー %d" % id


func _roster_note(text: String) -> Control:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	l.modulate = Color(1, 1, 1, 0.55)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l
