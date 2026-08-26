extends Control

## Fall Guys/荒野行動風の「見た目を見ながら選ぶ」3Dプレビューウィジェット。
## costume_screen から使う。ショップ画面（購入前試着）でも再利用する想定なので
## 単一責務のコンポーネントとして独立させてある。

const AUTO_SPIN_SPEED := 0.35      # rad/秒
const DRAG_SENSITIVITY := 0.01
const IDLE_RESUME_DELAY := 1.5     # ドラッグ終了後、自動回転を再開するまでの秒数

## tools/shot_humanoid.gd と同じ値。キャラの正面は -Z なので斜め前から見下ろす
const CAMERA_POS := Vector3(1.8, 1.5, -2.6)
const CAMERA_LOOK_AT := Vector3(0.0, 0.85, 0.0)

@onready var _viewport_container: SubViewportContainer = $SubViewportContainer
@onready var _camera: Camera3D = $SubViewportContainer/SubViewport/Camera3D
@onready var _turntable: Node3D = $SubViewportContainer/SubViewport/Turntable
@onready var _humanoid: Node3D = $SubViewportContainer/SubViewport/Turntable/Humanoid
@onready var _lock_badge: Label = $LockBadge

var _dragging := false
var _time_since_drag := 0.0


func _ready() -> void:
	_camera.position = CAMERA_POS
	_camera.look_at_from_position(CAMERA_POS, CAMERA_LOOK_AT, Vector3.UP)
	_viewport_container.gui_input.connect(_on_gui_input)
	reset_view()


## ダイアログが非表示の間は回転計算もレンダリングも止め、README のドローコール
## 意識(グロー/シャドウを先に切る、常時レンダリングを避ける)に沿って負荷を抑える
func _process(delta: float) -> void:
	if not is_visible_in_tree() or _dragging:
		return
	_time_since_drag += delta
	if _time_since_drag > IDLE_RESUME_DELAY:
		_turntable.rotation.y += AUTO_SPIN_SPEED * delta


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		_time_since_drag = 0.0
	elif event is InputEventMouseMotion and _dragging:
		_turntable.rotation.y += event.relative.x * DRAG_SENSITIVITY
		_time_since_drag = 0.0


## コスチュームを即座に反映する（未所持IDでも可＝試着用途）
func show_costume(id: StringName, colors: PackedColorArray) -> void:
	_humanoid.apply_costume(id, colors)


## ⑤帽子を即座に反映する（未所持IDでも可＝試着用途）
func show_hat(id: StringName) -> void:
	_humanoid.apply_hat(id)


## 未所持アイテムを試着中であることのバッジ表示切替
func set_locked(locked: bool) -> void:
	_lock_badge.visible = locked


## ダイアログを開き直すたびに見やすい角度・回転状態にリセットする
func reset_view() -> void:
	_turntable.rotation.y = deg_to_rad(20.0)
	_dragging = false
	_time_since_drag = 0.0
