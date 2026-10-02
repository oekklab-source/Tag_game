class_name SlideRide
extends RefCounted

## プレイヤー/CPU 共通。RECOVER は見た目だけで、移動を拘束しない。
enum Phase { NONE, ENTER, SIT, REVERSE_FALL, PRONE, RECOVER }
const ENTER_TIME := 7.0 / 30.0
const REVERSE_SPEED := 1.0
const REVERSE_FALL_START := 20.0 / 30.0
const FALL_TIME := 11.0 / 30.0
const RECOVER_TIME := 8.0 / 30.0
const CONTACT_GRACE := 0.12
## 下端からこの水平距離までは、通常移動で登って引き返せる。
const REVERSE_COMMIT_DISTANCE := 2.0
## ダイブの上り勢いを残しつつ、短い距離で停止させて下りへ返す。
const DIVE_UPHILL_MAX_SPEED := 5.0
const DIVE_TURN_ACCEL := 18.0
const DIVE_TOP_MARGIN := 0.2

var phase := Phase.NONE
var elapsed := 0.0
var direction := Vector3.FORWARD
var pitch := 0.0
var accel := 0.0
var cap := 18.0
var contact_left := 0.0
var source_id := 0
var reverse_approach := false
var dive_sliding := false
var dive_along := 0.0
var distance_to_top := INF


func active() -> bool:
	return dive_sliding or phase >= Phase.ENTER and phase <= Phase.PRONE


func approaching_reverse() -> bool:
	return reverse_approach


func sliding_dive() -> bool:
	return dive_sliding


## 逆走アプローチ中にダイブを開始した場合、Area の次回更新を待たずに
## 同じ滑り台のダイブ滑走へ引き継ぐ。踏み切りで判定面から浮く競合を防ぐ。
func begin_dive_from_approach(velocity: Vector3) -> bool:
	if not reverse_approach:
		return false
	_begin_dive(velocity, distance_to_top, direction)
	return true


func contact(id: int, dir: Vector3, slope: float, acceleration: float,
		max_speed: float, distance_from_bottom: float, distance_from_top: float,
		velocity: Vector3, dive_entry := false) -> void:
	# 起き上がりは最後まで見せる。移動は可能だが、接触で転倒を再開しない。
	if phase == Phase.RECOVER and not dive_entry:
		return
	if dive_entry:
		# phase は NONE のままにし、ダイブのアニメ・向きを一切上書きしない。
		# 最初の上り勢いは残すが、上端を飛び越さない速度へ抑える。
		if not dive_sliding or source_id != id:
			_begin_dive(velocity, distance_from_top, dir)
		source_id = id
	elif active() and source_id != id:
		source_id = id
		elapsed = 0.0
		phase = Phase.ENTER
		reverse_approach = false
		dive_sliding = false
	elif not active() and not reverse_approach:
		source_id = id
		elapsed = 0.0
		dive_sliding = false
		# 下端から登ってきた場合は、確定線まで通常移動を保つ。
		# 上から滑ってきたボディは正の下り速度を持つので区別できる。
		if distance_from_bottom < REVERSE_COMMIT_DISTANCE and velocity.dot(dir) <= 0.0:
			reverse_approach = true
		else:
			phase = Phase.ENTER
	elif reverse_approach and source_id == id \
			and distance_from_bottom >= REVERSE_COMMIT_DISTANCE:
		# 一度線を越えたら引き返しでは解除しない。
		reverse_approach = false
		phase = Phase.REVERSE_FALL
		elapsed = 0.0
	direction = dir
	pitch = slope
	accel = acceleration
	cap = max_speed
	distance_to_top = distance_from_top
	contact_left = CONTACT_GRACE


func _begin_dive(velocity: Vector3, remaining_to_top: float, slide_direction: Vector3) -> void:
	var stop_room := maxf(remaining_to_top - DIVE_TOP_MARGIN, 0.0)
	var safe_uphill := sqrt(2.0 * DIVE_TURN_ACCEL * stop_room)
	dive_along = maxf(velocity.dot(slide_direction), -minf(DIVE_UPHILL_MAX_SPEED, safe_uphill))
	elapsed = 0.0
	phase = Phase.NONE
	reverse_approach = false
	dive_sliding = true


func release(id: int) -> void:
	if source_id != id:
		return
	if dive_sliding:
		dive_sliding = false
		phase = Phase.NONE
	elif reverse_approach:
		reverse_approach = false
		phase = Phase.NONE
	elif active():
		phase = Phase.RECOVER if phase in [Phase.REVERSE_FALL, Phase.PRONE] else Phase.NONE
	else:
		return
	elapsed = 0.0
	contact_left = 0.0


func tick(delta: float) -> void:
	elapsed += delta
	if active() or reverse_approach:
		contact_left = maxf(0.0, contact_left - delta)
		if contact_left <= 0.0:
			release(source_id)
		elif phase == Phase.ENTER and elapsed >= ENTER_TIME:
			phase = Phase.SIT
			elapsed -= ENTER_TIME
		elif phase == Phase.REVERSE_FALL and elapsed >= FALL_TIME:
			phase = Phase.PRONE
			elapsed -= FALL_TIME
	elif phase == Phase.RECOVER and elapsed >= RECOVER_TIME:
		phase = Phase.NONE
		elapsed = 0.0


func move(v: Vector3, delta: float, input: Vector3, steer: float, minimum: float) -> Vector3:
	if dive_sliding:
		# 上向きの勢いだけは即座に反転させず、斜面で減速して下りへ返す。
		# すでに下向きならダイブ速度を固定・減速せず、通常滑走と同じ加速度で
		# 上限速度へ近づける。
		if dive_along >= minimum:
			var slide_velocity := SlideMotion.step(v, delta, direction, accel, cap,
				0.0, Vector3.ZERO, minimum)
			dive_along = Vector3(slide_velocity.x, 0.0, slide_velocity.z).dot(direction)
			return slide_velocity
		dive_along = move_toward(dive_along, minimum, DIVE_TURN_ACCEL * delta)
		var horizontal := Vector3(v.x, 0.0, v.z)
		var lateral := horizontal - direction * horizontal.dot(direction)
		var hv := direction * dive_along + lateral
		if hv.length() > cap:
			hv = hv.normalized() * cap
		return Vector3(hv.x, v.y, hv.z)
	if phase == Phase.REVERSE_FALL:
		# 登りは確定線までの通常移動で済んでいる。
		# 線上で上り速度を受け止め、転倒に合わせて下り速度を立ち上げる。
		var t := clampf(elapsed / FALL_TIME, 0.0, 1.0)
		var along := lerpf(0.0, minimum, smoothstep(0.0, 1.0, t))
		var hv := direction * along
		return Vector3(hv.x, v.y, hv.z)
	return SlideMotion.step(v, delta, direction, accel, cap, steer, input, minimum)


## phase / クリップ時刻 / 世界の向き / 斜面角を一括同期する。
func visual() -> Vector4:
	if phase == Phase.NONE:
		return Vector4.ZERO
	var reverse := phase in [Phase.REVERSE_FALL, Phase.PRONE, Phase.RECOVER]
	var facing := -direction if reverse else direction
	var tilt := pitch if reverse else -pitch
	if phase == Phase.RECOVER:
		tilt *= 1.0 - clampf(elapsed / RECOVER_TIME, 0.0, 1.0)
	var clip_time := REVERSE_FALL_START + elapsed if phase == Phase.REVERSE_FALL else elapsed
	return Vector4(phase, clip_time, atan2(-facing.x, -facing.z), tilt)


## 回復中も入力は即時反映。下りから上りへの速度反転だけを滑らかにする。
func recover_motion(v: Vector3, target: Vector2, delta: float) -> Vector3:
	var horizontal := Vector2(v.x, v.z).move_toward(target, 40.0 * delta)
	return Vector3(horizontal.x, v.y, horizontal.y)


func reset() -> void:
	phase = Phase.NONE
	elapsed = 0.0
	contact_left = 0.0
	source_id = 0
	reverse_approach = false
	dive_sliding = false
	dive_along = 0.0
	distance_to_top = INF
