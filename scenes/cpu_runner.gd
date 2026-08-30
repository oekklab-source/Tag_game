extends CharacterBody3D

const CPU_NAV_ASSIST := preload("res://scenes/cpu_nav_assist.gd")
const STUCK_ESCAPE := preload("res://scenes/stuck_escape.gd")

## デバッグ用の CPU 逃走者。
## ホスト上だけでAIを動かし、9エリアを順番に巡回する。
## プレイヤー側は鬼としてこのCPUを追いかけ、通常のタッチ判定で捕まえる。

const SPEED := Player.BASE_SPEED
const RUN_ORDER: Array[int] = [4, 3, 0, 1, 2, 5, 8, 7, 6]
const ARRIVE_DIST := 10.0
const GOAL_TIMEOUT := 18.0
const SIDESTEP_TIME := 1.0
const SIDESTEP_DIST := 5.0
const AIR_STEER := 6.0
const REPATH_INTERVAL := 0.3
const TURN_SPEED := 8.0
const RUNNER_COLOR := Player.COLOR_RUNNER
const GROUND_DRAG := Player.GROUND_DRAG
const STEER_WHILE_FAST := Player.STEER_WHILE_FAST
const SLIDE_STEER := Player.SLIDE_STEER
const SLIDE_MIN_SPEED := Player.SLIDE_MIN_SPEED
const SLIDE_SNAP := Player.SLIDE_SNAP
const SLIDE_GRACE := Player.SLIDE_GRACE
const WARP_GRACE := Player.WARP_GRACE
const NET_SMOOTH := Player.NET_SMOOTH
const NET_SNAP_DIST := Player.NET_SNAP_DIST

var buffs := BuffSet.new()
var carry_velocity := Vector3.ZERO
var bumper_bounce_velocity := Vector3.ZERO
var bumper_bounce_left := 0.0
var slide_dir := Vector3.ZERO
var slide_accel := 0.0
var slide_cap := 0.0
var slide_left := 0.0
var warp_lock := 0.0
var warp_grace := 0.0
var stun_left := 0.0
var diving := false

var _route_i := 0
var _route_dir := 1
var _goal := Vector3.ZERO
var _goal_timer := 0.0
var _repath_timer := 0.0
var _stuck_timer := 0.0
var _stuck_from := Vector3.ZERO
var _sidestep_left := 0.0
var _sidestep_goal := Vector3.ZERO
var _stuck_kick := Vector3.ZERO
var _stuck_kick_left := 0.0
var _rng := RandomNumberGenerator.new()

@export var sync_position := Vector3.ZERO
@export var sync_yaw := 0.0
@export var sync_speed := 0.0
@export var sync_air := false

@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var humanoid: Node3D = $Humanoid


func _ready() -> void:
	add_to_group("cpu_runners")
	humanoid.set_color(RUNNER_COLOR)
	if multiplayer.is_server():
		sync_position = position
		sync_yaw = rotation.y
		_goal = WorldData.zone_center(RUN_ORDER[_route_i])
		_goal_timer = GOAL_TIMEOUT
		_stuck_from = global_position
	else:
		position = sync_position
		rotation.y = sync_yaw
	$TagArea.body_entered.connect(_on_tag_area_body_entered)
	_rng.seed = hash(name)


func _on_tag_area_body_entered(body: Node3D) -> void:
	if multiplayer.is_server():
		GameManager.report_touch(self, body)


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	if not multiplayer.is_server():
		_follow_sync(delta)
	humanoid.set_diving(false)
	humanoid.update_motion(sync_speed, not sync_air, delta)
	humanoid.rotation.x = lerpf(humanoid.rotation.x, 0.0, minf(delta * 12.0, 1.0))


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	buffs.tick(delta)
	warp_lock = maxf(warp_lock - delta, 0.0)
	stun_left = maxf(stun_left - delta, 0.0)
	var holding_bumper_bounce := bumper_bounce_left > 0.0
	bumper_bounce_left = maxf(bumper_bounce_left - delta, 0.0)

	var grounded := is_on_floor() and not CharacterSeparation.on_character(self)
	if warp_grace > 0.0 or not grounded:
		velocity += get_gravity() * delta

	var active := (GameManager.state == GameManager.State.PLAYING and stun_left <= 0.0)
	var dir := Vector3.ZERO
	if active:
		_update_goal(delta)
		var assist := CPU_NAV_ASSIST.slide_assist(global_position, _goal)
		if assist["active"]:
			_stuck_timer = 0.0
			_stuck_from = global_position
			_sidestep_left = 0.0
			_stuck_kick_left = 0.0
		else:
			_avoid_stuck(delta)
		if _stuck_kick_left > 0.0:
			add_carry(_stuck_kick)
			_stuck_kick_left -= delta
		var nav_goal: Vector3 = _sidestep_goal if _sidestep_left > 0.0 else assist["target"]
		_repath_timer -= delta
		if _repath_timer <= 0.0:
			_repath_timer = REPATH_INTERVAL
			agent.target_position = nav_goal
		var next: Vector3 = nav_goal if assist["direct"] else agent.get_next_path_position()
		if not assist["direct"] and _xz_dist(global_position, next) < 0.2 \
				and _xz_dist(global_position, nav_goal) > 1.0:
			next = nav_goal
		dir = next - global_position
		dir.y = 0.0
		dir = dir.normalized() if dir.length() > 0.05 else Vector3.ZERO
		dir = CPU_NAV_ASSIST.avoid_bumpers(global_position, dir, get_tree())

	var speed := SPEED * buffs.get_mult(&"speed")
	var target := Vector2(dir.x, dir.z) * speed
	if holding_bumper_bounce:
		velocity.x = bumper_bounce_velocity.x
		velocity.z = bumper_bounce_velocity.z
	elif slide_left > 0.0:
		velocity = SlideMotion.step(velocity, delta, slide_dir, slide_accel, slide_cap,
			SLIDE_STEER, dir, SLIDE_MIN_SPEED)
		floor_snap_length = SLIDE_SNAP
		slide_left = maxf(slide_left - delta, 0.0)
		if slide_left <= 0.0:
			_repath_timer = 0.0
			_goal_timer = 0.0
	elif warp_grace > 0.0:
		warp_grace = maxf(warp_grace - delta, 0.0)
		if dir != Vector3.ZERO:
			velocity.x = move_toward(velocity.x, target.x, AIR_STEER * delta)
			velocity.z = move_toward(velocity.z, target.y, AIR_STEER * delta)
	elif grounded:
		floor_snap_length = 0.1
		var hv := Vector2(velocity.x, velocity.z)
		if hv.length() > speed + 0.5:
			var keep := hv.normalized() * maxf(hv.length() - GROUND_DRAG * delta, speed)
			if target != Vector2.ZERO:
				keep = keep.lerp(target.normalized() * keep.length(),
					minf(STEER_WHILE_FAST * delta, 1.0))
			velocity.x = keep.x
			velocity.z = keep.y
		else:
			velocity.x = target.x
			velocity.z = target.y
	elif dir != Vector3.ZERO:
		velocity.x = move_toward(velocity.x, target.x, AIR_STEER * delta)
		velocity.z = move_toward(velocity.z, target.y, AIR_STEER * delta)

	if dir != Vector3.ZERO:
		rotation.y = lerp_angle(rotation.y, atan2(-dir.x, -dir.z), TURN_SPEED * delta)

	var separate := CharacterSeparation.push(self)
	velocity += carry_velocity + separate
	move_and_slide()
	velocity -= carry_velocity + separate
	carry_velocity = Vector3.ZERO

	sync_speed = Vector2(velocity.x, velocity.z).length()
	sync_air = not grounded
	if global_position.y < WorldData.FALL_LIMIT:
		teleport(WorldData.zone_center(WorldData.zone_index(global_position)) + Vector3(0, 3, 0))
	sync_position = position
	sync_yaw = rotation.y


func _follow_sync(delta: float) -> void:
	if position.distance_squared_to(sync_position) > NET_SNAP_DIST * NET_SNAP_DIST:
		position = sync_position
		rotation.y = sync_yaw
		return
	var w := 1.0 - exp(-delta * NET_SMOOTH)
	position = position.lerp(sync_position, w)
	rotation.y = lerp_angle(rotation.y, sync_yaw, w)


func _update_goal(delta: float) -> void:
	_goal_timer -= delta
	if _xz_dist(global_position, _goal) < ARRIVE_DIST or _goal_timer <= 0.0:
		_advance_route()


func _advance_route() -> void:
	_route_i += _route_dir
	if _route_i >= RUN_ORDER.size():
		_route_i = RUN_ORDER.size() - 2
		_route_dir = -1
	elif _route_i < 0:
		_route_i = 1
		_route_dir = 1
	_goal = WorldData.zone_center(RUN_ORDER[_route_i])
	_goal_timer = GOAL_TIMEOUT
	_repath_timer = 0.0


func _avoid_stuck(delta: float) -> void:
	if _sidestep_left > 0.0:
		_sidestep_left -= delta
		return
	_stuck_timer += delta
	if _stuck_timer < STUCK_ESCAPE.STUCK_TIME:
		return
	var moved := _xz_dist(global_position, _stuck_from)
	_stuck_timer = 0.0
	_stuck_from = global_position
	if moved >= STUCK_ESCAPE.STUCK_DIST:
		return
	var kick := STUCK_ESCAPE.normal_kick(self, SPEED)
	if kick != Vector3.ZERO:
		_stuck_kick = kick
		_stuck_kick_left = STUCK_ESCAPE.KICK_TIME
		_repath_timer = 0.0
		return
	var to_goal := _goal - global_position
	var side := Vector3(-to_goal.z, 0.0, to_goal.x).normalized()
	if side.length_squared() < 0.01:
		side = Vector3.RIGHT
	if _rng.randf() < 0.5:
		side = -side
	_sidestep_goal = global_position + side * SIDESTEP_DIST
	_sidestep_left = SIDESTEP_TIME
	_repath_timer = 0.0


func _xz_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func get_ai_goal() -> Vector3:
	return _goal


func teleport(pos: Vector3) -> void:
	global_position = pos
	sync_position = position
	velocity = Vector3.ZERO
	bumper_bounce_left = 0.0
	buffs.clear()
	warp_lock = 0.0
	warp_grace = 0.0
	slide_left = 0.0
	stun_left = 0.0
	_repath_timer = 0.0
	_goal_timer = 0.0
	_stuck_from = global_position
	_stuck_kick_left = 0.0


func launch(v: Vector3) -> void:
	if v.y != 0.0:
		velocity.y = v.y
	velocity.x += v.x
	velocity.z += v.z
	_repath_timer = 0.0
	_stuck_from = global_position
	_stuck_kick_left = 0.0


func hold_bumper_bounce(horizontal: Vector3, duration: float) -> void:
	bumper_bounce_velocity = horizontal
	bumper_bounce_left = duration


func warp_to(pos: Vector3, up_vel: float, exit_kick := Vector3.ZERO) -> void:
	global_position = pos
	velocity = Vector3(exit_kick.x, up_vel, exit_kick.z)
	bumper_bounce_left = 0.0
	warp_lock = 0.9
	warp_grace = WARP_GRACE
	slide_left = 0.0
	_repath_timer = 0.0
	_goal_timer = 0.0
	_stuck_from = global_position
	_stuck_kick_left = 0.0


func apply_boost(mult: float, dur: float, kick: Vector3) -> void:
	buffs.add(&"speed", mult, dur)
	velocity.x += kick.x
	velocity.z += kick.z


func add_carry(v: Vector3) -> void:
	carry_velocity += v


func apply_slide(dir: Vector3, accel: float, cap: float) -> void:
	slide_dir = dir
	slide_accel = accel
	slide_cap = cap
	slide_left = SLIDE_GRACE


func apply_stun(seconds: float) -> void:
	stun_left = maxf(stun_left, seconds)
	velocity.x = 0.0
	velocity.z = 0.0
