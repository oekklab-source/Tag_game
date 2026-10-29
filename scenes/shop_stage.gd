extends Control

## ショップの3D舞台。お店の中で、台の上に立った自分のキャラに試着させ、
## カウンターの奥の店員さんが反応する。
##
## costume_preview(きせかえ画面のターンテーブル)と役割は近いが、こちらは
## 「店の空間に2人を置く」ため1つの SubViewport に舞台・自分・店員さんを全部入れる。
## costume_preview を2つ並べると世界が別々になり、床も光も共有できないので分けてある。
##
## 店員さんの専用モデルと奥の壁の絵は Gemini で起こした設定画から作る予定
## (tools/blender/references/SHOP_ART_PROMPTS.md)。届くまでは、店員さんは既存の
## きょうりゅうにモノトーン柄＋ネコミミビーニーを着せた仮の姿、奥の壁は単色で動く。

## キャラの正面は -Z なので、カメラは -Z 側の少し高い位置から2人の間を見る。
## カメラが +Z を向くため、ワールドの +X が画面の左になる(プレイヤー x=+0.9 が左、店員さん x=-1.5 が右)
const CAMERA_POS := Vector3(-0.28, 1.6, -6.4)
const CAMERA_LOOK_AT := Vector3(-0.28, 1.1, 0.4)

## 奥の壁の絵。assets 側に置かれていれば貼る(tools/blender/references は .gdignore で
## Godot から見えないので、使う絵はここへコピーする)
const BACKDROP_PATH := "res://assets/shop/shop_backdrop.png"

const DRAG_SENSITIVITY := 0.01
const PLAYER_FACING := deg_to_rad(15.0)   # 少し店員さん側(画面の右)へ向けて立たせる

## 店員さんのリアクションの長さ。エモートはループ再生なので時間で止める
const REACTION_SECONDS := 2.4
const EMOTE_NICE := 1
const EMOTE_COME := 2

## --- 店員さんの動き ---
## 普段はカウンターの奥(HOME)で画面の前のお客さん(=カメラ)の方を向き、ときどき
## 試着台のアバターをちらっと見る。試着されたらカウンターの端(ASSIST)まで出てきて
## アバターを見てから反応し、しばらく試着が無ければカウンターの奥へ戻る。
## 向きは「見る相手」へ毎フレーム exp 減衰で寄せる(パッと振り向かず、首を回すように)
const CLERK_HOME := Vector3(-1.5, 0.0, 0.65)
const CLERK_ASSIST := Vector3(-0.5, 0.0, 0.5)
## 歩く速さ(m/s)。Humanoid.update_motion に実際の速さを渡すので、歩幅はアニメ側が合わせる
const CLERK_WALK_SPEED := 1.8
const CLERK_TURN_RATE := 6.0
## 最後に試着されてから、カウンターへ戻るまでの秒数
const ASSIST_LINGER := 7.0
## 試着されたとき、アバターを見続ける秒数と、着いてから喜ぶまでの間(見てから反応する)
const ADMIRE_WATCH := 2.2
const ADMIRE_DELAY := 0.3
## 待機中のちら見: 間隔の幅(秒)と見る長さ
const GLANCE_INTERVAL := Vector2(3.0, 6.0)
const GLANCE_LENGTH := 1.3
## 見る相手の頭の高さ。カメラは「お客さんの目」
const AVATAR_HEAD_Y := 1.4
const CLERK_HEAD_Y := 2.0
const ARRIVE_EPS := 0.02

## 仮の店員さんの見た目(専用モデルが届くまで)
const STAND_IN_COSTUME: StringName = &"mono"
const STAND_IN_COLORS := [Color(1.0, 0.85, 0.88)]
const STAND_IN_HAT: StringName = &"cat_ears"

## 陳列棚に並べる帽子の間隔(m)と大きさ。帽子は頭に合わせた実寸なので、
## 奥の棚に実寸で並べると手前のキャラより目立つ。小さめにして飾りに留める
const SHELF_SPACING := 0.55
const SHELF_HAT_SCALE := 0.7
const SHELF_COLOR := Color(1.0, 0.97, 0.9)

@onready var _container: SubViewportContainer = $SubViewportContainer
@onready var _camera: Camera3D = $SubViewportContainer/SubViewport/Camera3D
@onready var _turntable: Node3D = $SubViewportContainer/SubViewport/PlayerTurntable
@onready var _player: Node3D = $SubViewportContainer/SubViewport/PlayerTurntable/Player
@onready var _shopkeeper_root: Node3D = $SubViewportContainer/SubViewport/Shopkeeper
@onready var _backdrop: MeshInstance3D = $SubViewportContainer/SubViewport/Set/Backdrop
@onready var _hat_shelf: Node3D = $SubViewportContainer/SubViewport/Set/HatShelf
@onready var _lock_badge: Label = $LockBadge

var _shopkeeper: Node3D
var _dragging := false
var _reaction_left := 0.0

var _clerk_goal := CLERK_HOME
var _assist_left := 0.0      # >0: 接客位置に留まる残り秒
var _watch_left := 0.0       # >0: アバターを見続ける残り秒(試着直後)
var _glance_left := 0.0      # >0: ちら見の残り秒
var _next_glance := 0.0
var _pending_emote := 0      # 歩いている間に頼まれた反応は、着いてから出す
var _pending_delay := 0.0
var _clerk_speed := 0.0      # 直前フレームの歩く速さ(テストと向きの判定用)
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_camera.look_at_from_position(CAMERA_POS, CAMERA_LOOK_AT, Vector3.UP)
	_container.gui_input.connect(_on_gui_input)
	_apply_backdrop()
	_spawn_shopkeeper()
	_stock_hat_shelf()
	reset_view()
	_next_glance = _rng.randf_range(GLANCE_INTERVAL.x, GLANCE_INTERVAL.y)


## 表示中だけアニメを進める(非表示のオーバーレイで回し続けない)
func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	tick(delta)


## 1フレーム分進める。テストが固定の刻みで直接呼べるよう _process から分けてある
func tick(delta: float) -> void:
	_player.update_motion(0.0, true, delta)
	_tick_clerk(delta)
	if _reaction_left > 0.0:
		_reaction_left -= delta
		if _reaction_left <= 0.0:
			_shopkeeper.set_emote(0)


## 試着の見た目を反映する。set_skin はモデルごと差し替えて直前のコスチュームを
## 付け直すので、必ずコスチューム・帽子より先に呼ぶ
func show_outfit(skin: int, costume_id: StringName, colors: PackedColorArray, hat_id: StringName) -> void:
	_player.set_skin(skin)
	_player.apply_costume(costume_id, colors)
	_player.apply_hat(hat_id)


## 未所持のものを試着中であることのバッジ
func set_locked(locked: bool) -> void:
	_lock_badge.visible = locked


## 試着されたとき。接客位置まで出てきてアバターを見て、新しい物なら喜ぶ
## (もう持っている物は見るだけ)
func admire(excited: bool) -> void:
	_clerk_goal = CLERK_ASSIST
	_assist_left = ASSIST_LINGER
	_watch_left = ADMIRE_WATCH
	_glance_left = 0.0
	if excited:
		_pending_emote = EMOTE_NICE
		_pending_delay = ADMIRE_DELAY


## お客さんの方を向いて喜ぶ(購入・着替え・プレゼントのとき)
func cheer() -> void:
	_watch_left = 0.0
	_glance_left = 0.0
	_assist_left = maxf(_assist_left, ASSIST_LINGER * 0.5)
	_pending_emote = EMOTE_NICE
	_pending_delay = 0.0


## 店員さんが手招きする(入店のとき)
func beckon() -> void:
	_react(EMOTE_COME)


## 店員さんの頭の上の位置(このコントロールのローカル座標)。吹き出しを店員さんに付いて行かせる
func clerk_head_position() -> Vector2:
	var head := _shopkeeper_root.global_position + Vector3.UP * CLERK_HEAD_Y
	var vp: Vector2 = _camera.unproject_position(head)
	return vp * (size / Vector2(_camera.get_viewport().size))


func reset_view() -> void:
	_turntable.rotation.y = PLAYER_FACING
	_dragging = false


func _react(emote: int) -> void:
	_shopkeeper.set_emote(emote)
	_reaction_left = REACTION_SECONDS


func _tick_clerk(delta: float) -> void:
	var pos := _shopkeeper_root.position
	var to := _clerk_goal - pos
	to.y = 0.0
	var dist := to.length()
	_clerk_speed = 0.0
	if dist > ARRIVE_EPS and delta > 0.0:
		var step := minf(dist, CLERK_WALK_SPEED * delta)
		_shopkeeper_root.position += to / dist * step
		_clerk_speed = step / delta
	var arrived := dist <= ARRIVE_EPS

	if _assist_left > 0.0:
		_assist_left -= delta
		if _assist_left <= 0.0:
			_clerk_goal = CLERK_HOME
	if _watch_left > 0.0:
		_watch_left -= delta
	# 歩いている間・見つめている間は、ちら見しない
	if arrived and _watch_left <= 0.0:
		if _glance_left > 0.0:
			_glance_left -= delta
		else:
			_next_glance -= delta
			if _next_glance <= 0.0:
				_glance_left = GLANCE_LENGTH
				_next_glance = _rng.randf_range(GLANCE_INTERVAL.x, GLANCE_INTERVAL.y)
	# エモートは止まっていないと再生されない(Humanoid.update_motion)ので、着いてから出す
	if _pending_emote != 0 and arrived:
		_pending_delay -= delta
		if _pending_delay <= 0.0:
			_react(_pending_emote)
			_pending_emote = 0

	var yaw := _shopkeeper_root.rotation.y
	var want := _yaw_towards(pos, _clerk_look_point(to))
	_shopkeeper_root.rotation.y = lerp_angle(yaw, want, 1.0 - exp(-CLERK_TURN_RATE * delta))
	_shopkeeper.update_motion(_clerk_speed, true, delta)


## 今どこを見るか。歩いている間は進む方向、試着直後・ちら見中・アバターを回している間は
## アバター、それ以外はお客さん(カメラ)
func _clerk_look_point(walk_dir: Vector3) -> Vector3:
	var pos := _shopkeeper_root.position
	if _clerk_speed > 0.0:
		return pos + walk_dir
	if _watch_left > 0.0 or _glance_left > 0.0 or _dragging:
		return _turntable.position + Vector3.UP * AVATAR_HEAD_Y
	return _camera.position


## キャラの正面は -Z(Humanoid の約束)なので、正面を point へ向ける Y 回転
static func _yaw_towards(from: Vector3, point: Vector3) -> float:
	var d := point - from
	return atan2(-d.x, -d.z)


## 店員さんの今の正面と point の方向とのずれ(ラジアン)。テスト用
func clerk_facing_error(point: Vector3) -> float:
	var want := _yaw_towards(_shopkeeper_root.position, point)
	return absf(angle_difference(_shopkeeper_root.rotation.y, want))


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
	elif event is InputEventMouseMotion and _dragging:
		_turntable.rotation.y += event.relative.x * DRAG_SENSITIVITY


func _apply_backdrop() -> void:
	if not ResourceLoader.exists(BACKDROP_PATH):
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load(BACKDROP_PATH)
	# 絵の明るさをそのまま見せる(ライトで暗くなると設定画と色が変わる)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_backdrop.material_override = mat


func _spawn_shopkeeper() -> void:
	_shopkeeper = (load("res://scenes/humanoid.tscn") as PackedScene).instantiate()
	_shopkeeper.name = "Clerk"
	_shopkeeper_root.add_child(_shopkeeper)
	_shopkeeper.apply_costume(STAND_IN_COSTUME, PackedColorArray(STAND_IN_COLORS))
	_shopkeeper.apply_hat(STAND_IN_HAT)
	_shopkeeper_root.position = CLERK_HOME
	_shopkeeper_root.rotation.y = _yaw_towards(CLERK_HOME, _camera.position)


## 棚に売り物の帽子を飾る(お店らしさと、帽子の形を一目で見せるため)
func _stock_hat_shelf() -> void:
	var hats: Array[PackedScene] = []
	for id in HatCatalog.HATS:
		var packed: PackedScene = HatCatalog.get_def(id).get("scene")
		if packed != null:
			hats.append(packed)
	var width := SHELF_SPACING * hats.size()
	# 棚板。HatShelf の原点を棚の中央にして、帽子を左右対称に並べる
	var board := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(width + 0.2, 0.06, 0.4)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = SHELF_COLOR
	mesh.material = mat
	board.mesh = mesh
	board.position = Vector3(0.0, -0.03, 0.0)
	_hat_shelf.add_child(board)
	for i in hats.size():
		var hat: Node3D = hats[i].instantiate()
		hat.position = Vector3(width * 0.5 - SHELF_SPACING * (i + 0.5), 0.0, 0.0)
		hat.scale = Vector3.ONE * SHELF_HAT_SCALE
		hat.rotation_degrees = Vector3(0, 180, 0)
		_hat_shelf.add_child(hat)
