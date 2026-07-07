extends CharacterBody3D

## ソロモード用の CPU 鬼。ロジックはホスト（サーバ）でのみ動作し、
## 位置・回転は MultiplayerSynchronizer で途中参加者にも配信される。
## 経路探索は NavigationAgent3D（world 側で焼いたナビメッシュ）を使う。

const SPEED := 6.5
const REPATH_INTERVAL := 0.3
const TURN_SPEED := 8.0
const HUNTER_COLOR := Color(0.85, 0.2, 0.15)

var _repath_timer := 0.0

@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var humanoid: Node3D = $Humanoid


func _ready() -> void:
	add_to_group("cpu_hunters")
	humanoid.set_color(HUNTER_COLOR)


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	if not is_on_floor():
		velocity += get_gravity() * delta

	var dir := Vector3.ZERO
	if GameManager.state == GameManager.State.PLAYING:
		var runner: Node3D = GameManager.get_runner()
		if runner:
			_repath_timer -= delta
			if _repath_timer <= 0.0:
				_repath_timer = REPATH_INTERVAL
				agent.target_position = runner.global_position
			var next := agent.get_next_path_position()
			dir = next - global_position
			dir.y = 0.0
			dir = dir.normalized() if dir.length() > 0.05 else Vector3.ZERO

	if dir != Vector3.ZERO:
		velocity.x = dir.x * SPEED
		velocity.z = dir.z * SPEED
		rotation.y = lerp_angle(rotation.y, atan2(-dir.x, -dir.z), TURN_SPEED * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)
		velocity.z = move_toward(velocity.z, 0.0, SPEED)

	move_and_slide()
