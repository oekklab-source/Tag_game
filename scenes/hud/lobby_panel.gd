extends CenterContainer

## HUD の子（$Lobby）にアタッチ。待機中のロビー一覧・定員変更・役割ボタン等を持つ。
## HUD で唯一クリックできる UI（hud.gd._ignore_mouse() がこのノード以下を対象外にしている）。
##
## 着せ替え/ショップ/フレンドのオーバーレイの開閉自体は scenes/hud.gd(ルート)側に残す
## (フルスクリーン表示のため HUD の CanvasLayer 直下に追加する必要があり、
## このノードは CenterContainer なので直接の子にすると中央寄せで縮められてしまう)。
## ボタンが押されたことだけ signal で root に伝える

signal open_overlay_requested(key: String)
## M-09: 定員変更などの結果をトーストで知らせたいときに使う(hud.gdの_toastへそのまま繋ぐ)
signal toast_requested(text: String, color: Color)

## scenes/hud.gd(ルート)の同名定数と値を揃えておくこと(役割バッジの色と一致させる)
const COLOR_RUNNER := Color(0.35, 1.0, 0.55)
const COLOR_HUNTER := Color(1.0, 0.45, 0.4)

## ⑥参加者一覧の見た目プレビュー。着せ替え/ショップ画面と同じ3Dプレビュー部品を再利用する。
## SubViewportContainer.stretch(costume_preview.tscn側で有効)により、内部の描画解像度も
## このコンテナの実サイズへ自動追従するので、別途レンダリング解像度を落とす必要はない
const COSTUME_PREVIEW_SCENE := preload("res://scenes/costume_preview.tscn")
const PREVIEW_SIZE := 96
## L-10: _fit_to_screen() で画面の上下左右に残す余白
const FIT_MARGIN := 16.0

@onready var box: PanelContainer = $Box
@onready var status: Label = $Box/Col/Status
@onready var status_sub: Label = $Box/Col/StatusSub
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
@onready var invite_row: HBoxContainer = $Box/Col/InviteRow
@onready var invite_label: Label = $Box/Col/InviteRow/InviteLabel
@onready var copy_link_button: Button = $Box/Col/InviteRow/CopyLinkButton
@onready var version_label: Label = $Box/Col/ControlsHelpRow/VersionLabel

var _roster_key := ""
var _max_members_row_was_visible := false
var _sb_row: StyleBoxFlat
var _sb_row_hover: StyleBoxFlat
var _public_address_confirmed := false
## H-04: キック確認ダイアログは1つ使い回し、対象idだけ差し替える
## (friend_screen.gdの_remove_confirm_dialogと同じパターン)
var _pending_kick_id := -1
var _kick_confirm_dialog: ConfirmationDialog


func _ready() -> void:
	_sb_row = _row_style()
	_sb_row_hover = _row_style_hover()
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
	copy_link_button.pressed.connect(_on_copy_link_pressed)
	# ホストマイグレーション後の再emit(_promote_self_to_host())も含めて拾う。
	# 既にpublic_addressが確定した後にこのパネルが読み込まれるケースは
	# シグナルを取りこぼすため、下の即時チェックで補う
	NetworkManager.public_address_ready.connect(_on_public_address_ready)
	# この"v"は通信プロトコル版数(PROTOCOL_VERSION)。ストア版数(application/config/version)ではない
	version_label.text = "v%d" % GameManager.PROTOCOL_VERSION
	if not NetworkManager.public_address.is_empty():
		_on_public_address_ready(NetworkManager.public_address)
	_build_kick_confirm_dialog()


## H-04: キック確認ダイアログ(OK/キャンセルを1つ使い回し、対象は_pending_kick_idに保持する)
func _build_kick_confirm_dialog() -> void:
	_kick_confirm_dialog = ConfirmationDialog.new()
	_kick_confirm_dialog.title = tr("参加者を退出させる")
	_kick_confirm_dialog.ok_button_text = tr("退出させる")
	_kick_confirm_dialog.cancel_button_text = tr("キャンセル")
	_kick_confirm_dialog.confirmed.connect(_on_kick_confirmed)
	add_child(_kick_confirm_dialog)


func _on_kick_pressed(id: int) -> void:
	_pending_kick_id = id
	_kick_confirm_dialog.dialog_text = tr("%s をロビーから退出させますか？") \
		% _display_name(id, multiplayer.get_unique_id())
	_kick_confirm_dialog.popup_centered()


func _on_kick_confirmed() -> void:
	if _pending_kick_id < 0:
		return
	GameManager.kick_peer(_pending_kick_id)
	_pending_kick_id = -1


## 招待リンクの画面内表示(C-04)。ホスト開始/トンネル確定/ホストマイグレーション後の
## 再確定のいずれでもNetworkManager.public_address_readyから呼ばれる
func _on_public_address_ready(_addr: String) -> void:
	_public_address_confirmed = true
	invite_label.text = tr("招待リンク: %s") % NetworkManager.join_link()


func _on_copy_link_pressed() -> void:
	DisplayServer.clipboard_set(NetworkManager.join_link())
	copy_link_button.text = tr("コピーしました")
	copy_link_button.disabled = true
	await get_tree().create_timer(1.5).timeout
	copy_link_button.text = tr("リンクをコピー")
	copy_link_button.disabled = false


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


## L-02: 役割指名ボタンのホバー時。_row_style()と同じ形でbg_colorだけ明るくする
func _row_style_hover() -> StyleBoxFlat:
	var sb := _row_style()
	sb.bg_color = Color(1, 1, 1, 0.14)
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
	# EOSロビー経由(見知らぬ相手とのレート戦)で招待リンクを見せると、意図的に
	# 特定の相手を招き入れてレートを操作できてしまう。DirectConnect(非レート)でのみ出す
	invite_row.visible = _public_address_confirmed and not is_eos_matched
	_update_max_members_row(is_host)
	# 版数は_ready()でControlsHelpRow/VersionLabelに出す(古いビルドが混ざったときに
	# 見ただけで分かるように)。ここではStatusの毎フレーム更新のみ扱う。
	# 定員は常に4人（逃走者1 + 鬼3）で、足りない鬼は CPU が埋めることも書いておく
	var humans_on_hunt: int = maxi(ids.size() - 1, 0)
	var cpu_fill: int = maxi(GameManager.MAX_HUNTERS - humans_on_hunt, 0)
	if GameManager.debug_cpu_runner:
		cpu_fill = 0  # デバッグ（CPU逃走者）は1対1の検証用で CPU 鬼を足さない
	var fill_text := "" if cpu_fill <= 0 else tr("（うち CPU の鬼 %d人）") % cpu_fill
	status.text = tr("ホスト（あなた）") if is_host else tr("参加中（ホストは別の人）")
	status_sub.text = tr("4人であそぶ: %d人が参加中%s") % [ids.size(), fill_text]

	_rebuild_roster(ids, me, is_host, is_eos_matched)

	var debug_available := OS.is_debug_build() and is_host and ids.size() == 1
	if is_host and GameManager.debug_cpu_runner and not debug_available:
		GameManager.set_debug_cpu_runner(false)
	debug_cpu_runner_button.visible = debug_available
	debug_cpu_runner_button.set_pressed_no_signal(GameManager.debug_cpu_runner)
	debug_cpu_runner_button.text = tr("デバッグ: CPU逃走者 ON") if GameManager.debug_cpu_runner else tr("デバッグ: CPU逃走者 OFF")
	var i_am_runner := GameManager.wanted_runner == me
	role_button.text = tr("デバッグ中: あなたは鬼") if GameManager.debug_cpu_runner else (tr("おにに戻る") if i_am_runner else tr("逃げる役になる"))
	role_button.disabled = GameManager.debug_cpu_runner
	role_button.visible = not is_eos_matched
	start_button.visible = is_host
	start_button.disabled = ids.is_empty()
	if not GameManager.peer_notice.is_empty():
		# ビルドの食い違いなど、放っておくと原因の分からない不具合になるものを出す
		hint.text = GameManager.peer_notice
		hint.modulate = Color(1.0, 0.55, 0.4)
	elif is_eos_matched:
		hint.text = tr("この対戦は鬼がランダムで決まります（立候補不可）%s") \
			% (tr("　Enter キー: 開始") if is_host else tr("　― ホストが始めるのを待っています"))
		hint.modulate = Color.WHITE
	elif is_host and GameManager.debug_cpu_runner:
		hint.text = tr("デバッグ中: あなたが鬼、CPUが逃げる役です。Enter キー: 開始")
		hint.modulate = Color.WHITE
	elif is_host:
		hint.text = ""
	else:
		hint.text = tr("R キー: 役割を切りかえ　― ホストが始めるのを待っています")
		hint.modulate = Color.WHITE
	hint.visible = not hint.text.is_empty()
	_fit_to_screen()


## L-10: 文字サイズ「大/特大」(SettingsManager.TEXT_SIZE_SCALES、ルート Window の
## content_scale_factor)では、使える画面の高さが 1080/1.3≒831 相当まで減る。参加者が並ぶと
## このパネルは標準でも縦 800 前後あるため、そのままでは見出しと操作説明が画面外に切れる
## (実測: 特大で両方とも見えなくなった)。はみ出すときだけパネルごと縮めて収める。
## 縮めるのは Box ではなくこのノード自身: Box は CenterContainer の子なので、並べ直しのたびに
## Container.fit_child_in_rect() が scale を 1 に戻してしまう。このノードの親は CanvasLayer
## (Container ではない)なので scale が保たれ、画面中央を支点に縮めれば中央寄せも崩れない。
## 使える広さは自分の size ではなく get_viewport_rect() で測る: このノードも Container なので、
## Box の最小サイズが画面より大きいと自分の size まで画面の外へ広がってしまう(実測で縮まなかった)
func _fit_to_screen() -> void:
	var need := box.get_combined_minimum_size()
	if need.x <= 0.0 or need.y <= 0.0:
		return
	var avail := get_viewport_rect().size - Vector2(FIT_MARGIN, FIT_MARGIN) * 2.0
	var s := minf(1.0, minf(avail.x / need.x, avail.y / need.y))
	pivot_offset = size / 2.0
	scale = Vector2(s, s)


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
	if ok:
		toast_requested.emit(tr("定員を%d人に変更しました") % new_max, COLOR_RUNNER)
	else:
		max_members_spin.value = EosManager.get_current_lobby_max_members()
		toast_requested.emit(
			tr("定員の変更に失敗しました（現在: %d人）") % int(max_members_spin.value), COLOR_HUNTER)


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
		list.add_child(_roster_note(tr("だれもいません")))
		return
	for id in ids:
		list.add_child(_roster_row(id, me, is_host, is_eos_matched))
	if is_eos_matched:
		list.add_child(_roster_note(tr("鬼は開始時にランダムで決まります（立候補不可）")))
	elif GameManager.wanted_runner < 0:
		list.add_child(_roster_note(tr("逃げる役が未定です（開始時にランダムで決まります）")))


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
	# L-09: プレイヤー名は利用者の入力なので自動翻訳させない(title.gd の profile_badge_name と同じ理由)
	name_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	name_label.text = _display_name(id, me)
	name_label.add_theme_font_size_override("font_size", 19)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# ②相手のレート帯バッジ・生数値（peer_profiles が届くまでは両方とも表示しない）
	var tier_badge := Label.new()
	var rating_label := Label.new()
	if GameManager.peer_profiles.has(id):
		var rating := int(GameManager.peer_profiles[id].get("rating", 1500))
		tier_badge.text = "[%s]" % tr(RankingManager.tier_name(rating))
		tier_badge.modulate = RankingManager.tier_color(rating)
		tier_badge.add_theme_font_size_override("font_size", 15)
		rating_label.text = "%d Pt" % rating
		rating_label.add_theme_font_size_override("font_size", 15)
		rating_label.modulate = Color(1, 1, 1, 0.7)
	var badge := Label.new()
	# H-08: 色分けだけに頼らないよう、役割ごとに異なる漢字1字を記号的に添える(応急処置)。
	# 絵文字は ui/pop_theme.tres の和文フォント(MPLUSRounded1c-Bold.ttf)にフォールバックが
	# 無く文字化け(豆腐化)のリスクがあるため避け、フォントが対応を謳う日本語グリフの
	# 範囲内に収まる漢字にした(tier_badge の "[%s]" と同じ角括弧表記に揃えている)
	badge.text = tr("[走] にげる") if is_runner else tr("[鬼] おに")
	badge.add_theme_font_size_override("font_size", 19)
	badge.modulate = COLOR_RUNNER if is_runner else COLOR_HUNTER
	h.add_child(name_label)
	h.add_child(tier_badge)
	h.add_child(rating_label)
	h.add_child(badge)
	if is_host and not is_eos_matched and id != me:
		# H-04: キックボタン(_kick_slot)の当たり判定と役割バッジが重ならないよう、
		# バッジの後ろに当たり判定と同じ幅の透明スペーサーを確保しておく
		# (_kick_slot が実際に出る条件と完全に一致させる。出ない行にまで空けると
		# 全員の行が右に詰まって見える無駄な余白になる)
		var kick_spacer := Control.new()
		kick_spacer.custom_minimum_size = Vector2(44, 0)
		h.add_child(kick_spacer)
	row.add_child(h)
	if not is_host or is_eos_matched:
		return row
	# ホストだけ、行を押して逃げる役を付け替えられる
	var btn := Button.new()
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.tooltip_text = tr("この人を逃げる役にする")
	btn.pressed.connect(func() -> void: GameManager.set_wanted_runner_to(id))
	btn.mouse_entered.connect(func(): row.add_theme_stylebox_override("panel", _sb_row_hover))
	btn.mouse_exited.connect(func(): row.add_theme_stylebox_override("panel", _sb_row))
	btn.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.add_child(btn)
	# H-04: 自分以外の行にだけキック用の当たり判定を重ねる
	if id != me:
		row.add_child(_kick_slot(id))
	return row


## H-04: rowの右端に小さく重なる「キック」当たり判定。
## row は PanelContainer で直接の子をすべて同じフルレクトへ強制的に引き伸ばすため、
## キックボタンを row へ直接 add すると btn と同じく行全体を覆ってしまう。
## 非Containerのラッパー(このslot自身)でその強制から一度抜け、中だけ普通の
## アンカー計算をさせて小さい当たり判定にする。slot自身は mouse_filter=IGNORE なので、
## kbtn の矩形外のクリックは slot を素通りして btn (前の兄弟)の役割指名にフォールバックする
func _kick_slot(id: int) -> Control:
	var slot := Control.new()
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var kbtn := Button.new()
	kbtn.flat = true
	kbtn.focus_mode = Control.FOCUS_NONE
	kbtn.text = "✕"
	kbtn.tooltip_text = tr("この人をロビーから退出させる")
	kbtn.anchor_left = 1.0
	kbtn.anchor_right = 1.0
	kbtn.anchor_top = 0.5
	kbtn.anchor_bottom = 0.5
	kbtn.offset_left = -40.0
	kbtn.offset_right = 0.0
	kbtn.offset_top = -18.0
	kbtn.offset_bottom = 18.0
	kbtn.pressed.connect(func() -> void: _on_kick_pressed(id))
	kbtn.mouse_entered.connect(func(): kbtn.modulate = Color(1.0, 0.55, 0.5))
	kbtn.mouse_exited.connect(func(): kbtn.modulate = Color.WHITE)
	slot.add_child(kbtn)
	return slot


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
	var skin := 0
	if GameManager.peer_profiles.has(id):
		var info: Dictionary = GameManager.peer_profiles[id]
		costume_id = StringName(info.get("costume", costume_id))
		colors = ProfileManager.colors_from_html(info.get("colors", []))
		hat_id = StringName(info.get("hat", hat_id))
		skin = int(info.get("skin", skin))

	# ②この時点ではまだシーンツリーに未接続(_rebuild_roster側でlist.add_child(row)するまで、
	# rowもhもこのpreviewも宙に浮いた状態)。costume_preview.gdの@onready参照は
	# _ready()(ツリー接続時)で解決されるため、ここで直接呼ぶと_viewport_container/_humanoid
	# がまだnullでクラッシュする。call_deferredで1フレーム遅らせ、接続後に実行させる
	preview.call_deferred("set_interactive", false)
	preview.call_deferred("show_skin", skin)
	preview.call_deferred("show_costume", costume_id, colors)
	preview.call_deferred("show_hat", hat_id)
	# ⑥見た目反映後の1フレームだけ描いて止める(静止画なのに毎フレーム再レンダリングされる
	# render_target_update_mode=3の既定動作を避け、拡大後のGPU負荷を抑える)
	preview.call_deferred("request_static_render")
	return preview


## GameManager.nickname_for(sync_nickname)を優先し、未到着なら
## ②GameManager.peer_profiles の名前、それも無ければ id 表示にする。
## 両者とも出どころは同じ ProfileManager.player_name で、到着経路が違うだけ
## (sync_nickname はスポーン時の同期プロパティ、peer_profiles は report_profile の RPC)。
## 前者が先に届くことが多いため優先し、後者はまだ Player ノードが居ない/未到着の間の
## フォールバックとして残している
func _display_name(id: int, me: int) -> String:
	var nickname := GameManager.nickname_for(id)
	# L-09: 以前は nickname_for() のフォールバック表記と文字列比較していたが、表記を tr() で
	# 訳すようになったので、比較ではなく has_nickname() で判定する
	var has_nickname := GameManager.has_nickname(id)
	if id == me:
		return tr("あなた（%s）") % nickname if has_nickname else tr("あなた")
	if has_nickname:
		return nickname
	if GameManager.peer_profiles.has(id):
		var pname := String(GameManager.peer_profiles[id].get("name", ""))
		if not pname.is_empty():
			return pname
	return tr("プレイヤー %d") % id


func _roster_note(text: String) -> Control:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	l.modulate = Color(1, 1, 1, 0.55)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l
