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
## カメラが +Z を向くため、ワールドの +X が画面の左になる(プレイヤー x=+0.7 が左、店員さん x=-1.5 が右)
const CAMERA_POS := Vector3(-0.35, 1.6, -5.9)
const CAMERA_LOOK_AT := Vector3(-0.35, 1.1, 0.4)

## 奥の壁の絵。assets 側に置かれていれば貼る(tools/blender/references は .gdignore で
## Godot から見えないので、使う絵はここへコピーする)
const BACKDROP_PATH := "res://assets/shop/shop_backdrop.png"

const DRAG_SENSITIVITY := 0.01
const PLAYER_FACING := deg_to_rad(15.0)   # 少し店員さん側(画面の右)へ向けて立たせる

## 店員さんのリアクションの長さ。エモートはループ再生なので時間で止める
const REACTION_SECONDS := 2.4
const EMOTE_NICE := 1
const EMOTE_COME := 2

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


func _ready() -> void:
	_camera.look_at_from_position(CAMERA_POS, CAMERA_LOOK_AT, Vector3.UP)
	_container.gui_input.connect(_on_gui_input)
	_apply_backdrop()
	_spawn_shopkeeper()
	_stock_hat_shelf()
	reset_view()


## 表示中だけアニメを進める(非表示のオーバーレイで回し続けない)
func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_player.update_motion(0.0, true, delta)
	_shopkeeper.update_motion(0.0, true, delta)
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


## 店員さんが喜ぶ(試着・購入のとき)
func cheer() -> void:
	_react(EMOTE_NICE)


## 店員さんが手招きする(入店のとき)
func beckon() -> void:
	_react(EMOTE_COME)


func reset_view() -> void:
	_turntable.rotation.y = PLAYER_FACING
	_dragging = false


func _react(emote: int) -> void:
	_shopkeeper.set_emote(emote)
	_reaction_left = REACTION_SECONDS


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
