extends CharacterBody3D

## ソロモード用の CPU 鬼。ロジックはホスト（サーバ）でのみ動作し、
## 位置・回転は MultiplayerSynchronizer で途中参加者にも配信される。
##
## 逃走者の位置は**知らない**。人間の鬼とまったく同じ情報しか持たず、3状態で動く:
##   CHASE       自分が視認している -> 実際の位置へ回り込みながら直接追う
##   INVESTIGATE 誰かが通報したゾーンがある -> そこへ行き、中を掃くように歩き回る
##   PATROL      情報なし -> マップ全体を決まった順路で巡回して探す
## 視認判定は GameManager に一本化してあり、ここでレイは飛ばさない。

## 逃走者の持続平均速度（約8.65 m/s）よりわずかに遅く、歩行(7.0)より明確に速い。
## この差がじわじわ詰められる圧力になる。
## 補足: get_speed_mult() は peer_id 基準で CPU はピアではないため、
## 人数による速度補正の対象外。CPU はこの定数だけで調整する
const SPEED := 8.2
const JUMP_VELOCITY := 5.2
const FLANK_RADIUS := 4.0

enum Mind { PATROL, INVESTIGATE, CHASE }

## 巡回の順路。隣り合う要素が必ず辺で接するので、各区間は短くスロープも確実にある。
## 端で折り返す（環状にしない）ので 8->0 の150m移動は起きない
const PATROL_ORDER: Array[int] = [0, 1, 2, 5, 4, 3, 6, 7, 8]
## ゾーン中心からこの距離まで寄れば到着とみなす。
## zone_index による判定にすると、境界を歩く CPU が跨いだ瞬間に「到着」して
## 次（＝今出たゾーン）へ進み、継ぎ目で永久に振動する。
## 12m は壁のない十字通路の内側（壁は local 9 から）なので必ず到達できる
const PATROL_ARRIVE := 12.0
const PATROL_TIMEOUT := 20.0
## 捜索中はゾーン中心に立ち止まらず歩き回る。6m壁があると中心からは
## ゾーンの3割程度しか見えず、視野を振って初めて死角が潰れる
const SWEEP_RADIUS := 18.0
const SWEEP_ARRIVE := 4.0
const SWEEP_TIMEOUT := 6.0
## 目的地があるのにほとんど進めていない＝何かに押し付けられている。
## ナビメッシュに焼かれていない設置ブロックが典型だが、壁の角や
## CPU 同士の押し合いでも起きるので汎用の脱出手段として持たせる
const STUCK_DIST := 0.6
const STUCK_TIME := 1.0
const SIDESTEP_TIME := 1.2
const SIDESTEP_DIST := 6.0
const AIR_STEER := 6.0        # 空中での方向転換（プレイヤーより弱く、慣性を残す）
const REPATH_INTERVAL := 0.3
const TURN_SPEED := 8.0
const JUMP_COOLDOWN := 0.7
const DIRECT_CHASE_DIST := 10.0
const HUNTER_COLOR := Player.COLOR_HUNTER

var buffs := BuffSet.new()
var carry_velocity := Vector3.ZERO
var warp_lock := 0.0

var _repath_timer := 0.0
var _jump_cooldown := 0.0
var _last_pos := Vector3.ZERO
var _flank_angle := 0.0
var _mind: int = Mind.PATROL
var _patrol_i := 0
var _patrol_dir := 1
var _goal := Vector3.ZERO
var _goal_timer := 0.0
var _rng := RandomNumberGenerator.new()
var stun_left := 0.0
var _stuck_timer := 0.0
var _stuck_from := Vector3.ZERO
var _sidestep_left := 0.0
var _sidestep_goal := Vector3.ZERO

@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var humanoid: Node3D = $Humanoid


func _ready() -> void:
	add_to_group("cpu_hunters")
	humanoid.set_color(HUNTER_COLOR)
	_last_pos = global_position
	$TagArea.body_entered.connect(_on_tag_area_body_entered)
	# 個体ごとに狙う位置をずらし、再経路探索のタイミングも散らす
	_flank_angle = randf() * TAU
	_repath_timer = randf() * REPATH_INTERVAL
	_rng.seed = hash(name)
	# 巡回の開始位置を個体ごとにずらして全員が同じゾーンへ集まらないようにする。
	# add_to_group の直後なので size() は 1..N（5体なら順路の 2,4,6,8,1 番目）
	var spawn_index := get_tree().get_nodes_in_group("cpu_hunters").size()
	_patrol_i = (spawn_index * 2) % PATROL_ORDER.size()


func _on_tag_area_body_entered(body: Node3D) -> void:
	if multiplayer.is_server():
		GameManager.report_touch(self, body)


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

	buffs.tick(delta)
	warp_lock = maxf(warp_lock - delta, 0.0)
	stun_left = maxf(stun_left - delta, 0.0)

	if not is_on_floor():
		velocity += get_gravity() * delta
	_jump_cooldown = maxf(_jump_cooldown - delta, 0.0)

	var chasing := (GameManager.state == GameManager.State.PLAYING
		and GameManager.head_start_left <= 0.0
		and stun_left <= 0.0)
	var dir := Vector3.ZERO
	var rise := 0.0
	if chasing:
		var runner: Node3D = GameManager.get_runner()
		if runner:
			# 状態を先に決める。自分の視認 > 共有された通報 > 情報なし
			var mind := Mind.PATROL
			if GameManager.hunter_sees_runner(self):
				mind = Mind.CHASE
			elif GameManager.spotted_zone >= 0:
				mind = Mind.INVESTIGATE
			if mind != _mind:
				_mind = mind
				_repath_timer = 0.0  # 状態が変わったら即座に経路を引き直す
				_goal_timer = 0.0
			_goal_timer -= delta
			_update_goal(runner, delta)
			_avoid_stuck(delta)

			_repath_timer -= delta
			if _repath_timer <= 0.0:
				_repath_timer = REPATH_INTERVAL
				agent.target_position = _goal
			var next := agent.get_next_path_position()
			var to_runner := runner.global_position - global_position
			var h_dist := Vector2(to_runner.x, to_runner.z).length()
			# 見えている近距離で高低差が小さい、またはナビで到達不能なら直接追跡へ
			if (_mind == Mind.CHASE and h_dist < DIRECT_CHASE_DIST
					and (absf(to_runner.y) < 1.2 or not agent.is_target_reachable())):
				next = runner.global_position
			dir = next - global_position
			rise = dir.y
			dir.y = 0.0
			dir = dir.normalized() if dir.length() > 0.05 else Vector3.ZERO
			# 壁に当たった/目標が高い場合はジャンプ（スロープや1m段差を跳んで登る）
			if is_on_floor() and _jump_cooldown <= 0.0 and (is_on_wall() or rise > 0.4):
				velocity.y = JUMP_VELOCITY * buffs.get_mult(&"jump")
				_jump_cooldown = JUMP_COOLDOWN

	# プレイヤーと同じく、空中では慣性を保つ（打ち上げ・ブーストが消えないように）
	var speed := SPEED * buffs.get_mult(&"speed")
	var target := Vector2(dir.x, dir.z) * speed
	if is_on_floor():
		velocity.x = target.x
		velocity.z = target.y
	elif dir != Vector3.ZERO:
		velocity.x = move_toward(velocity.x, target.x, AIR_STEER * delta)
		velocity.z = move_toward(velocity.z, target.y, AIR_STEER * delta)
	if dir != Vector3.ZERO:
		rotation.y = lerp_angle(rotation.y, atan2(-dir.x, -dir.z), TURN_SPEED * delta)

	velocity += carry_velocity
	move_and_slide()
	velocity -= carry_velocity
	carry_velocity = Vector3.ZERO

	if global_position.y < WorldData.FALL_LIMIT:
		teleport(WorldData.zone_center(WorldData.zone_index(global_position)) + Vector3(0, 3, 0))


## 状態に応じて目的地を更新する。
## 目的地は「到着したか時間切れの時」だけ差し替え、毎フレーム動かさない
## （動かすと NavigationAgent3D の経路が落ち着かず、その場で震える）
func _update_goal(runner: Node3D, _delta: float) -> void:
	match _mind:
		Mind.CHASE:
			# 全員が一列に詰まらないよう、個体ごとに違う側から回り込む
			_flank_angle += REPATH_INTERVAL * 0.5
			_goal = runner.global_position \
				+ Vector3(cos(_flank_angle), 0.0, sin(_flank_angle)) * FLANK_RADIUS
		Mind.INVESTIGATE:
			var zone: int = GameManager.spotted_zone
			if WorldData.zone_index(global_position) != zone:
				_goal = WorldData.zone_center(zone)  # まず現地へ
				_goal_timer = SWEEP_TIMEOUT
			elif _goal_timer <= 0.0 or _xz_dist(global_position, _goal) < SWEEP_ARRIVE:
				# 着いたらゾーン内を掃くように歩き回る
				_goal = WorldData.zone_point(zone,
					_rng.randf_range(-SWEEP_RADIUS, SWEEP_RADIUS),
					_rng.randf_range(-SWEEP_RADIUS, SWEEP_RADIUS))
				_goal_timer = SWEEP_TIMEOUT
		_:
			_goal = WorldData.zone_center(PATROL_ORDER[_patrol_i])
			if _xz_dist(global_position, _goal) < PATROL_ARRIVE or _goal_timer <= 0.0:
				_advance_patrol()


## 目的地があるのに進めていないとき、横へずれる目標に一時的に差し替える。
## 設置ブロックはナビメッシュに焼かれないため経路探索では避けられない。
## 壁の角や CPU 同士の押し合いにも同じ手で抜けられる
func _avoid_stuck(delta: float) -> void:
	if _sidestep_left > 0.0:
		# _update_goal が毎フレーム本来の目標を書き戻すので、迂回中は上書きし続ける
		_sidestep_left -= delta
		_goal = _sidestep_goal
		return
	_stuck_timer += delta
	if _stuck_timer < STUCK_TIME:
		return
	var moved := _xz_dist(global_position, _stuck_from)
	_stuck_timer = 0.0
	_stuck_from = global_position
	if moved >= STUCK_DIST:
		return
	# 目的地の方向に対して直角の、開いている側へ逃がす
	var to_goal := _goal - global_position
	var side := Vector3(-to_goal.z, 0.0, to_goal.x).normalized()
	if _rng.randf() < 0.5:
		side = -side
	_sidestep_goal = global_position + side * SIDESTEP_DIST
	_goal = _sidestep_goal
	_sidestep_left = SIDESTEP_TIME
	_repath_timer = 0.0


func _advance_patrol() -> void:
	_patrol_i += _patrol_dir
	if _patrol_i >= PATROL_ORDER.size():
		_patrol_i = PATROL_ORDER.size() - 2
		_patrol_dir = -1
	elif _patrol_i < 0:
		_patrol_i = 1
		_patrol_dir = 1
	_goal = WorldData.zone_center(PATROL_ORDER[_patrol_i])
	_goal_timer = PATROL_TIMEOUT
	_repath_timer = 0.0


func _xz_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## 土管が「その近道は自分の役に立つか」を判断するために参照する。
## 逃走者の位置ではなく今向かっている場所で判断させること
func get_ai_goal() -> Vector3:
	return _goal


## --- ギミックから呼ばれる API（player.gd と同じ契約） --------------------
## CPU はサーバ権威なので、これらはサーバ上でのみ実行される

func teleport(pos: Vector3) -> void:
	global_position = pos
	_last_pos = pos
	velocity = Vector3.ZERO
	buffs.clear()
	warp_lock = 0.0
	_repath_timer = 0.0
	_goal_timer = 0.0


func launch(v: Vector3) -> void:
	if v.y != 0.0:
		velocity.y = v.y
	velocity.x += v.x
	velocity.z += v.z


func warp_to(pos: Vector3, up_vel: float) -> void:
	global_position = pos
	_last_pos = pos
	velocity = Vector3(0, up_vel, 0)
	warp_lock = 0.9
	_repath_timer = 0.0  # ワープ直後は経路と目的地を引き直す
	_goal_timer = 0.0


func apply_boost(mult: float, dur: float, kick: Vector3) -> void:
	buffs.add(&"speed", mult, dur)
	velocity.x += kick.x
	velocity.z += kick.z


func add_carry(v: Vector3) -> void:
	carry_velocity += v


## バナナを踏んだ時の転倒。？ブロックは CPU に反応しないので、
## CPU が受け取るアイテム系の効果はこれだけ
func apply_stun(seconds: float) -> void:
	stun_left = maxf(stun_left, seconds)
	velocity.x = 0.0
	velocity.z = 0.0
