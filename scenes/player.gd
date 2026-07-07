extends CharacterBody3D

## プレイヤーキャラクター。
## 自分が権威を持つインスタンスのみ入力・物理を処理し、
## 位置と回転は MultiplayerSynchronizer が他ピアへ配信する。

const BASE_SPEED := 6.0
const DASH_MULT := 1.5
const JUMP_VELOCITY := 4.5
const MOUSE_SENSITIVITY := 0.003
const PITCH_MIN := -60.0
const PITCH_MAX := 30.0

const STAMINA_MAX := 100.0
const STAMINA_DRAIN := 25.0   # ダッシュ中の消費 /秒
const STAMINA_REGEN := 15.0   # 非ダッシュ時の回復 /秒
const STAMINA_RECOVER := 30.0 # 枯渇後、この値まで回復するとダッシュ再可

const COLOR_WAITING := Color(0.5, 0.55, 0.6)
const COLOR_RUNNER := Color(0.2, 0.8, 0.35)
const COLOR_HUNTER := Color(0.85, 0.2, 0.15)

var stamina := STAMINA_MAX
var exhausted := false
var is_dashing := false

var _current_color := Color.TRANSPARENT
var _last_pos := Vector3.ZERO

@onready var spring_arm: SpringArm3D = $SpringArm3D
@onready var camera: Camera3D = $SpringArm3D/Camera3D
@onready var humanoid: Node3D = $Humanoid


func _enter_tree() -> void:
	# ノード名 = peer_id。生成時（ホスト側/レプリケート側とも）に権威を設定する
	set_multiplayer_authority(String(name).to_int())


func _ready() -> void:
	add_to_group("players")
	_last_pos = global_position
	if is_multiplayer_authority():
		camera.current = true
		spring_arm.add_excluded_object(get_rid())


func _process(delta: float) -> void:
	# 歩行モーション: リモートでは velocity が同期されないため位置差分から推定する
	if delta <= 0.0:
		return
	var vel_est := (global_position - _last_pos) / delta
	_last_pos = global_position
	var hspeed := Vector2(vel_est.x, vel_est.z).length()
	humanoid.update_motion(hspeed, absf(vel_est.y) < 1.5)


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if event is InputEventMouseButton and event.pressed:
		# ブラウザのポインタロックはユーザー操作起点が必須のため、クリックで取得する
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		spring_arm.rotation.x = clampf(
			spring_arm.rotation.x - event.relative.y * MOUSE_SENSITIVITY,
			deg_to_rad(PITCH_MIN), deg_to_rad(PITCH_MAX))


func _physics_process(delta: float) -> void:
	_update_role_visuals()
	if not is_multiplayer_authority():
		return

	var my_id := String(name).to_int()
	# 結果表示中と、ヘッドスタート中の鬼は移動不可（カメラ操作は可能）
	var frozen := GameManager.state == GameManager.State.RESULT
	if (GameManager.state == GameManager.State.PLAYING
			and my_id != GameManager.runner_id
			and GameManager.head_start_left > 0.0):
		frozen = true

	if not is_on_floor():
		velocity += get_gravity() * delta
	elif Input.is_action_just_pressed("jump") and not frozen:
		velocity.y = JUMP_VELOCITY

	var input_dir := Vector2.ZERO
	if not frozen:
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()

	_update_stamina(delta, direction != Vector3.ZERO, frozen)

	var speed := BASE_SPEED * GameManager.get_speed_mult(my_id)
	if is_dashing:
		speed *= DASH_MULT

	if direction != Vector3.ZERO:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, BASE_SPEED)
		velocity.z = move_toward(velocity.z, 0.0, BASE_SPEED)

	move_and_slide()


func _update_stamina(delta: float, moving: bool, frozen: bool) -> void:
	var wants_dash := Input.is_action_pressed("dash") and moving and not frozen
	is_dashing = wants_dash and not exhausted and stamina > 0.0
	if is_dashing:
		stamina = maxf(stamina - STAMINA_DRAIN * delta, 0.0)
		if stamina <= 0.0:
			exhausted = true
			is_dashing = false
	else:
		stamina = minf(stamina + STAMINA_REGEN * delta, STAMINA_MAX)
		if exhausted and stamina >= STAMINA_RECOVER:
			exhausted = false


## ラウンド開始時に GameManager（RPC 内）から呼ばれる。権威ピア上でのみ有効。
func teleport(pos: Vector3) -> void:
	if not is_multiplayer_authority():
		return
	global_position = pos
	_last_pos = pos
	velocity = Vector3.ZERO
	stamina = STAMINA_MAX
	exhausted = false


## 役割に応じた体色の反映（全ピアで実行）
func _update_role_visuals() -> void:
	var my_id := String(name).to_int()
	var color := COLOR_WAITING
	if GameManager.state != GameManager.State.WAITING:
		color = COLOR_RUNNER if my_id == GameManager.runner_id else COLOR_HUNTER
	if color != _current_color:
		_current_color = color
		humanoid.set_color(color)
