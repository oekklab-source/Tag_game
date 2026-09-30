extends CanvasLayer

## C-07 T-2: タッチコントロール土台。現時点ではポーズボタンのみ実装。
## T-3(仮想スティック)/T-5(アクションボタン)がこの下に子ノードを追加していく前提のシーンなので、
## 削除・大規模な構造変更をせず、素直に子ノードを足していくこと。
##
## hud.gd の _ignore_mouse() は self (HUD) 配下を再帰的に MOUSE_FILTER_IGNORE 化するが、
## TouchControls は world.tscn 上で HUD の兄弟(別CanvasLayer)なのでこの再帰に一切
## 巻き込まれない。ポーズボタンは Control の既定 mouse_filter (STOP) のままでよい。
##
## [大きさは dp(実寸)で決める(2026-09-30 スマホ実機の指摘で変更)]
## 以前は tscn の 1920x1080 基準の固定値で、スマホではすべてが約 0.36〜0.45 倍に縮み、
## アクションボタンは約 35〜43dp しかなかった(Android の最小推奨 48dp 未満)。
## 今は _apply_layout() が下の LAYOUT_* 定数(dp)を画面の座標単位へ換算して並べ直す
## (tscn 側の offset は初期値にすぎない)。画面サイズが変わるたび(回転・全画面の切り替え)に
## やり直す。配置の考え方:
## - 左手: 追従スティック。画面左下の広い範囲のどこに指を置いてもよい(virtual_joystick.gd)
## - 右手: 右下隅のダイブ(最大)を中心に、ダッシュ(左)・アイテム(上)・カモン(左上)を扇形に置く。
##   当たり判定同士が重ならない間隔にして、2本の指で別々のボタンを押しても隣を誤爆しない。
##   ボタンの無い右側の領域は視点ドラッグ(touch_look_zone.gd)
## - iPhone のノッチ・角の丸みの分(safe area)だけ内側へ寄せる

## 以下すべて dp。LAYOUT_BTN_* は見た目の直径で、当たり判定は LAYOUT_HIT_PAD だけ外側まで
const LAYOUT_MARGIN := 20.0
const LAYOUT_STICK_RADIUS := 75.0
const LAYOUT_BTN_MAIN := 84.0 ## ダイブ
const LAYOUT_BTN_SUB := 68.0 ## ダッシュ・アイテム
const LAYOUT_BTN_SMALL := 56.0 ## カモン
const LAYOUT_TAUNT := 52.0 ## カモン長押しの挑発3種
const LAYOUT_TOP_BTN := 48.0 ## ≡・全画面
const LAYOUT_HIT_PAD := 8.0
const LAYOUT_ARC := 110.0 ## ダイブの中心からダッシュ・アイテムの中心まで
const LAYOUT_ARC_DIAG := 115.0 ## ダイブの中心からカモンの中心まで(斜め45°)
const LAYOUT_FONT := 15.0
## スティックを掴む範囲(画面に対する割合)。左 40%・下 70%
const STICK_ZONE_W := 0.4
const STICK_ZONE_H := 0.7

@onready var pause_button: Button = $PauseButton
@onready var fullscreen_button: Button = $FullscreenButton
@onready var joystick: Control = $VirtualJoystick
@onready var dash_button: Panel = $ActionDash
@onready var dive_button: Panel = $ActionDive
@onready var item_button: Panel = $ActionUseItem
@onready var emote_button: Panel = $ActionEmote

var _local_player: Node = null


func _ready() -> void:
	pause_button.pressed.connect(_on_pause_pressed)
	# hud.gdの_on_state_changed()と同じ「状態が変わった瞬間だけ処理する」方式。
	# 現状SettingsManagerに変更通知シグナルが無く、かつtouch_controls_modeを
	# PLAYING中に変更できる導線も無い(設定画面はタイトルからしか開けない)ため、
	# 毎フレームのポーリングは不要。GameManager.state_changedだけで十分
	GameManager.state_changed.connect(_on_state_changed)
	# T-8(RV-06): QuitMenuはポーズも状態遷移もしない(autoload/quit_menu.gd参照)ので、
	# state_changedだけではポーズ中もTouchControlsがvisibleのままになり、
	# ダイアログの裏で移動・視点回転・ダッシュが発火していた。専用シグナルで拾う
	QuitMenu.opened_changed.connect(_on_quit_menu_toggled)
	# スティックから指を離したらダッシュもOFF(止まったのにダッシュが残ると、
	# 次に動き出した瞬間にスタミナを使ってしまう)
	joystick.released.connect(func() -> void: dash_button.set_toggled(false))
	fullscreen_button.pressed.connect(_on_fullscreen_pressed)
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	_refresh_visibility()
	_apply_layout()


func _on_viewport_size_changed() -> void:
	_apply_layout()


func _on_state_changed(_new_state: int) -> void:
	_refresh_visibility()


func _on_quit_menu_toggled(_is_open: bool) -> void:
	_refresh_visibility()


## 配下の virtual_joystick / touch_look_zone / touch_action_button は
## いずれもこの CanvasLayer の visible だけを見て _input() を処理するので、
## 「触らせたくない状況」はすべてここに集約する
func _refresh_visibility() -> void:
	visible = (
		SettingsManager.should_show_touch_controls()
		and GameManager.state == GameManager.State.PLAYING
		and not QuitMenu.is_open())


func _on_pause_pressed() -> void:
	QuitMenu.open()


## 全画面ボタン。Fullscreen API がある端末(Android・iPad)だけに出す
## (iPhone ではタイトル画面の同じボタンが「ホーム画面に追加」の案内を出す。試合中には出さない)
func _on_fullscreen_pressed() -> void:
	WebScreen.toggle_fullscreen()


func _refresh_fullscreen_button() -> void:
	fullscreen_button.visible = WebScreen.fullscreen_enabled() and not WebScreen.is_standalone()
	var on := WebScreen.is_fullscreen()
	fullscreen_button.text = tr("全画面を解除") if on else tr("全画面")


## touch_look_zone.gd が「上端のボタンの上の指は視点ドラッグにしない」判定に使う
func is_on_top_button(p: Vector2) -> bool:
	if pause_button.get_global_rect().has_point(p):
		return true
	return fullscreen_button.visible and fullscreen_button.get_global_rect().has_point(p)


## 操作しているローカルプレイヤー(ダッシュの自動OFF・視点ドラッグで使う)
func get_local_player() -> Node:
	if is_instance_valid(_local_player):
		return _local_player
	if multiplayer.multiplayer_peer == null:
		return null
	var my_name := str(multiplayer.get_unique_id())
	for p in get_tree().get_nodes_in_group("players"):
		if p.name == my_name:
			_local_player = p
			return p
	return null


func _units_per_dp() -> float:
	return WebScreen.units_per_dp(DisplayServer.screen_get_scale(),
		get_viewport().get_visible_rect().size, get_window().size)


## dp の定数から全コントロールの位置と大きさを決め直す(ヘッダ参照)。
## テストから画面サイズ・換算係数・safe area を直接渡せるよう、省略したときだけ実画面から取る
func _apply_layout(vis := Vector2.ZERO, u := 0.0, insets_dp := {}) -> void:
	if vis == Vector2.ZERO:
		vis = get_viewport().get_visible_rect().size
	if u <= 0.0:
		u = _units_per_dp()
	if insets_dp.is_empty():
		insets_dp = WebScreen.safe_area_insets_dp()
	var left: float = (LAYOUT_MARGIN + float(insets_dp.get("left", 0.0))) * u
	var top: float = (LAYOUT_MARGIN + float(insets_dp.get("top", 0.0))) * u
	var right: float = vis.x - (LAYOUT_MARGIN + float(insets_dp.get("right", 0.0))) * u
	var bottom: float = vis.y - (LAYOUT_MARGIN + float(insets_dp.get("bottom", 0.0))) * u

	# 上端: ≡ と全画面(全画面は文言が入るので横長)
	var tb := LAYOUT_TOP_BTN * u
	_place_top_left(pause_button, Vector2(left, top), Vector2(tb, tb))
	_place_top_left(fullscreen_button, Vector2(left + tb + 12.0 * u, top), Vector2(tb * 2.6, tb))
	pause_button.add_theme_font_size_override("font_size", int(round(24.0 * u)))
	fullscreen_button.add_theme_font_size_override("font_size", int(round(14.0 * u)))
	_refresh_fullscreen_button()

	# 左手: 追従スティック
	var r := LAYOUT_STICK_RADIUS * u
	var rest := Vector2(left + r + 10.0 * u, bottom - r - 10.0 * u)
	var zone := Rect2(0.0, vis.y * (1.0 - STICK_ZONE_H), vis.x * STICK_ZONE_W, vis.y * STICK_ZONE_H)
	joystick.configure(r, rest, zone)

	# 右手: ダイブを右下隅に置き、ほかをその周りに扇形に並べる
	var main_r := LAYOUT_BTN_MAIN * 0.5 * u
	var dive_c := Vector2(right - main_r, bottom - main_r)
	var arc := LAYOUT_ARC * u
	var diag := LAYOUT_ARC_DIAG * u / sqrt(2.0)
	_place_button(dive_button, dive_c, LAYOUT_BTN_MAIN * u, u)
	_place_button(dash_button, dive_c + Vector2(-arc, 0.0), LAYOUT_BTN_SUB * u, u)
	_place_button(item_button, dive_c + Vector2(0.0, -arc), LAYOUT_BTN_SUB * u, u)
	var emote_c := dive_c + Vector2(-diag, -diag)
	_place_button(emote_button, emote_c, LAYOUT_BTN_SMALL * u, u)

	# カモン長押しの挑発3種: カモンの上に横一列。右端をカモンの右端にそろえて左へ伸ばす
	# (カモンの真上に中央ぞろえにすると、右上のアイテムボタンに重なって見づらかった)
	var submenu: Control = emote_button.get_node("TauntSubmenu")
	var t := LAYOUT_TAUNT * u
	var gap := 8.0 * u
	var total_w := t * 3.0 + gap * 2.0
	var sub_left := emote_c.x + LAYOUT_BTN_SMALL * 0.5 * u - total_w
	var sub_top := emote_c.y - LAYOUT_BTN_SMALL * 0.5 * u - 12.0 * u - t
	# TauntSubmenu は ActionEmote の子なので、ローカル座標に直す
	submenu.position = Vector2(sub_left, sub_top) - emote_button.position
	submenu.size = Vector2(total_w, t)
	for i in submenu.get_child_count():
		var circle: Control = submenu.get_child(i)
		circle.position = Vector2(i * (t + gap), 0.0)
		circle.size = Vector2(t, t)
		_round_panel(circle, t * 0.5)
		var label := circle.get_node_or_null("Label") as Label
		if label != null:
			label.add_theme_font_size_override("font_size", int(round(11.0 * u)))


func _place_top_left(c: Control, pos: Vector2, sz: Vector2) -> void:
	c.set_anchors_preset(Control.PRESET_TOP_LEFT)
	c.position = pos
	c.size = sz


func _place_button(b: Panel, center: Vector2, diameter: float, u: float) -> void:
	b.set_anchors_preset(Control.PRESET_TOP_LEFT)
	b.size = Vector2(diameter, diameter)
	b.position = center - b.size * 0.5
	b.hit_padding = LAYOUT_HIT_PAD * u
	b.apply_round(diameter * 0.5)
	var label := b.get_node_or_null("Label") as Label
	if label != null:
		label.add_theme_font_size_override("font_size", int(round(LAYOUT_FONT * u)))


## StyleBoxFlat の角丸は px 指定なので、大きさに合わせて真円を保つ
static func _round_panel(panel: Control, radius: float) -> void:
	var sb := panel.get_theme_stylebox("panel")
	if sb is StyleBoxFlat:
		var flat := (sb as StyleBoxFlat).duplicate() as StyleBoxFlat
		# 半径をちょうど幅の半分にすると、左右の角のアンチエイリアスが中央で重なり、
		# 半透明の塗りに縦線(2px 濃い帯)が出る(2026-09-30 の uishot で実測)。7% 小さくして避ける
		# (固定の 2 単位では、位置が画素の途中にかかるカモンで消えなかった)。
		# touch_action_button.gd / virtual_joystick.gd も同じ
		flat.set_corner_radius_all(int(floor(radius * 0.93)))
		panel.add_theme_stylebox_override("panel", flat)
