extends CanvasLayer

## ローカルプレイヤー向け HUD。
##
## 非対称情報の設計はこの実装の核なので、見た目を変えても崩さないこと:
##   Hunter  : 誰かが Runner を「視認」した時だけ、共有された最後の目撃ゾーンの
##             名前と色を受け取る。視認中は SPOTTED、途切れたら残り秒の
##             カウントダウン、さらに10秒の NO INTEL 後は距離だけ受け取る。
##             逃走者の方向・マーカー・座標は無し。
##             マップは出すが、描かれるのは**味方の鬼と自分だけ**（連携用）。
##   Runner  : 全体の2Dマップ（鬼の位置つき）＋最寄りの鬼への矢印・距離・危険ヴィネット、
##             そして「今 見られている」ことを知らせる SPOTTED バナー。
## Runner 側の情報が多いのは意図的で、非対称性を弱めず強めている。
## マップに逃走者のドットは誰の画面にも描かれない（scenes/hud/minimap.gd の _on_map_draw を参照）。

## scenes/hud/lobby_panel.gd の同名定数と値を揃えておくこと(役割バッジの色と一致させる)
const COLOR_RUNNER := Color(0.35, 1.0, 0.55)
const COLOR_HUNTER := Color(1.0, 0.45, 0.4)
const COLOR_HEAD_START := Color(0.35, 0.85, 1.0)
const COLOR_GOLD := Color(1.0, 0.82, 0.25)
const COLOR_RATING_SYNC := Color(0.6, 0.85, 1.0)

const HUNTER_DISTANCE_DELAY := 10.0
const BUFF_BAR_WIDTH := 64.0
const DANGER_FAR := 28.0   # この距離からヴィネットが出はじめる
const DANGER_NEAR := 7.0   # この距離で最大になる

## HUD は「読まなくても絵で分かる」ことを狙っている。文字で残すのは名前・数字と、
## 原因を伝える通知（切断・レート補正）だけ。絵は tools/blender/build_ui_art.py が書き出す
const KeyHint := preload("res://ui/key_hint.gd")
const ICON_RUNNER := preload("res://ui/icons/role_runner.png")
const ICON_HUNTER := preload("res://ui/icons/role_hunter.png")
const ICON_TAGGED := preload("res://ui/icons/tagged.png")
const ICON_CLOCK := preload("res://ui/icons/clock.png")
const ICON_LOCK := preload("res://ui/icons/lock.png")
const ICON_EYE := preload("res://ui/icons/eye.png")
const ICON_EYE_OFF := preload("res://ui/icons/eye_off.png")
const ICON_DISTANCE := preload("res://ui/icons/distance.png")
const ICON_WIN := preload("res://ui/icons/win.png")
const ICON_LOSE := preload("res://ui/icons/lose.png")
const ICON_STOP := preload("res://ui/icons/stop.png")
const ICON_BANANA := preload("res://ui/icons/item_banana.png")
## ゆうれい(Reverse Tag でつかまった逃げ役)のバッジの透明度。逃げ役の絵を薄くして使い回す
const GHOST_ICON_ALPHA := 0.45
## 効果を受けた瞬間に出す絵（以前は「ブースト！」などの文字だった）
const TOAST_ICON := {
	Player.Effect.BOOST: preload("res://ui/icons/bolt.png"),
	Player.Effect.WARP: preload("res://ui/icons/warp.png"),
	Player.Effect.STUN: preload("res://ui/icons/item_banana.png"),
}
## 持ち物の名前・色・絵（Player.Item と対応）。画面に出すのは絵だけ
const ITEM_INFO := {
	Player.Item.NONE: ["- - -", Color(1, 1, 1, 0.35), null],
	Player.Item.ROCKET: ["ロケット", Color(1.0, 0.55, 0.3), preload("res://ui/icons/item_rocket.png")],
	Player.Item.BANANA: ["バナナ", Color(1.0, 0.86, 0.2), preload("res://ui/icons/item_banana.png")],
	Player.Item.BLOCK: ["ブロック", Color(0.45, 0.85, 1.0), preload("res://ui/icons/item_block.png")],
}
## 左下のキー操作ヒントの絵の大きさ(px)
const KEY_HINT_PX := 34.0
## 取得直後に回すルーレットの出目の並びと、切り替え間隔（速い→遅い）
const ROULETTE_ORDER := [Player.Item.ROCKET, Player.Item.BANANA, Player.Item.BLOCK]
const ROULETTE_FAST := 0.05
const ROULETTE_SLOW := 0.22
## speed バフの付与元はダッシュパネルだけなので、ゲージの満タン基準はその実効果時間を直接参照する。
## 以前は 2.5 を手書きしていて、パネル側を 3.0 秒へ延ばした(8fcdd1e)ときに取り残され、
## 踏んでから0.5秒間ゲージが満タンのまま減らなかった(tests/boost_gauge.tscn が検出)
const BoostPanel := preload("res://scenes/gimmicks/boost_panel.gd")
## バフの名前、残量ゲージの基準になる持続時間、ゲージの色、絵
const BUFF_INFO := {
	&"speed": ["スピード", BoostPanel.BOOST_TIME, Color(1.0, 0.85, 0.25),
		preload("res://ui/icons/bolt.png")],
	&"jump": ["ジャンプ", 8.0, Color(0.55, 0.8, 1.0), preload("res://ui/icons/spring.png")],
}

var _local_player: Player
var _buff_keys: Array = []
var _spotted_tween: Tween
var _banner_hiding := false
var _hunter_distance_delay_left := HUNTER_DISTANCE_DELAY
var _sb_full: StyleBoxFlat
var _sb_mid: StyleBoxFlat
var _sb_low: StyleBoxFlat
var _sb_empty: StyleBoxFlat
var _sb_border: StyleBoxFlat
var _spinning := false
var _spin_index := 0
var _spin_next := 0.0
var _last_rating_delta := 0
## H-03: RankingManager.last_delta_breakdown の退避（結果画面のレート内訳表示用）
var _last_rating_base := 0
var _last_rating_bonus := 0
var _rating_applied := false
var _rating_shown := false  # ①CPU戦や離脱中断ではレート行を表示しない
## Reverse Tag: 「今 敵に見られている」の前回値(エッジで SPOTTED バナーを出し入れする)
var _team_spotted := false
var _swap_tween: Tween

## 待機中に一時的に開く着せ替え/ショップ/フレンド画面。world.tscnのシーンツリーは
## 離れず、hudの子としてオーバーレイ表示することで部屋(接続・スポーン状態)を保つ
const OVERLAY_SCENES := {
	"costume": "res://scenes/costume_screen.tscn",
	"shop": "res://scenes/shop_screen.tscn",
	"friend": "res://scenes/friend_screen.tscn",
}
var _overlay_instance: Control = null
var _overlay_full_notified := false
var _shown_item: int = Player.Item.NONE
var _shown_alpha := 1.0
## 結果画面の事実の行は毎フレーム作り直さず、中身が変わったときだけ組み直す
var _facts_key := ""
var _icon_tween: Tween
## スマホでミニマップを描き直す間隔(秒)。_update_tracking を参照
const MAP_REDRAW_INTERVAL_PHONE := 1.0 / 15.0
var _map_redraw_wait := 0.0

@onready var vignette: TextureRect = $Vignette
@onready var role_badge: PanelContainer = $RoleBadge
@onready var role_icon: TextureRect = $RoleBadge/Row/RoleIcon
@onready var goal_icon: TextureRect = $RoleBadge/Row/GoalIcon
@onready var target_icon: TextureRect = $RoleBadge/Row/TargetIcon
@onready var lock_icon: TextureRect = $RoleBadge/Row/LockIcon
@onready var timer_ring: Control = $TimerRing
@onready var timer_label: Label = $TimerRing/TimerLabel
@onready var zone_chip: PanelContainer = $ZoneChip
@onready var zone_icon: TextureRect = $ZoneChip/Row/ZoneIcon
@onready var zone_swatch: ColorRect = $ZoneChip/Row/Swatch
@onready var zone_label: Label = $ZoneChip/Row/ZoneLabel
## scenes/hud/minimap.gd がアタッチされている(型を書くと組み込みControlに
## 縛られsetup()/update_compass()が呼べないため、意図的に無署名の := で推論させる)
@onready var map_panel := $MapPanel
@onready var compass: Control = $Compass
@onready var distance_chip: PanelContainer = $DistanceChip
@onready var distance_label: Label = $DistanceChip/DistanceLabel
@onready var spotted_banner: TextureRect = $SpottedBanner
@onready var team_chip: PanelContainer = $TeamChip
@onready var turn_label: Label = $TeamChip/Row/TurnLabel
@onready var score_a_label: Label = $TeamChip/Row/ScoreA
@onready var score_b_label: Label = $TeamChip/Row/ScoreB
@onready var swap_banner: Label = $SwapBanner
@onready var item_slot: PanelContainer = $ItemSlot
@onready var item_icon: TextureRect = $ItemSlot/Row/ItemIcon
@onready var buff_tray: HBoxContainer = $BuffTray
@onready var stamina_icon: TextureRect = $StaminaIcon
@onready var stamina_bar: Control = $StaminaBar
@onready var toast_tray: VBoxContainer = $ToastTray
## scenes/hud/lobby_panel.gd がアタッチされている。HUD で唯一クリックできる UI
## なので _ignore_mouse() はここだけ対象外にする(型を書くとupdate_lobby()等の
## 独自メンバーが呼べないため、意図的に無署名の := で推論させる)
@onready var lobby := $Lobby
@onready var key_hints: HBoxContainer = $KeyHints
@onready var info_label: Label = $InfoLabel
@onready var result_panel: CenterContainer = $ResultPanel
@onready var result_icon: TextureRect = $ResultPanel/Box/Col/ResultIcon
@onready var result_title: Label = $ResultPanel/Box/Col/ResultTitle
@onready var result_sub: Label = $ResultPanel/Box/Col/ResultSub
## H-03: 生存時間・鬼人数・トドメ役の事実行＋レート内訳（低レート帯ボーナス分のみ）
@onready var result_facts: HBoxContainer = $ResultPanel/Box/Col/ResultFacts
@onready var result_detail: Label = $ResultPanel/Box/Col/ResultDetail
## M-14対策: 結果画面唯一の操作可能ボタン。lobbyと同じ理由で_ignore_mouse()の対象外にする
@onready var result_skip_btn: Button = $ResultPanel/Box/Col/ResultSkipButton


func _ready() -> void:
	_ignore_mouse(self)
	timer_ring.draw.connect(_on_timer_draw)
	stamina_bar.draw.connect(_on_stamina_draw)
	GameManager.state_changed.connect(_on_state_changed)
	GameManager.spotted_changed.connect(_on_spotted_changed)
	GameManager.runner_cpu_takeover.connect(_on_runner_cpu_takeover)
	RankingManager.server_rating_corrected.connect(_on_server_rating_corrected)
	map_panel.setup(compass, distance_chip, distance_label)
	lobby.open_overlay_requested.connect(_open_overlay)
	lobby.toast_requested.connect(_toast)
	result_skip_btn.pressed.connect(_on_result_skip_pressed)
	_sb_full = _bar_style(Color(0.3, 0.95, 0.55))
	_sb_mid = _bar_style(Color(1.0, 0.85, 0.25))
	_sb_low = _bar_style(Color(1.0, 0.35, 0.35))
	_sb_empty = _bar_style(Color(1, 1, 1, 0.13))
	_sb_border = StyleBoxFlat.new()
	_sb_border.draw_center = false
	_sb_border.bg_color = Color(0, 0, 0, 0)
	_sb_border.set_corner_radius_all(6)
	_sb_border.set_border_width_all(2)
	_sb_border.border_color = Color(1, 1, 1, 0.6)
	_sb_border.anti_aliasing = true
	score_a_label.add_theme_color_override("font_color", GameManager.team.TEAM_COLORS[0])
	score_b_label.add_theme_color_override("font_color", GameManager.team.TEAM_COLORS[1])
	vignette.texture = _radial_texture()
	vignette.modulate = Color(1.0, 0.12, 0.12, 0.0)
	## C-07 T-6: キーボード操作ヒントはタッチ操作時には意味がなく、仮想スティック
	## 直上の視覚密集も緩和するため非表示にする
	info_label.visible = not SettingsManager.should_show_touch_controls()
	_build_key_hints()
	_capture_base_offsets()
	get_viewport().size_changed.connect(_apply_safe_area)
	_apply_safe_area()


## 左下のキー操作ヒント。「キーの絵＋そのキーでできることの絵」を並べる
## (視点・移動・ダッシュ・ダイブ・アイテム・エモート・メニュー)
func _build_key_hints() -> void:
	for entry: Array in [
			[KeyHint.icon("mouse"), null], ["WASD", KeyHint.icon("move")],
			["Shift", KeyHint.icon("bolt")], ["Space", KeyHint.icon("dive")],
			["E", KeyHint.icon("gift")], ["F", KeyHint.icon("emote")],
			["Esc", KeyHint.icon("quit")]]:
		key_hints.add_child(KeyHint.pair(entry[0], entry[1], KEY_HINT_PX))


## iPhone のノッチ・角の丸み(safe area)の分だけ、画面の端に付いた HUD 要素を内側へ寄せる
## (2026-09-30: Web 版を viewport-fit=cover にしてノッチの横まで描くようにしたため)。
## tscn の offset を基準として覚えておき、画面サイズが変わるたびに基準から計算し直す
## (前回ずらした値に重ねてずらさないため)。PC 版・Android では余白が 0 なので何も変わらない。
## Vignette は画面全体を覆う演出なので対象外
var _base_offsets := {}


func _capture_base_offsets() -> void:
	for child in get_children():
		if child is Control and child != vignette:
			var c := child as Control
			_base_offsets[c] = Rect2(c.offset_left, c.offset_top, c.offset_right, c.offset_bottom)


func _apply_safe_area() -> void:
	var insets_dp := WebScreen.safe_area_insets_dp()
	# 余白は実寸どおりに換算する(タッチボタンのような「背の低い画面では縮める」はしない)
	var u := WebScreen.units_per_dp(DisplayServer.screen_get_scale(),
		get_viewport().get_visible_rect().size, get_window().size, 1.0)
	var insets := {}
	for k in insets_dp:
		insets[k] = float(insets_dp[k]) * u
	for c: Control in _base_offsets:
		var o := WebScreen.inset_offsets(
			Rect2(c.anchor_left, c.anchor_top, c.anchor_right, c.anchor_bottom),
			_base_offsets[c], insets)
		c.offset_left = o.position.x
		c.offset_top = o.position.y
		c.offset_right = o.size.x
		c.offset_bottom = o.size.y


## HUD には操作可能なウィジェットが一つも無いので、全 Control をマウス無視にする。
##
## これが無いと、マウスキャプチャ中のカーソル位置（GUI空間の画面中央 640,360）に
## 重なった Control が InputEventMouseMotion を食い潰し、
## player.gd の _unhandled_input が呼ばれず**振り向けなくなる**。
## Godot の入力順は _input -> GUI -> _unhandled_input なので、
## Control が STOP のままだと必ずこうなる。
## 個別ノードに書くのではなく再帰で潰すのは、UI を足した時に再発させないため。
func _ignore_mouse(node: Node) -> void:
	# ロビーと結果画面の「スキップ」ボタンだけは操作できるUIなので触らない。
	# どちらも該当ステート(WAITING/RESULT)でしか visible にならないので、
	# ラウンド中に視点操作を奪うことはない
	if node == lobby or node == result_skip_btn:
		return
	if node is Control:
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in node.get_children():
		_ignore_mouse(c)


func _bar_style(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(6)
	sb.anti_aliasing = true
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
	_update_tracking(player, delta)
	timer_ring.queue_redraw()
	stamina_bar.queue_redraw()


## --- 状態表示 ----------------------------------------------------------

func _update_labels() -> void:
	var my_id := multiplayer.get_unique_id()
	var team_mode := GameManager.in_team_round()
	var my_name := str(my_id)
	var is_runner := GameManager.team.is_runner_name(my_name) if team_mode \
		else my_id == GameManager.runner_id
	# 旧モードは「逃げでなければ鬼」。Reverse Tag にはどちらでもない幽霊がいる
	var is_hunter := GameManager.team.is_hunter_name(my_name) if team_mode else not is_runner
	var is_ghost := team_mode and GameManager.team.is_ghost_name(my_name)
	match GameManager.state:
		GameManager.State.WAITING:
			# 待機中の情報はロビーに集約する。ここにも出すと二重になって散らかる
			role_badge.visible = false
			timer_label.text = ""
			zone_chip.visible = false
			result_panel.visible = false
		GameManager.State.PLAYING, GameManager.State.RESULT:
			role_badge.visible = true
			# H-08: 色だけに頼らず、役割と目的を形の違う絵で示す(lobby_panel.gd の役割の絵と同じ)。
			#   逃げる人: 逃げる人・時計     ＝ 時間まで逃げろ
			#   鬼      : 鬼・手・逃げる人   ＝ つかまえろ
			# 幽霊: 薄い逃げ役の絵。目的は「バナナを鬼に当てて復活」なのでバナナ・鬼の絵を並べる
			role_icon.modulate.a = GHOST_ICON_ALPHA if is_ghost else 1.0
			if is_ghost:
				role_icon.texture = ICON_RUNNER
				goal_icon.texture = ICON_BANANA
				target_icon.texture = ICON_HUNTER
				target_icon.visible = true
			elif is_runner:
				role_icon.texture = ICON_RUNNER
				goal_icon.texture = ICON_CLOCK
				target_icon.visible = false
			else:
				role_icon.texture = ICON_HUNTER
				goal_icon.texture = ICON_TAGGED
				target_icon.texture = ICON_RUNNER
				target_icon.visible = true
			# ヘッドスタート中の鬼はまだ動けない
			lock_icon.texture = ICON_LOCK
			lock_icon.visible = is_hunter and GameManager.head_start_left > 0.0
			if GameManager.head_start_left > 0.0:
				timer_label.text = "%d" % ceili(GameManager.head_start_left)
			else:
				var t := maxi(ceili(GameManager.time_left), 0)
				timer_label.text = "%d:%02d" % [t / 60, t % 60]
			_update_zone_chip(is_runner)
			_update_result(is_runner)
	_update_team_hud(team_mode, is_runner)
	# バナーは逃走者専用。表示はシグナルのエッジで駆動しているので、
	# 役割が変わる経路を取りこぼさないようここでも不変条件を担保する
	var spotted_now := _team_spotted if team_mode else GameManager.spotted
	if spotted_banner.visible and (not is_runner or not spotted_now):
		_hide_spotted_banner()

	lobby.update_lobby(_overlay_instance != null)
	_check_overlay_room_full(GameManager.player_ids().size(), multiplayer.is_server())

	# キー操作のヒントは絵の並び(key_hints)で出す。待機中はロビーのパネルに同じものがあるので隠す。
	# 文字で残すのはデバッグ用の行だけ
	key_hints.visible = GameManager.state != GameManager.State.WAITING \
		and not SettingsManager.should_show_touch_controls()
	info_label.text = tr("デバッグ: R バナナ / T ブロック / Y ロケット / E 使用 / Q メイン画面") \
		if GameManager.debug_cpu_runner else ""


## Reverse Tag の HUD。ターンと得点のチップ、入れかえ予告、SPOTTED の判定。
## SPOTTED は旧モードの spotted_changed シグナルを使わず、ここで毎フレーム引く:
## シグナルの発生源(sight_system.gd)は「逃げ1人」前提のままで、チーム戦の視界は
## team.visible_to(チームごとの見えている敵)に入っているため
func _update_team_hud(team_mode: bool, is_runner: bool) -> void:
	var team := GameManager.team
	var playing := GameManager.state == GameManager.State.PLAYING
	team_chip.visible = team_mode
	if not team_mode:
		_team_spotted = false
		_hide_swap_banner()
		return
	turn_label.text = "%d/%d" % [mini(team.turn + 1, team.TURNS), team.TURNS]
	score_a_label.text = str(team.score[0])
	score_b_label.text = str(team.score[1])
	# 自分のチームの得点を一回り大きくして、どちらが自分たちかを色以外でも分かるようにする
	var mine := team.my_team()
	score_a_label.add_theme_font_size_override("font_size", 32 if mine == 0 else 22)
	score_b_label.add_theme_font_size_override("font_size", 32 if mine == 1 else 22)

	if playing and team.swap_warning():
		swap_banner.text = "%s %d" % [tr("まもなく入れかえ！"), maxi(ceili(GameManager.time_left), 0)]
		if not swap_banner.visible:
			swap_banner.visible = true
			if _swap_tween and _swap_tween.is_valid():
				_swap_tween.kill()
			_swap_tween = create_tween().set_loops()
			# 下げすぎると明るい地面の上で読めなくなる（uishot で確認）
			_swap_tween.tween_property(swap_banner, "modulate:a", 0.7, 0.35)
			_swap_tween.tween_property(swap_banner, "modulate:a", 1.0, 0.35)
	else:
		_hide_swap_banner()

	var seen := playing and is_runner and mine >= 0 \
		and team.visible_to[1 - mine].has(str(multiplayer.get_unique_id()))
	if seen != _team_spotted:
		_team_spotted = seen
		if seen:
			_show_spotted_banner()
		else:
			_hide_spotted_banner()


func _hide_swap_banner() -> void:
	if not swap_banner.visible:
		return
	if _swap_tween and _swap_tween.is_valid():
		_swap_tween.kill()
	_swap_tween = null
	swap_banner.visible = false
	swap_banner.modulate.a = 1.0


## --- 待機中のロビー -----------------------------------------------------
## ロビー一覧・定員変更・役割ボタン等の実装は scenes/hud/lobby_panel.gd($Lobby)に
## 集約してある。ここに残るのはオーバーレイ(着せ替え/ショップ/フレンド)の開閉のみ
## (フルスクリーン表示のため HUD の CanvasLayer 直下に追加する必要があるため)。

## 着せ替え/ショップ/フレンド画面をworld.tscnのシーンツリーを離れずに
## オーバーレイとして開く。閉じる操作はそれぞれのcloseシグナル経由(_on_overlay_closed)
func _open_overlay(key: String) -> void:
	if _overlay_instance != null:
		return
	var scene: PackedScene = load(OVERLAY_SCENES[key])
	var inst: Control = scene.instantiate()
	add_child(inst)
	_overlay_instance = inst
	_overlay_full_notified = false
	GameManager.lobby_overlay_open = true
	if inst.has_signal("closed"):
		inst.closed.connect(_on_overlay_closed)


func _on_overlay_closed() -> void:
	if is_instance_valid(_overlay_instance):
		_overlay_instance.queue_free()
	_overlay_instance = null
	GameManager.lobby_overlay_open = false


## 満員通知: オーバーレイを開いている間だけ人数を監視し、定員に達した瞬間に
## 一度だけポップアップする。定員を下回ったら再度通知できるようリセットする
func _check_overlay_room_full(member_count: int, is_host: bool) -> void:
	if _overlay_instance == null or not is_host:
		return
	var max_m := EosManager.get_current_lobby_max_members()
	if member_count >= max_m:
		if not _overlay_full_notified:
			_overlay_full_notified = true
			_show_room_full_popup()
	else:
		_overlay_full_notified = false


func _show_room_full_popup() -> void:
	var dlg := AcceptDialog.new()
	dlg.dialog_text = tr("部屋の人数が揃いました。戻りますか？")
	dlg.ok_button_text = tr("部屋に戻る")
	add_child(dlg)
	dlg.confirmed.connect(func() -> void:
		_on_overlay_closed()
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	dlg.popup_centered()


## 鬼にだけ、共有された目撃情報を見せる。
## 距離は情報が切れてから10秒後に限り読める。方向・マーカー・座標は出さない。
## 文ではなく「絵＋ゾーンの色＋数字」で出す:
##   手がかりなし = 斜線の目 / 距離 = 両矢印＋m / 発見 = 目＋色＋「!」 / さっき目撃 = 薄い目＋色＋残り秒
## ゾーン名は出さない。場所は色と、ミニマップの該当ゾーンの点灯(minimap.gd)で伝える
func _update_zone_chip(is_runner: bool) -> void:
	# Reverse Tag には「共有された最後の目撃ゾーン」が無い(ミニマップで敵の点を直接見せる)
	if is_runner or GameManager.in_team_round() or GameManager.state != GameManager.State.PLAYING:
		zone_chip.visible = false
		return
	zone_chip.visible = true
	var zone: int = GameManager.spotted_zone
	zone_swatch.visible = zone >= 0
	zone_icon.modulate.a = 1.0
	if zone < 0:
		var distance := _runner_distance(_get_local_player())
		if _hunter_distance_delay_left <= 0.0 and distance >= 0.0:
			zone_icon.texture = ICON_DISTANCE
			zone_label.text = "%d m" % roundi(distance)
		else:
			zone_icon.texture = ICON_EYE_OFF
			zone_label.text = ""
		zone_chip.modulate.a = 1.0
	elif GameManager.spotted:
		zone_icon.texture = ICON_EYE
		zone_label.text = "!"
		zone_swatch.color = WorldData.zone_color(zone)
		zone_chip.modulate.a = 0.75 + 0.25 * sin(Time.get_ticks_msec() * 0.012)
	else:
		zone_icon.texture = ICON_EYE
		zone_icon.modulate.a = 0.55
		zone_label.text = "%d" % maxi(ceili(GameManager.intel_left), 0)
		zone_swatch.color = WorldData.zone_color(zone).darkened(0.35)
		zone_chip.modulate.a = 1.0
	zone_label.visible = not zone_label.text.is_empty()


func _update_hunter_distance_delay(delta: float, player: Player) -> void:
	var is_hunter := (
		GameManager.state == GameManager.State.PLAYING
		and player != null
		and multiplayer.get_unique_id() != GameManager.runner_id
		and not GameManager.in_team_round()
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
	if GameManager.in_team_round():
		_update_team_result()
		return
	var won: bool = GameManager.result_runner_won
	var copy := result_copy(is_runner, won, GameManager.result_reason)
	# 文字は大見出しの1語だけ。説明文(copy[1])は出さず、勝ち負けは絵で伝える
	result_title.text = copy[0]
	if GameManager.result_reason == GameManager.EndReason.RUNNER_LEFT:
		result_title.modulate = COLOR_GOLD
		result_icon.texture = ICON_STOP
		result_sub.visible = false
	else:
		result_title.modulate = COLOR_RUNNER if won else COLOR_HUNTER
		result_icon.texture = ICON_WIN if is_runner == won else ICON_LOSE
		# レート変動（①CPU戦・離脱中断は出さない）。数字だけにする
		result_sub.visible = _rating_shown
		if _rating_shown:
			var sign_str := "+" if _last_rating_delta >= 0 else ""
			result_sub.text = "%d Pt (%s%d)" % [ProfileManager.rating, sign_str, _last_rating_delta]

	_update_result_facts()
	result_detail.text = _result_detail_text()
	result_detail.visible = not result_detail.text.is_empty()
	# 自動で戻るまでの残り秒は、やり直しボタンの数字で出す
	result_skip_btn.text = "%d" % maxi(ceili(GameManager.result_left), 0)


## static 関数では Object.tr() が使えないので TranslationServer.translate() で訳す(L-09)
static func result_copy(is_runner: bool, runner_won: bool, reason: int) -> PackedStringArray:
	var pair: Array[String]
	if reason == GameManager.EndReason.RUNNER_LEFT:
		pair = ["ちゅうだん", "逃げる人が抜けました"]
	elif runner_won:
		if is_runner:
			pair = ["にげきった！", "最後まで逃げきった"]
		else:
			pair = ["にげきられた…", "逃げる人をつかまえられなかった"]
	elif is_runner:
		pair = ["つかまった…", "鬼につかまってしまった"]
	else:
		pair = ["つかまえた！", "逃げる人をつかまえた"]
	return PackedStringArray([
		TranslationServer.translate(pair[0]), TranslationServer.translate(pair[1])])


## Reverse Tag の結果。result_runner_won は「チームAの勝ち」の意味で入っている
func _update_team_result() -> void:
	var mine := GameManager.team.my_team()
	var reason: int = GameManager.result_reason
	var draw := reason == GameManager.EndReason.TEAM_DRAW
	var won: bool = GameManager.result_runner_won == (mine <= 0)
	var copy := team_result_copy(won, reason)
	result_title.text = copy[0]
	if draw:
		result_title.modulate = COLOR_GOLD
		result_icon.texture = ICON_STOP
	else:
		result_title.modulate = COLOR_RUNNER if won else COLOR_HUNTER
		result_icon.texture = ICON_WIN if won else ICON_LOSE
	result_sub.visible = false  # レート対象外
	_update_team_result_facts()
	result_detail.visible = false
	result_skip_btn.text = "%d" % maxi(ceili(GameManager.result_left), 0)


## Reverse Tag の勝敗文言。my_team_won は引き分けのとき無視される
static func team_result_copy(my_team_won: bool, reason: int) -> PackedStringArray:
	var pair: Array[String]
	if reason == GameManager.EndReason.TEAM_DRAW:
		pair = ["ひきわけ", "同点で引き分け"]
	elif my_team_won:
		pair = ["かった！", "全員つかまえた" if reason == GameManager.EndReason.TEAM_WIPE else "得点で勝ち"]
	else:
		pair = ["まけた…", "全員つかまってしまった" if reason == GameManager.EndReason.TEAM_WIPE else "得点で負け"]
	return PackedStringArray([
		TranslationServer.translate(pair[0]), TranslationServer.translate(pair[1])])


## 事実の行は最終得点(チーム色の数字)だけ。_update_result_facts と同じく変化時だけ組み直す
func _update_team_result_facts() -> void:
	var sc := GameManager.team.score
	var key := "team|%d|%d" % [sc[0], sc[1]]
	if key == _facts_key:
		return
	_facts_key = key
	for c in result_facts.get_children():
		result_facts.remove_child(c)
		c.queue_free()
	for i in 2:
		var label := Label.new()
		label.text = "%s %d" % [tr(GameManager.team.TEAM_NAMES[i]), sc[i]]
		label.add_theme_font_size_override("font_size", 28)
		label.add_theme_color_override("font_color", GameManager.team.TEAM_COLORS[i])
		result_facts.add_child(label)
		if i == 0:
			var sep := Label.new()
			sep.text = ":"
			sep.add_theme_font_size_override("font_size", 28)
			result_facts.add_child(sep)


## H-03: 「何が起きたか」の事実行。時計＋時間、鬼の絵＋人数、手の絵＋つかまえた人。
## 毎フレーム呼ばれるが、参照する値は RESULT 中は固定されている(time_left は RESULT 中は
## 減らない)ので、中身が変わったときだけ組み直す
func _update_result_facts() -> void:
	var elapsed := GameManager.ROUND_TIME - GameManager.time_left
	var tagger := _tagger_display_name()
	var key := "%s|%d|%s" % [_mmss(elapsed), GameManager.round_hunter_count, tagger]
	if key == _facts_key:
		return
	_facts_key = key
	for c in result_facts.get_children():
		result_facts.remove_child(c)
		c.queue_free()
	result_facts.add_child(_result_fact(ICON_CLOCK, _mmss(elapsed)))
	if GameManager.round_hunter_count > 0:
		result_facts.add_child(_result_fact(ICON_HUNTER, "x%d" % GameManager.round_hunter_count))
	if not tagger.is_empty():
		result_facts.add_child(_result_fact(ICON_TAGGED, tagger))


func _result_fact(texture: Texture2D, text: String) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(KeyHint.image(texture, 40.0))
	var label := Label.new()
	# 名前は利用者の入力なので自動翻訳させない
	label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	label.text = text
	label.add_theme_font_size_override("font_size", 22)
	box.add_child(label)
	return box


## H-03: レート内訳(低レート帯ボーナス分のみ)。
## 生存スコア分・鬼人数ハンデ分は式の上で加算項ではなく(ロジスティック期待値の
## 入力なので)Pt単位に分解できない。分解できるのは最後に純加算される低レート帯
## ボーナス(ranking_manager.gd の手順8)だけなので、残りは事実の行(絵)として並べる
func _result_detail_text() -> String:
	# ボーナスが0(ダイヤ帯以上)のときは合計＝基礎なので内訳行そのものを出さない
	if _rating_shown and _last_rating_bonus != 0:
		return tr("内訳: 基礎 %s ／ 低レート帯ボーナス %s") \
			% [_signed(_last_rating_base), _signed(_last_rating_bonus)]
	return ""


## 捕まった試合でだけ「誰がタッチしたか」を返す。逃げ切り・中断では空文字
func _tagger_display_name() -> String:
	if GameManager.result_reason != GameManager.EndReason.TAGGED:
		return ""
	if GameManager.tagger_peer_id < 0:
		return "CPU"
	if GameManager.tagger_peer_id == multiplayer.get_unique_id():
		return tr("あなた")
	return GameManager.nickname_for(GameManager.tagger_peer_id)


static func _mmss(sec: float) -> String:
	var s := maxi(int(sec), 0)
	return "%d:%02d" % [s / 60, s % 60]


## 既存のレート行(_update_result内)と同じ「+12 / -12」表記に揃える
static func _signed(n: int) -> String:
	return "+%d" % n if n >= 0 else str(n)


## M-14対策: 結果画面に唯一の操作(自動カウントダウンを待たずに次へ進む)を足す
func _on_result_skip_pressed() -> void:
	GameManager.skip_result()


## --- 円形タイマー ------------------------------------------------------

func _on_timer_draw() -> void:
	if GameManager.state == GameManager.State.WAITING:
		return
	var c := timer_ring.size * 0.5
	timer_ring.draw_arc(c, 54.0, 0.0, TAU, 64, Color(0, 0, 0, 0.45), 14.0, true)
	var frac := 0.0
	var col := COLOR_RUNNER
	# Reverse Tag の時計は「今のターンの残り」。入れかえ直後の静止は短い(SWAP_FREEZE)ので、
	# 一周の基準もそれに合わせる(HEAD_START のままだと入れかえのたびにリングが 3/8 から始まる)
	var team_mode := GameManager.in_team_round()
	if GameManager.head_start_left > 0.0:
		var full: float = GameManager.HEAD_START
		if team_mode and GameManager.team.turn > 0:
			full = GameManager.team.SWAP_FREEZE
		frac = clampf(GameManager.head_start_left / full, 0.0, 1.0)
		col = COLOR_HEAD_START
	else:
		var total: float = GameManager.team.TURN_TIME if team_mode else GameManager.ROUND_TIME
		frac = clampf(GameManager.time_left / total, 0.0, 1.0)
		if frac < 0.34:
			col = Color(1.0, 0.72, 0.2)
		if frac < 0.15:
			col = Color(1.0, 0.3, 0.3)
	timer_ring.draw_arc(c, 54.0, -PI * 0.5, -PI * 0.5 + TAU * frac, 64, col, 12.0, true)


## --- スタミナ（連続バー） -----------------------------------------------

func _update_stamina(player: Player) -> void:
	var show := player != null and GameManager.state != GameManager.State.WAITING
	stamina_bar.visible = show
	stamina_icon.visible = show


func _on_stamina_draw() -> void:
	var player := _get_local_player()
	if player == null:
		return
	var w := stamina_bar.size.x
	var h := stamina_bar.size.y
	stamina_bar.draw_style_box(_sb_empty, Rect2(0.0, 0.0, w, h))
	var frac := clampf(player.stamina / player.stamina_max(), 0.0, 1.0)
	if frac > 0.0:
		var fill: StyleBoxFlat
		if frac <= 0.10:
			fill = _sb_low
		elif frac <= 0.30:
			fill = _sb_mid
		else:
			fill = _sb_full
		stamina_bar.draw_style_box(fill, Rect2(0.0, 0.0, w * frac, h))
	# 背景に同化しないよう、残量に関わらず枠は常に最前面へ重ねる
	stamina_bar.draw_style_box(_sb_border, Rect2(0.0, 0.0, w, h))


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
	_set_shown_icon(player.item, 1.0)


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
		_punch_icon()  # コマが切り替わった瞬間だけ弾ませ、リールが1コマ進んだ手応えを出す
	_set_shown_icon(ROULETTE_ORDER[_spin_index], 0.7)  # 確定前は薄く出す


## ルーレットが止まった瞬間。ここで初めて中身を名乗る
func _confirm_item(held: int) -> void:
	if held == Player.Item.NONE:
		return  # ラウンド開始などで持ち物ごと消えた場合
	var info: Array = ITEM_INFO.get(held, ITEM_INFO[Player.Item.NONE])
	_toast_icon(info[2])
	_set_shown_icon(held, 1.0)
	item_slot.pivot_offset = item_slot.size * 0.5
	var tw := create_tween()
	var tween := tw.tween_property(item_slot, "scale", Vector2.ONE, 0.4)
	tween.from(Vector2(1.4, 1.4))
	tween.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


## スロットの絵に表示中の出目を反映する。確定前は薄く出す
func _set_shown_icon(item: int, alpha: float) -> void:
	_shown_item = item
	_shown_alpha = alpha
	item_icon.texture = ITEM_INFO.get(item, ITEM_INFO[Player.Item.NONE])[2]
	item_icon.modulate.a = alpha


## リールが1コマ進むたびに小さく弾ませる。連続で呼ばれるので前のを必ず止めてから張り直す
func _punch_icon() -> void:
	if _icon_tween != null and _icon_tween.is_valid():
		_icon_tween.kill()
	item_icon.pivot_offset = item_icon.size * 0.5
	item_icon.scale = Vector2(1.25, 1.25)
	_icon_tween = create_tween()
	_icon_tween.tween_property(item_icon, "scale", Vector2.ONE, 0.12) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


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
		var info: Array = BUFF_INFO.get(key, ["BUFF", 6.0, Color.WHITE, null])
		var fill: ColorRect = buff_tray.get_child(i).get_node("Col/Fill")
		var frac := clampf(player.buffs.time_left(key) / info[1], 0.0, 1.0)
		fill.custom_minimum_size.x = BUFF_BAR_WIDTH * frac
		i += 1


func _make_buff_chip(key: StringName) -> Control:
	var info: Array = BUFF_INFO.get(key, ["BUFF", 6.0, Color.WHITE, null])
	var panel := PanelContainer.new()
	var col := VBoxContainer.new()
	col.name = "Col"
	col.add_theme_constant_override("separation", 4)
	var label := KeyHint.image(info[3], 40.0)
	var fill := ColorRect.new()
	fill.name = "Fill"
	fill.color = info[2]
	fill.custom_minimum_size = Vector2(BUFF_BAR_WIDTH, 4)
	fill.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	col.add_child(label)
	col.add_child(fill)
	panel.add_child(col)
	return panel


## --- ミニマップ（両陣営）と Runner 専用の方位・距離・危険表示 ----------------
## ミニマップの描画とコンパス回転・距離表示は scenes/hud/minimap.gd($MapPanel)に
## 集約してある。危険ヴィネット（近いほど赤く脈打つ）だけはここに残す
## ("見られている"バナーと合わせて管理する in-match HUD の危険表示の一部だから)。
## コンパスとヴィネットは同じ「最寄りの鬼との距離」を使うので、二重に計算しない
## よう minimap.gd の update_compass() が最寄りの鬼(または null)を返す

func _update_tracking(player: Player, delta: float) -> void:
	var playing := GameManager.state == GameManager.State.PLAYING and player != null
	var is_runner := playing and (
		GameManager.team.is_runner_name(str(multiplayer.get_unique_id())) if GameManager.in_team_round()
		else multiplayer.get_unique_id() == GameManager.runner_id)
	# マップは両陣営に出す。鬼の画面には味方の鬼と自分しか描かれないので
	# （minimap.gd の _on_map_draw を参照）、逃走者の位置が漏れることはない
	map_panel.visible = playing
	if playing:
		# スマホだけ描き直しを間引く(発熱対策)。毎回全マーカーを描き直しており、
		# 小さな地図の点が 1/15 秒ごとに動いても見た目は変わらない。PC は今までどおり毎フレーム
		_map_redraw_wait -= delta
		if not PhonePerf.enabled() or _map_redraw_wait <= 0.0:
			_map_redraw_wait = MAP_REDRAW_INTERVAL_PHONE
			map_panel.queue_redraw()

	var target: Node3D = map_panel.update_compass(player, is_runner)
	if target == null:
		vignette.modulate.a = 0.0
		return

	var dist := player.global_position.distance_to(target.global_position)
	# 鬼が近いほど赤く脈打つ（Runner 側だけの情報）
	var a := clampf(inverse_lerp(DANGER_FAR, DANGER_NEAR, dist), 0.0, 1.0) * 0.6
	# 見られている間は距離に関わらず必ず出す。
	# 「近いが見失われている」と「遠いが見られている」は別の危険なので、
	# バナー（離散）とヴィネット（連続）で二重に伝える
	if _team_spotted if GameManager.in_team_round() else GameManager.spotted:
		a = maxf(a, 0.45)
	vignette.modulate.a = a * (0.85 + 0.15 * sin(Time.get_ticks_msec() * 0.012))


## --- 演出（状態遷移とトースト） ------------------------------------------

func _on_state_changed(new_state: int) -> void:
	# ロビーは HUD で唯一クリックできる UI。待機中に戻ったらマウスを返す
	# （毎フレームやると待機中に視点を回せなくなるので、状態が変わった瞬間だけ）
	if new_state == GameManager.State.WAITING:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_rating_applied = false
		# 事実の行はノードで組むので、閉じたリザルトに残さない(ラウンド後にノード数が戻らなくなる)
		_facts_key = ""
		for c in result_facts.get_children():
			result_facts.remove_child(c)
			c.queue_free()
	if new_state != GameManager.State.PLAYING:
		_hide_spotted_banner()  # 見られたままラウンドが終わる（＝捕まる）ので必ず消す
		_team_spotted = false
		_hide_swap_banner()
	if new_state == GameManager.State.PLAYING:
		_pop_in(role_badge)
		_rating_applied = false
	elif new_state == GameManager.State.RESULT:
		if not _rating_applied:
			_rating_applied = true
			_last_rating_delta = 0
			_last_rating_base = 0
			_last_rating_bonus = 0
			# ①VS CPU戦（round_is_ranked==false）と、逃走者離脱による中断はレート非適用
			# Reverse Tag は逃げ1人を前提にしたレート式に当てはまらないのでレート対象外
			_rating_shown = GameManager.round_is_ranked \
				and GameManager.result_reason != GameManager.EndReason.RUNNER_LEFT \
				and not GameManager.in_team_round()
			if _rating_shown:
				var my_id := multiplayer.get_unique_id()
				var is_runner := my_id == GameManager.runner_id
				var won := (is_runner and GameManager.result_runner_won) or (not is_runner and not GameManager.result_runner_won)
				var survival := GameManager.ROUND_TIME - GameManager.time_left
				var is_tagger := (my_id == GameManager.tagger_peer_id)
				var opp_rating := RankingManager.opponent_avg_rating(is_runner)
				_last_rating_delta = RankingManager.apply_match_end(
					is_runner, won, survival, GameManager.round_hunter_count, is_tagger, opp_rating)
				# H-03: 結果画面の内訳表示用（低レート帯ボーナス分だけを分離して見せる）
				_last_rating_base = int(RankingManager.last_delta_breakdown.get("base", _last_rating_delta))
				_last_rating_bonus = int(RankingManager.last_delta_breakdown.get("bonus", 0))
			elif not GameManager.round_is_ranked:
				# 離脱中断（オンライン）はどちらの戦績にも数えない。CPU戦のみ練習回数に加算
				ProfileManager.record_casual_match()
		_pop_in(result_panel.get_node("Box"))


## 「見られている」は継続状態なので、一過性のトーストではなく専用バナーで出す。
## 点滅はポーリングではなくシグナルのエッジで駆動する（発生源で
## SPOTTED_HOLD のデバウンスが効いているので、ここでばたつくことはない）
func _on_spotted_changed(is_spotted: bool) -> void:
	if GameManager.in_team_round():
		return  # Reverse Tag は _update_team_hud が team.visible_to から出し入れする
	if not is_spotted or multiplayer.get_unique_id() != GameManager.runner_id:
		_hide_spotted_banner()
		return
	_show_spotted_banner()


func _show_spotted_banner() -> void:
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
	_toast_icon(TOAST_ICON.get(effect))


## H-02: 逃げる役の切断でCPUが代行を始めたことをその場で気づけるようにする
func _on_runner_cpu_takeover(peer_name: String) -> void:
	_toast(tr("%s が切断 ― CPUが代わりに逃げます") % peer_name, Color(1.0, 0.75, 0.4))


## C-03 R-4: 試合中にサーバー補正RPCが届いた場合のトースト通知
func _on_server_rating_corrected(_old_rating: int, new_rating: int, delta: int) -> void:
	_toast(rating_sync_toast_text(delta, new_rating), COLOR_RATING_SYNC)


## C-03 R-4: サーバー同期レート補正トーストの文言(純粋関数、tests/で直接検証)。
## static 関数なので TranslationServer.translate() で訳す(L-09)
static func rating_sync_toast_text(delta: int, new_rating: int) -> String:
	var sign_str := "+" if delta >= 0 else ""
	return TranslationServer.translate("レートがサーバーと同期され、%s%d Pt 補正されました（現在 %d Pt）") \
		% [sign_str, delta, new_rating]


func _toast(text: String, color: Color) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 26)
	label.modulate = color
	toast_tray.add_child(label)
	_fade_toast(label)


## 効果やアイテムの取得は文ではなく絵で知らせる（何が起きたかは絵で足りる）
func _toast_icon(texture: Texture2D) -> void:
	if texture == null:
		return
	var icon := KeyHint.image(texture, 72.0)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	toast_tray.add_child(icon)
	_fade_toast(icon)


func _fade_toast(node: Control) -> void:
	var tw := create_tween()
	tw.tween_property(node, "modulate:a", 1.0, 0.15).from(0.0)
	tw.tween_interval(1.6)
	tw.tween_property(node, "modulate:a", 0.0, 0.4)
	tw.tween_callback(node.queue_free)


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
