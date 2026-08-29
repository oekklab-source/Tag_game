extends CanvasLayer

## ローカルプレイヤー向け HUD。
##
## 非対称情報の設計はこの実装の核なので、見た目を変えても崩さないこと:
##   Hunter  : 誰かが Runner を「視認」した時だけ、共有された最後の目撃ゾーンの
##             名前と色を受け取る。視認中は SPOTTED、途切れたら残り秒の
##             カウントダウン、さらに10秒の NO INTEL 後は距離だけ受け取る。
##             方向・マーカー・座標は無し。
##   Runner  : 全体の2Dマップ（鬼の位置つき）＋最寄りの鬼への矢印・距離・危険ヴィネット、
##             そして「今 見られている」ことを知らせる SPOTTED バナー。
## Runner 側の情報が多いのは意図的で、非対称性を弱めず強めている。

const ARROW_COLOR := Color(1.0, 0.3, 0.25)
const HUNTER_DOT := Color(1.0, 0.25, 0.2)
const SELF_DOT := Color(0.3, 1.0, 0.5)
const INK := Color(0.05, 0.04, 0.12)
const COLOR_RUNNER := Color(0.35, 1.0, 0.55)
const COLOR_HUNTER := Color(1.0, 0.45, 0.4)
const COLOR_HEAD_START := Color(0.35, 0.85, 1.0)
const COLOR_GOLD := Color(1.0, 0.82, 0.25)

# ゾーン名・色は WorldData に一本化してある（レイアウト変更時の同期漏れを防ぐため）
const WORLD_MIN := -WorldData.WORLD_HALF
const WORLD_SIZE := WorldData.WORLD_HALF * 2.0

const STAMINA_SEGMENTS := 12
const HUNTER_DISTANCE_DELAY := 10.0
const BUFF_BAR_WIDTH := 64.0
const DANGER_FAR := 28.0   # この距離からヴィネットが出はじめる
const DANGER_NEAR := 7.0   # この距離で最大になる

const TOAST_TEXT := {
	Player.Effect.BOOST: "ブースト！",
	Player.Effect.WARP: "ワープ！",
	Player.Effect.STUN: "すべった！",
}
const TOAST_COLOR := {
	Player.Effect.BOOST: Color(0.4, 1.0, 1.0),
	Player.Effect.WARP: Color(0.6, 1.0, 0.5),
	Player.Effect.STUN: Color(1.0, 0.85, 0.25),
}
## 持ち物の表示名と色（Player.Item と対応）
const ITEM_INFO := {
	Player.Item.NONE: ["- - -", Color(1, 1, 1, 0.35)],
	Player.Item.ROCKET: ["ロケット", Color(1.0, 0.55, 0.3)],
	Player.Item.BANANA: ["バナナ", Color(1.0, 0.86, 0.2)],
	Player.Item.BLOCK: ["ブロック", Color(0.45, 0.85, 1.0)],
}
## 取得直後に回すルーレットの出目の並びと、切り替え間隔（速い→遅い）
const ROULETTE_ORDER := [Player.Item.ROCKET, Player.Item.BANANA, Player.Item.BLOCK]
const ROULETTE_FAST := 0.05
const ROULETTE_SLOW := 0.22
## バフの表示名と、残量ゲージの基準になる持続時間
const BUFF_INFO := {
	&"speed": ["スピード", 6.0, Color(1.0, 0.85, 0.25)],
	&"jump": ["ジャンプ", 8.0, Color(0.55, 0.8, 1.0)],
}

var _local_player: Player
var _buff_keys: Array = []
var _spotted_tween: Tween
var _banner_hiding := false
var _hunter_distance_delay_left := HUNTER_DISTANCE_DELAY
var _sb_full: StyleBoxFlat
var _sb_low: StyleBoxFlat
var _sb_empty: StyleBoxFlat
var _sb_row: StyleBoxFlat
var _spinning := false
var _spin_index := 0
var _spin_next := 0.0
var _roster_key := ""

@onready var vignette: TextureRect = $Vignette
@onready var role_badge: PanelContainer = $RoleBadge
@onready var role_label: Label = $RoleBadge/RoleLabel
@onready var timer_ring: Control = $TimerRing
@onready var timer_label: Label = $TimerRing/TimerLabel
@onready var zone_chip: PanelContainer = $ZoneChip
@onready var zone_swatch: ColorRect = $ZoneChip/Row/Swatch
@onready var zone_label: Label = $ZoneChip/Row/ZoneLabel
@onready var map_panel: Control = $MapPanel
@onready var compass: Control = $Compass
@onready var distance_chip: PanelContainer = $DistanceChip
@onready var distance_label: Label = $DistanceChip/DistanceLabel
@onready var spotted_banner: Label = $SpottedBanner
@onready var item_slot: PanelContainer = $ItemSlot
@onready var item_label: Label = $ItemSlot/ItemLabel
@onready var buff_tray: HBoxContainer = $BuffTray
@onready var stamina_label: Label = $StaminaLabel
@onready var stamina_bar: Control = $StaminaBar
@onready var toast_tray: VBoxContainer = $ToastTray
@onready var lobby: CenterContainer = $Lobby
@onready var lobby_status: Label = $Lobby/Box/Col/Status
@onready var lobby_list: VBoxContainer = $Lobby/Box/Col/ListBox/List
@onready var lobby_role_button: Button = $Lobby/Box/Col/RoleButton
@onready var lobby_debug_cpu_runner_button: CheckButton = $Lobby/Box/Col/DebugCpuRunnerButton
@onready var lobby_start_button: Button = $Lobby/Box/Col/StartButton
@onready var lobby_hint: Label = $Lobby/Box/Col/Hint
@onready var info_label: Label = $InfoLabel
@onready var result_panel: CenterContainer = $ResultPanel
@onready var result_title: Label = $ResultPanel/Box/Col/ResultTitle
@onready var result_sub: Label = $ResultPanel/Box/Col/ResultSub
@onready var result_next: Label = $ResultPanel/Box/Col/ResultNext


func _ready() -> void:
	_ignore_mouse(self)
	timer_ring.draw.connect(_on_timer_draw)
	compass.draw.connect(_on_compass_draw)
	map_panel.draw.connect(_on_map_draw)
	stamina_bar.draw.connect(_on_stamina_draw)
	GameManager.state_changed.connect(_on_state_changed)
	GameManager.spotted_changed.connect(_on_spotted_changed)
	_sb_full = _bar_style(Color(0.3, 0.95, 0.55))
	_sb_low = _bar_style(Color(1.0, 0.35, 0.35))
	_sb_empty = _bar_style(Color(1, 1, 1, 0.13))
	_sb_row = _row_style()
	vignette.texture = _radial_texture()
	vignette.modulate = Color(1.0, 0.12, 0.12, 0.0)
	lobby_role_button.pressed.connect(GameManager.toggle_my_role)
	lobby_debug_cpu_runner_button.toggled.connect(GameManager.set_debug_cpu_runner)
	lobby_start_button.pressed.connect(GameManager.request_start_round)


## HUD には操作可能なウィジェットが一つも無いので、全 Control をマウス無視にする。
##
## これが無いと、マウスキャプチャ中のカーソル位置（GUI空間の画面中央 640,360）に
## 重なった Control が InputEventMouseMotion を食い潰し、
## player.gd の _unhandled_input が呼ばれず**振り向けなくなる**。
## Godot の入力順は _input -> GUI -> _unhandled_input なので、
## Control が STOP のままだと必ずこうなる。
## 個別ノードに書くのではなく再帰で潰すのは、UI を足した時に再発させないため。
func _ignore_mouse(node: Node) -> void:
	# ロビーだけは唯一の操作できる UI なので触らない。
	# 待機中しか visible にならないので、ラウンド中に視点操作を奪うことはない
	if node == lobby:
		return
	if node is Control:
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in node.get_children():
		_ignore_mouse(c)


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


func _bar_style(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(6)
	return sb


## 危険表示用の放射グラデーション。アセットを持たずコードで作る
func _radial_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0))
	g.set_color(1, Color(1, 1, 1, 1))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 256
	t.height = 256
	return t


func _process(delta: float) -> void:
	var player := _get_local_player()
	_update_hunter_distance_delay(delta, player)
	_update_labels()
	_update_stamina(player)
	_update_item(player, delta)
	_update_buffs(player)
	_update_tracking(player)
	timer_ring.queue_redraw()
	stamina_bar.queue_redraw()


## --- 状態表示 ----------------------------------------------------------

func _update_labels() -> void:
	var my_id := multiplayer.get_unique_id()
	var is_runner := my_id == GameManager.runner_id
	match GameManager.state:
		GameManager.State.WAITING:
			# 待機中の情報はロビーに集約する。ここにも出すと二重になって散らかる
			role_badge.visible = false
			timer_label.text = ""
			zone_chip.visible = false
			result_panel.visible = false
		GameManager.State.PLAYING, GameManager.State.RESULT:
			role_badge.visible = true
			if is_runner:
				role_label.text = "にげろ！"
				role_label.modulate = COLOR_RUNNER
			else:
				role_label.text = "おに ― にげる人をつかまえろ！"
				role_label.modulate = COLOR_HUNTER
			if GameManager.head_start_left > 0.0:
				timer_label.text = "%d" % ceili(GameManager.head_start_left)
			else:
				var t := maxi(ceili(GameManager.time_left), 0)
				timer_label.text = "%d:%02d" % [t / 60, t % 60]
			_update_zone_chip(is_runner)
			_update_result(is_runner)
	# バナーは逃走者専用。表示はシグナルのエッジで駆動しているので、
	# 役割が変わる経路を取りこぼさないようここでも不変条件を担保する
	if spotted_banner.visible and (not is_runner or not GameManager.spotted):
		_hide_spotted_banner()

	_update_lobby()

	var lines := PackedStringArray()
	if GameManager.state == GameManager.State.WAITING:
		lines.append("Esc: マウスを離してロビーを操作")
	else:
		lines.append("クリック: 視点を操作 / Esc: マウスを離す")
		if GameManager.head_start_left > 0.0:
			lines.append("にげる時間！ 今のうちに走れ" if is_runner
				else "にげる時間 ― おには動けない")
	info_label.text = "
".join(lines)


## --- 待機中のロビー -----------------------------------------------------
## HUD で唯一クリックできる UI。誰が逃げる役かをひと目で分かるようにして、
## 「開始のしかたが分からない」を無くすのがここの役目。
## キー操作（R / Enter）も同じことができる
func _update_lobby() -> void:
	var waiting := GameManager.state == GameManager.State.WAITING
	lobby.visible = waiting
	if not waiting:
		return

	var me := multiplayer.get_unique_id()
	var ids := GameManager.player_ids()
	var is_host := multiplayer.is_server()
	# 版数を出しておくと、古いビルドが混ざったときに見ただけで分かる
	lobby_status.text = "%s ／ %d人が参加中 ／ v%d" % ["ホスト（あなた）" if is_host
		else "参加中（ホストは別の人）", ids.size(), GameManager.PROTOCOL_VERSION]

	_rebuild_roster(ids, me, is_host)

	var debug_available := is_host and ids.size() == 1
	if is_host and GameManager.debug_cpu_runner and not debug_available:
		GameManager.set_debug_cpu_runner(false)
	lobby_debug_cpu_runner_button.visible = debug_available
	lobby_debug_cpu_runner_button.set_pressed_no_signal(GameManager.debug_cpu_runner)
	lobby_debug_cpu_runner_button.text = "デバッグ: CPU逃走者 ON" if GameManager.debug_cpu_runner else "デバッグ: CPU逃走者 OFF"
	var i_am_runner := GameManager.wanted_runner == me
	lobby_role_button.text = "デバッグ中: あなたは鬼" if GameManager.debug_cpu_runner else ("おにに戻る" if i_am_runner else "逃げる役になる")
	lobby_role_button.disabled = GameManager.debug_cpu_runner
	lobby_start_button.visible = is_host
	lobby_start_button.disabled = ids.is_empty()
	if not GameManager.peer_notice.is_empty():
		# ビルドの食い違いなど、放っておくと原因の分からない不具合になるものを出す
		lobby_hint.text = GameManager.peer_notice
		lobby_hint.modulate = Color(1.0, 0.55, 0.4)
	elif is_host and GameManager.debug_cpu_runner:
		lobby_hint.text = "デバッグ中: あなたが鬼、CPUが逃げる役です。Enter キー: 開始"
		lobby_hint.modulate = Color.WHITE
	elif is_host:
		lobby_hint.text = "R キー: 役割を切りかえ　Tab キー: 逃げる役を指名　Enter キー: 開始"
		lobby_hint.modulate = Color.WHITE
	else:
		lobby_hint.text = "R キー: 役割を切りかえ　― ホストが始めるのを待っています"
		lobby_hint.modulate = Color.WHITE


## 一覧は毎フレーム作り直さず、中身が変わったときだけ組み直す
func _rebuild_roster(ids: Array[int], me: int, is_host: bool) -> void:
	var names := ids.map(func(id): return GameManager.nickname_for(id))
	var key := "%s|%s|%d|%d" % [ids, names, GameManager.wanted_runner, int(is_host)]
	if key == _roster_key:
		return
	_roster_key = key
	for c in lobby_list.get_children():
		lobby_list.remove_child(c)
		c.queue_free()
	if ids.is_empty():
		lobby_list.add_child(_roster_note("だれもいません"))
		return
	for id in ids:
		lobby_list.add_child(_roster_row(id, me, is_host))
	if GameManager.wanted_runner < 0:
		lobby_list.add_child(_roster_note("逃げる役が未定です（開始時にランダムで決まります）"))


## 1行 = 名前 + 役割バッジ。ホストなら行ごとクリックして指名できる
func _roster_row(id: int, me: int, is_host: bool) -> Control:
	var is_runner := id == GameManager.wanted_runner
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", _sb_row)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	var name_label := Label.new()
	var nickname := GameManager.nickname_for(id)
	name_label.text = "あなた（%s）" % nickname if id == me else nickname
	name_label.add_theme_font_size_override("font_size", 19)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var badge := Label.new()
	badge.text = "にげる" if is_runner else "おに"
	badge.add_theme_font_size_override("font_size", 19)
	badge.modulate = COLOR_RUNNER if is_runner else COLOR_HUNTER
	h.add_child(name_label)
	h.add_child(badge)
	row.add_child(h)
	if not is_host:
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


func _roster_note(text: String) -> Control:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	l.modulate = Color(1, 1, 1, 0.55)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


## 鬼にだけ、共有された目撃情報を見せる。
## 距離は情報が切れてから10秒後に限り読める。方向・マーカー・座標は出さない。
## 3状態とも表示したままにしてレイアウトが跳ねないようにする
func _update_zone_chip(is_runner: bool) -> void:
	if is_runner or GameManager.state != GameManager.State.PLAYING:
		zone_chip.visible = false
		return
	zone_chip.visible = true
	var zone: int = GameManager.spotted_zone
	if zone < 0:
		var distance := _runner_distance(_get_local_player())
		if _hunter_distance_delay_left <= 0.0 and distance >= 0.0:
			zone_label.text = "逃走者との距離　%d m" % roundi(distance)
			zone_swatch.color = COLOR_RUNNER.darkened(0.2)
		else:
			zone_label.text = "手がかりなし"
			zone_swatch.color = Color(0.32, 0.32, 0.38)
		zone_chip.modulate.a = 1.0
	elif GameManager.spotted:
		zone_label.text = "発見！　%s" % WorldData.zone_name(zone)
		zone_swatch.color = WorldData.zone_color(zone)
		zone_chip.modulate.a = 0.75 + 0.25 * sin(Time.get_ticks_msec() * 0.012)
	else:
		zone_label.text = "さっき目撃　%s　あと%d秒" % [
			WorldData.zone_name(zone), maxi(ceili(GameManager.intel_left), 0)]
		zone_swatch.color = WorldData.zone_color(zone).darkened(0.35)
		zone_chip.modulate.a = 1.0


func _update_hunter_distance_delay(delta: float, player: Player) -> void:
	var is_hunter := (
		GameManager.state == GameManager.State.PLAYING
		and player != null
		and multiplayer.get_unique_id() != GameManager.runner_id
	)
	var has_zone_intel := GameManager.spotted or GameManager.spotted_zone >= 0
	if not is_hunter or has_zone_intel:
		_hunter_distance_delay_left = HUNTER_DISTANCE_DELAY
		return
	_hunter_distance_delay_left = maxf(_hunter_distance_delay_left - delta, 0.0)


func _runner_distance(player: Node3D) -> float:
	var runner := GameManager.get_runner() as Node3D
	if player == null or runner == null:
		return -1.0
	return player.global_position.distance_to(runner.global_position)


func _update_result(is_runner: bool) -> void:
	result_panel.visible = GameManager.state == GameManager.State.RESULT
	if not result_panel.visible:
		return
	var won: bool = GameManager.result_runner_won
	if GameManager.result_reason == GameManager.EndReason.RUNNER_LEFT:
		result_title.text = "ちゅうだん"
		result_title.modulate = COLOR_GOLD
		result_sub.text = "逃げる人が抜けました"
	else:
		result_title.text = "にげきった！" if won else "つかまえた！"
		result_title.modulate = COLOR_RUNNER if won else COLOR_HUNTER
		if won:
			result_sub.text = "最後まで逃げきった" if is_runner else "逃げる人に逃げきられた"
		else:
			result_sub.text = "つかまってしまった" if is_runner else "逃げる人をつかまえた"
	result_next.text = "%d秒後になかま待ちにもどります" % maxi(ceili(GameManager.result_left), 0)
	result_next.modulate = COLOR_GOLD


## --- 円形タイマー ------------------------------------------------------

func _on_timer_draw() -> void:
	if GameManager.state == GameManager.State.WAITING:
		return
	var c := timer_ring.size * 0.5
	timer_ring.draw_arc(c, 54.0, 0.0, TAU, 64, Color(0, 0, 0, 0.45), 14.0, true)
	var frac := 0.0
	var col := COLOR_RUNNER
	if GameManager.head_start_left > 0.0:
		frac = GameManager.head_start_left / GameManager.HEAD_START
		col = COLOR_HEAD_START
	else:
		frac = clampf(GameManager.time_left / GameManager.ROUND_TIME, 0.0, 1.0)
		if frac < 0.34:
			col = Color(1.0, 0.72, 0.2)
		if frac < 0.15:
			col = Color(1.0, 0.3, 0.3)
	timer_ring.draw_arc(c, 54.0, -PI * 0.5, -PI * 0.5 + TAU * frac, 64, col, 12.0, true)


## --- スタミナ（分割ゲージ） ---------------------------------------------

func _update_stamina(player: Player) -> void:
	var show := player != null and GameManager.state != GameManager.State.WAITING
	stamina_bar.visible = show
	stamina_label.visible = show


func _on_stamina_draw() -> void:
	var player := _get_local_player()
	if player == null:
		return
	var gap := 4.0
	var w := (stamina_bar.size.x - (STAMINA_SEGMENTS - 1) * gap) / STAMINA_SEGMENTS
	var filled := int(player.stamina / player.stamina_max() * STAMINA_SEGMENTS)
	for i in STAMINA_SEGMENTS:
		var sb := _sb_empty
		if i < filled:
			sb = _sb_low if player.exhausted else _sb_full
		stamina_bar.draw_style_box(sb, Rect2(i * (w + gap), 0.0, w, stamina_bar.size.y))


## --- 持ち物スロット（1個持ち） -------------------------------------------

func _update_item(player: Player, delta: float) -> void:
	item_slot.visible = player != null and GameManager.state == GameManager.State.PLAYING
	if not item_slot.visible:
		_spinning = false
		return
	# 取得直後（Player.item_lock 中）は中身を伏せ、出目を切り替え続ける。
	# 使用可否と足並みを揃えるため、回している判断は HUD 側では持たない
	if player.item != Player.Item.NONE and player.item_lock > 0.0:
		_spin_item(player, delta)
		return
	if _spinning:
		_spinning = false
		_confirm_item(player.item)
	var info: Array = ITEM_INFO.get(player.item, ITEM_INFO[Player.Item.NONE])
	item_label.text = info[0]
	item_label.modulate = info[1]


## 残りロック時間が減るほど切り替え間隔を広げ、止まりかけているように見せる
func _spin_item(player: Player, delta: float) -> void:
	if not _spinning:
		_spinning = true
		_spin_next = 0.0
		_spin_index = randi() % ROULETTE_ORDER.size()
	_spin_next -= delta
	if _spin_next <= 0.0:
		_spin_index = (_spin_index + 1) % ROULETTE_ORDER.size()
		var t := 1.0 - clampf(player.item_lock / Player.ITEM_ROULETTE, 0.0, 1.0)
		_spin_next = lerpf(ROULETTE_FAST, ROULETTE_SLOW, t * t)
	var info: Array = ITEM_INFO[ROULETTE_ORDER[_spin_index]]
	var color: Color = info[1]
	item_label.text = info[0]
	item_label.modulate = Color(color, 0.7)  # 確定前は薄く出す


## ルーレットが止まった瞬間。ここで初めて中身を名乗る
func _confirm_item(held: int) -> void:
	if held == Player.Item.NONE:
		return  # ラウンド開始などで持ち物ごと消えた場合
	var info: Array = ITEM_INFO.get(held, ITEM_INFO[Player.Item.NONE])
	_toast("%s を手に入れた（E キー）" % info[0], info[1])
	item_slot.pivot_offset = item_slot.size * 0.5
	var tw := create_tween()
	var tween := tw.tween_property(item_slot, "scale", Vector2.ONE, 0.4)
	tween.from(Vector2(1.4, 1.4))
	tween.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


## トーストは確定時（_confirm_item）に出すので、ここでは回転の後始末だけ行う
func _on_item_changed(held: int) -> void:
	if held == Player.Item.NONE:
		_spinning = false


## --- バフ表示（ローカルプレイヤーのバフを直接読む） ------------------------

func _update_buffs(player: Player) -> void:
	var active: Array = player.buffs.keys() if player else []
	# 表示中のチップと実際のバフが食い違ったときだけ作り直す。
	# 個数ではなく中身で比べないと、入れ替わり（speed 終了 + jump 取得）を取りこぼす
	if _buff_keys != active:
		_buff_keys = active.duplicate()
		for c in buff_tray.get_children():
			# queue_free だけでは同フレーム中に子として残るため、先に外す
			buff_tray.remove_child(c)
			c.queue_free()
		for key in active:
			buff_tray.add_child(_make_buff_chip(key))
	var i := 0
	for key in active:
		if i >= buff_tray.get_child_count():
			break
		var info: Array = BUFF_INFO.get(key, ["BUFF", 6.0, Color.WHITE])
		var fill: ColorRect = buff_tray.get_child(i).get_node("Col/Fill")
		var frac := clampf(player.buffs.time_left(key) / info[1], 0.0, 1.0)
		fill.custom_minimum_size.x = BUFF_BAR_WIDTH * frac
		i += 1


func _make_buff_chip(key: StringName) -> Control:
	var info: Array = BUFF_INFO.get(key, ["BUFF", 6.0, Color.WHITE])
	var panel := PanelContainer.new()
	var col := VBoxContainer.new()
	col.name = "Col"
	col.add_theme_constant_override("separation", 4)
	var label := Label.new()
	label.text = info[0]
	label.add_theme_font_size_override("font_size", 16)
	label.modulate = info[2]
	var fill := ColorRect.new()
	fill.name = "Fill"
	fill.color = info[2]
	fill.custom_minimum_size = Vector2(BUFF_BAR_WIDTH, 4)
	fill.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	col.add_child(label)
	col.add_child(fill)
	panel.add_child(col)
	return panel


## --- Runner 専用: ミニマップ・方位・距離・危険表示 --------------------------

func _update_tracking(player: Player) -> void:
	var is_runner := (
		GameManager.state == GameManager.State.PLAYING
		and player != null
		and multiplayer.get_unique_id() == GameManager.runner_id
	)
	map_panel.visible = is_runner
	if is_runner:
		map_panel.queue_redraw()

	var target: Node3D = _nearest_hunter(player) if is_runner else null
	compass.visible = target != null
	distance_chip.visible = target != null
	if target == null:
		vignette.modulate.a = 0.0
		return

	var forward: Vector3 = -player.camera.global_transform.basis.z
	var to_target: Vector3 = target.global_position - player.global_position
	var f2 := Vector2(forward.x, forward.z)
	var t2 := Vector2(to_target.x, to_target.z)
	if f2.length_squared() > 0.0001 and t2.length_squared() > 0.0001:
		compass.rotation = f2.angle_to(t2)
	var dist := to_target.length()
	distance_label.text = "%.1f m" % dist
	# 鬼が近いほど赤く脈打つ（Runner 側だけの情報）
	var a := clampf(inverse_lerp(DANGER_FAR, DANGER_NEAR, dist), 0.0, 1.0) * 0.6
	# 見られている間は距離に関わらず必ず出す。
	# 「近いが見失われている」と「遠いが見られている」は別の危険なので、
	# バナー（離散）とヴィネット（連続）で二重に伝える
	if GameManager.spotted:
		a = maxf(a, 0.45)
	vignette.modulate.a = a * (0.85 + 0.15 * sin(Time.get_ticks_msec() * 0.012))


func _nearest_hunter(player: Node3D) -> Node3D:
	var best: Node3D = null
	var best_dist := INF
	var runner_name := str(GameManager.runner_id)
	for p in get_tree().get_nodes_in_group("players"):
		if p.name == runner_name:
			continue
		var d: float = p.global_position.distance_to(player.global_position)
		if d < best_dist:
			best_dist = d
			best = p
	for cpu in get_tree().get_nodes_in_group("cpu_hunters"):
		var d: float = cpu.global_position.distance_to(player.global_position)
		if d < best_dist:
			best_dist = d
			best = cpu
	return best


func _on_compass_draw() -> void:
	var c := compass.size * 0.5
	var points := PackedVector2Array([
		c + Vector2(0, -40), c + Vector2(25, 22), c + Vector2(0, 9), c + Vector2(-25, 22),
	])
	compass.draw_colored_polygon(points, ARROW_COLOR)
	compass.draw_polyline(points + PackedVector2Array([points[0]]), INK, 3.0, true)


func _on_map_draw() -> void:
	var s := map_panel.size
	map_panel.draw_rect(Rect2(Vector2.ZERO, s), Color(0.06, 0.05, 0.12, 0.92))
	for idx in WorldData.ZONE_COUNT:
		var c := WorldData.zone_color(idx).darkened(0.35)
		c.a = 0.92
		map_panel.draw_rect(_zone_rect(idx), c)
		map_panel.draw_rect(_zone_rect(idx), Color(0, 0, 0, 0.25), false, 1.0)
	# 角丸は draw_rect では出せないので、太い枠を上から重ねて角を隠す
	var frame := StyleBoxFlat.new()
	frame.draw_center = false
	frame.bg_color = Color(0, 0, 0, 0)
	frame.set_corner_radius_all(18)
	frame.set_border_width_all(10)
	frame.border_color = Color(0.06, 0.05, 0.12, 1)
	map_panel.draw_style_box(frame, Rect2(Vector2.ZERO, s))

	var runner_name := str(GameManager.runner_id)
	for p in get_tree().get_nodes_in_group("players"):
		if p.name != runner_name:
			_draw_marker(_map_point(p.global_position), HUNTER_DOT)
	for cpu in get_tree().get_nodes_in_group("cpu_hunters"):
		_draw_marker(_map_point(cpu.global_position), HUNTER_DOT)

	var player := _get_local_player()
	if player:
		var center := _map_point(player.global_position)
		_draw_marker(center, SELF_DOT)
		var forward: Vector3 = -player.global_transform.basis.z
		var dir2 := Vector2(forward.x, forward.z).normalized()
		map_panel.draw_line(center, center + dir2 * 13.0, SELF_DOT, 2.5, true)


func _draw_marker(p: Vector2, c: Color) -> void:
	map_panel.draw_circle(p, 11.0, Color(c.r, c.g, c.b, 0.22))
	map_panel.draw_circle(p, 5.5, c)
	map_panel.draw_circle(p, 2.2, Color(1, 1, 1, 0.9))


## ゾーンの床範囲をミニマップ上の矩形に変換する
func _zone_rect(idx: int) -> Rect2:
	var col: int = WorldData.ZONE_COL[idx]
	var row: int = WorldData.ZONE_ROW[idx]
	var x0: float = WorldData.AXIS_CENTER[col] - WorldData.AXIS_SIZE[col] * 0.5
	var z0: float = WorldData.AXIS_CENTER[row] - WorldData.AXIS_SIZE[row] * 0.5
	var s := map_panel.size
	return Rect2(
		(x0 - WORLD_MIN) / WORLD_SIZE * s.x,
		(z0 - WORLD_MIN) / WORLD_SIZE * s.y,
		WorldData.AXIS_SIZE[col] / WORLD_SIZE * s.x,
		WorldData.AXIS_SIZE[row] / WORLD_SIZE * s.y)


func _map_point(world: Vector3) -> Vector2:
	var u := clampf((world.x - WORLD_MIN) / WORLD_SIZE, 0.0, 1.0)
	var v := clampf((world.z - WORLD_MIN) / WORLD_SIZE, 0.0, 1.0)
	return Vector2(u * map_panel.size.x, v * map_panel.size.y)


## --- 演出（状態遷移とトースト） ------------------------------------------

func _on_state_changed(new_state: int) -> void:
	# ロビーは HUD で唯一クリックできる UI。待機中に戻ったらマウスを返す
	# （毎フレームやると待機中に視点を回せなくなるので、状態が変わった瞬間だけ）
	if new_state == GameManager.State.WAITING:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if new_state != GameManager.State.PLAYING:
		_hide_spotted_banner()  # 見られたままラウンドが終わる（＝捕まる）ので必ず消す
	if new_state == GameManager.State.PLAYING:
		_pop_in(role_badge)
	elif new_state == GameManager.State.RESULT:
		_pop_in(result_panel.get_node("Box"))


## 「見られている」は継続状態なので、一過性のトーストではなく専用バナーで出す。
## 点滅はポーリングではなくシグナルのエッジで駆動する（発生源で
## SPOTTED_HOLD のデバウンスが効いているので、ここでばたつくことはない）
func _on_spotted_changed(is_spotted: bool) -> void:
	if not is_spotted or multiplayer.get_unique_id() != GameManager.runner_id:
		_hide_spotted_banner()
		return
	_kill_spotted_tween()
	_banner_hiding = false
	spotted_banner.visible = true
	spotted_banner.modulate.a = 1.0
	_spotted_tween = create_tween().set_loops()
	_spotted_tween.tween_property(spotted_banner, "modulate:a", 0.4, 0.35)
	_spotted_tween.tween_property(spotted_banner, "modulate:a", 1.0, 0.35)


## フェードアウト中は visible が true のままなので、
## 毎フレーム呼ばれても Tween を作り直さないようにする（作り直すと永久に消えない）
func _hide_spotted_banner() -> void:
	if _banner_hiding or not spotted_banner.visible:
		return
	_kill_spotted_tween()
	_banner_hiding = true
	_spotted_tween = create_tween()
	_spotted_tween.tween_property(spotted_banner, "modulate:a", 0.0, 0.5)
	_spotted_tween.tween_callback(func() -> void:
		spotted_banner.visible = false
		_banner_hiding = false)


## ループする Tween を放置すると同じプロパティを取り合うので、必ず先に殺す
func _kill_spotted_tween() -> void:
	if _spotted_tween and _spotted_tween.is_valid():
		_spotted_tween.kill()
	_spotted_tween = null


func _pop_in(node: Control) -> void:
	# レイアウト確定後でないと size が 0 で、中心ではなく左上から拡大してしまう
	await get_tree().process_frame
	node.pivot_offset = node.size * 0.5
	node.scale = Vector2(0.5, 0.5)
	create_tween().tween_property(node, "scale", Vector2.ONE, 0.45) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _on_effect_gained(effect: int) -> void:
	_toast(TOAST_TEXT.get(effect, "!"), TOAST_COLOR.get(effect, Color.WHITE))


func _toast(text: String, color: Color) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 26)
	label.modulate = color
	toast_tray.add_child(label)
	var tw := create_tween()
	tw.tween_property(label, "modulate:a", 1.0, 0.15).from(0.0)
	tw.tween_interval(1.6)
	tw.tween_property(label, "modulate:a", 0.0, 0.4)
	tw.tween_callback(label.queue_free)


func _get_local_player() -> Player:
	if is_instance_valid(_local_player):
		return _local_player
	var my_name := str(multiplayer.get_unique_id())
	for p in get_tree().get_nodes_in_group("players"):
		if p.name == my_name:
			_local_player = p
			p.effect_gained.connect(_on_effect_gained)
			p.item_changed.connect(_on_item_changed)
			return p
	return null
