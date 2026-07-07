extends CharacterBody3D

## ソロモード用の CPU 鬼。ロジックはホスト（サーバ）でのみ動作し、
## 位置・回転は MultiplayerSynchronizer で途中参加者にも配信される。
## 基本はナビメッシュ経路で追跡し、近距離やナビ経路が届かない場所
## （ジャンプ必須の段差上など）では直接追跡＋ジャンプで登って捕まえる。

const SPEED := 6.5
const JUMP_VELOCITY := 4.5
const REPATH_INTERVAL := 0.3
const TURN_SPEED := 8.0
const JUMP_COOLDOWN := 0.7
const DIRECT_CHASE_DIST := 10.0
const HUNTER_COLOR := Color(0.85, 0.2, 0.15)

var _repath_timer := 0.0
var _jump_cooldown := 0.0
var _last_pos := Vector3.ZERO

@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var humanoid: Node3D = $Humanoid


func _ready() -> void:
	add_to_group("cpu_hunters")
	humanoid.set_color(HUNTER_COLOR)
	_last_pos = global_position


func _process(delta: float) -> void:
	# 歩行モーションは全ピアで位置差分から駆動する
	if delta <= 0.0:
		return
	var vel_est := (global_position - _last_pos) / delta
	_last_pos = global_position
	var hspeed := Vector2(vel_est.x, vel_est.z).length()
	humanoid.update_motion(hspeed, absf(vel_est.y) < 1.5)


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	if not is_on_floor():
		velocity += get_gravity() * delta
	_jump_cooldown = maxf(_jump_cooldown - delta, 0.0)

	var chasing := (GameManager.state == GameManager.State.PLAYING
		and GameManager.head_start_left <= 0.0)
	var dir := Vector3.ZERO
	var rise := 0.0
	if chasing:
		var runner: Node3D = GameManager.get_runner()
		if runner:
			_repath_timer -= delta
			if _repath_timer <= 0.0:
				_repath_timer = REPATH_INTERVAL
				agent.target_position = runner.global_position
			var next := agent.get_next_path_position()
			var to_runner := runner.global_position - global_position
			var h_dist := Vector2(to_runner.x, to_runner.z).length()
			# 近距離で高低差が小さい、またはナビで到達不能なら直接追跡に切り替える
			if h_dist < DIRECT_CHASE_DIST and (absf(to_runner.y) < 1.2 or not agent.is_target_reachable()):
				next = runner.global_position
			dir = next - global_position
			rise = dir.y
			dir.y = 0.0
			dir = dir.normalized() if dir.length() > 0.05 else Vector3.ZERO
			# 壁に当たった/目標が高い場合はジャンプ（スロープや1m段差を跳んで登る）
			if is_on_floor() and _jump_cooldown <= 0.0 and (is_on_wall() or rise > 0.4):
				velocity.y = JUMP_VELOCITY
				_jump_cooldown = JUMP_COOLDOWN

	if dir != Vector3.ZERO:
		velocity.x = dir.x * SPEED
		velocity.z = dir.z * SPEED
		rotation.y = lerp_angle(rotation.y, atan2(-dir.x, -dir.z), TURN_SPEED * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)
		velocity.z = move_toward(velocity.z, 0.0, SPEED)

	move_and_slide()
