class_name Player
extends CharacterBody3D

## プレイヤーキャラクター。
## 自分が権威を持つインスタンスのみ入力・物理を処理し、
## 位置と回転は MultiplayerSynchronizer が他ピアへ配信する。

## トースト表示用の出来事 ID（hud.gd と共有）
enum Effect { BOOST, WARP, STUN }

## 持ち物アイテム（question_block.gd / hud.gd と共有）。1個だけ持てる
enum Item { NONE, ROCKET, BANANA, BLOCK }

signal effect_gained(effect: int)
signal item_changed(held: int)

const BASE_SPEED := 7.0       # 160m四方のマップで「歩きゲー」にしないための下限
const DASH_MULT := 1.5        # ダッシュ時 10.5 m/s
const JUMP_VELOCITY := 5.2    # 約1.38m。1.2m級の段差を越えられる高さ
const AIR_ACCEL := 14.0       # 空中での方向転換の効き（慣性を残すため小さめ）
const MOUSE_SENSITIVITY := 0.003
const PITCH_MIN := -60.0
const PITCH_MAX := 30.0

const STAMINA_MAX := 100.0
const STAMINA_DRAIN := 20.0   # ダッシュ中の消費 /秒（連続5秒ダッシュできる）
const STAMINA_REGEN := 18.0   # 非ダッシュ時の回復 /秒（ダッシュ稼働率 約47%）
const STAMINA_RECOVER := 30.0 # 枯渇後、この値まで回復するとダッシュ再可

## ロケット: 前方へ大きく飛ぶ。ジャンプ(1.38m)では届かない距離を一気に詰める/離す
const ROCKET_FORWARD := 12.0
const ROCKET_UP := 9.0
const BANANA_BEHIND := 2.0    # 足元の後ろこの距離に置く
const BLOCK_AHEAD := 3.5      # 目の前この距離に立てる

const COLOR_WAITING := Color(0.62, 0.66, 0.72)
const COLOR_RUNNER := Color(0.2, 1.0, 0.45)
const COLOR_HUNTER := Color(1.0, 0.18, 0.22)

var stamina := STAMINA_MAX
var exhausted := false
var is_dashing := false
var buffs := BuffSet.new()
var carry_velocity := Vector3.ZERO  # 動く床から毎フレーム渡される搬送速度
var warp_lock := 0.0                # 土管の往復ワープ防止
var item: int = Item.NONE
var stun_left := 0.0                # バナナを踏んだ時の操作不能時間

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
	$TagArea.body_entered.connect(_on_tag_area_body_entered)
	if is_multiplayer_authority():
		camera.current = true
		spring_arm.add_excluded_object(get_rid())


## 接触判定はホストが一元的に行う（全ピアで発火するので必ずサーバ判定を挟む）
func _on_tag_area_body_entered(body: Node3D) -> void:
	if multiplayer.is_server():
		GameManager.report_touch(self, body)


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

	buffs.tick(delta)
	warp_lock = maxf(warp_lock - delta, 0.0)
	stun_left = maxf(stun_left - delta, 0.0)

	var my_id := String(name).to_int()
	# 結果表示中・ヘッドスタート中の鬼・バナナで転倒中は移動不可（カメラ操作は可能）
	var frozen := GameManager.state == GameManager.State.RESULT or stun_left > 0.0
	if (GameManager.state == GameManager.State.PLAYING
			and my_id != GameManager.runner_id
			and GameManager.head_start_left > 0.0):
		frozen = true
	if not frozen and Input.is_action_just_pressed("use_item"):
		_use_item()

	if not is_on_floor():
		velocity += get_gravity() * delta
	elif Input.is_action_just_pressed("jump") and not frozen:
		velocity.y = JUMP_VELOCITY * buffs.get_mult(&"jump")

	var input_dir := Vector2.ZERO
	if not frozen:
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()

	_update_stamina(delta, direction != Vector3.ZERO, frozen)

	var speed := BASE_SPEED * GameManager.get_speed_mult(my_id) * buffs.get_mult(&"speed")
	if is_dashing:
		speed *= DASH_MULT

	# 接地中は即座に目標速度へ。空中では慣性を保ったまま弱く操作する。
	# ジャンプ台やブーストで得た初速が次フレームで消えないようにするため、
	# 空中で入力が無い場合は水平速度に一切手を加えない。
	var target := Vector2(direction.x, direction.z) * speed
	if is_on_floor():
		velocity.x = target.x
		velocity.z = target.y
	elif direction != Vector3.ZERO:
		velocity.x = move_toward(velocity.x, target.x, AIR_ACCEL * delta)
		velocity.z = move_toward(velocity.z, target.y, AIR_ACCEL * delta)

	velocity += carry_velocity
	move_and_slide()
	velocity -= carry_velocity
	carry_velocity = Vector3.ZERO

	if global_position.y < WorldData.FALL_LIMIT:
		teleport(WorldData.zone_center(WorldData.zone_index(global_position)) + Vector3(0, 3, 0))


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
	buffs.clear()
	warp_lock = 0.0
	stun_left = 0.0
	item = Item.NONE
	item_changed.emit(item)


## --- 持ち物アイテム -----------------------------------------------------

## ？ブロックから受け取る。1個だけ持てるので、新しく取ると上書きされる
func give_item(id: int) -> void:
	if not is_multiplayer_authority():
		return
	item = id
	item_changed.emit(item)


func _use_item() -> void:
	match item:
		Item.ROCKET:
			var fwd := -global_transform.basis.z
			launch(Vector3(fwd.x, 0.0, fwd.z).normalized() * ROCKET_FORWARD
				+ Vector3(0, ROCKET_UP, 0))
		Item.BANANA:
			var back := global_transform.basis.z
			_request_drop(Item.BANANA,
				global_position + Vector3(back.x, 0.0, back.z).normalized() * BANANA_BEHIND)
		Item.BLOCK:
			var ahead := -global_transform.basis.z
			_request_drop(Item.BLOCK,
				global_position + Vector3(ahead.x, 0.0, ahead.z).normalized() * BLOCK_AHEAD)
		_:
			return
	item = Item.NONE
	item_changed.emit(item)


## 置き物の生成はサーバに一任する。クライアントが自前で生成しても
## MultiplayerSpawner を通らず他ピアへ同期されないため。
## 自分がサーバなら rpc_id(1) のセルフ配信に頼らず直接呼ぶ
func _request_drop(kind: int, pos: Vector3) -> void:
	if multiplayer.is_server():
		GameManager.request_drop(kind, pos, rotation.y)
	else:
		GameManager.request_drop.rpc_id(1, kind, pos, rotation.y)


## --- ギミックから呼ばれる API ------------------------------------------
## いずれも「そのボディの権威ピア」でのみ適用する。
## 移動結果は既存の位置レプリケーションで他ピアへ伝わるため RPC は不要。

## ジャンプ台などの打ち上げ。y は上書き、水平は加算
func launch(v: Vector3) -> void:
	if not is_multiplayer_authority():
		return
	if v.y != 0.0:
		velocity.y = v.y
	velocity.x += v.x
	velocity.z += v.z


## 土管ワープ。着地先の土管で即座に再ワープしないよう warp_lock を張る
func warp_to(pos: Vector3, up_vel: float) -> void:
	if not is_multiplayer_authority():
		return
	global_position = pos
	_last_pos = pos
	velocity = Vector3(0, up_vel, 0)
	warp_lock = 0.9
	effect_gained.emit(Effect.WARP)


func apply_boost(mult: float, dur: float, kick: Vector3) -> void:
	if not is_multiplayer_authority():
		return
	buffs.add(&"speed", mult, dur)
	velocity.x += kick.x
	velocity.z += kick.z
	effect_gained.emit(Effect.BOOST)


## 動く床・回転床が毎フレーム乗客に渡す搬送速度
func add_carry(v: Vector3) -> void:
	carry_velocity += v


## バナナを踏んだ時の転倒
func apply_stun(seconds: float) -> void:
	if not is_multiplayer_authority():
		return
	stun_left = maxf(stun_left, seconds)
	velocity.x = 0.0
	velocity.z = 0.0
	effect_gained.emit(Effect.STUN)


## 役割に応じた体色の反映（全ピアで実行）
func _update_role_visuals() -> void:
	var my_id := String(name).to_int()
	var color := COLOR_WAITING
	if GameManager.state != GameManager.State.WAITING:
		color = COLOR_RUNNER if my_id == GameManager.runner_id else COLOR_HUNTER
	if color != _current_color:
		_current_color = color
		humanoid.set_color(color)
