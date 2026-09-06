class_name SlideRide
extends RefCounted

## プレイヤー/CPU 共通。RECOVER は見た目だけで、移動を拘束しない。
enum Phase { NONE, ENTER, SIT, REVERSE_FALL, PRONE, RECOVER }
const ENTER_TIME := 7.0 / 30.0
const REVERSE_SPEED := 2.0
const CLIMB_TIME := 20.0 / (30.0 * REVERSE_SPEED)
const FALL_TIME := 31.0 / (30.0 * REVERSE_SPEED)
const RECOVER_TIME := 8.0 / 30.0
const CONTACT_GRACE := 0.12
const CLIMB_SPEED := 3.0 * REVERSE_SPEED

var phase := Phase.NONE
var elapsed := 0.0
var direction := Vector3.FORWARD
var pitch := 0.0
var accel := 0.0
var cap := 18.0
var contact_left := 0.0
var source_id := 0


func active() -> bool:
	return phase >= Phase.ENTER and phase <= Phase.PRONE


func contact(id: int, dir: Vector3, slope: float, acceleration: float,
		max_speed: float, near_bottom: bool, velocity: Vector3) -> void:
	# 起き上がりは最後まで見せる。移動は可能だが、接触で転倒を再開しない。
	if phase == Phase.RECOVER:
		return
	if not active() or source_id != id:
		source_id = id
		elapsed = 0.0
		phase = Phase.REVERSE_FALL if near_bottom and velocity.dot(dir) < -0.1 else Phase.ENTER
	direction = dir
	pitch = slope
	accel = acceleration
	cap = max_speed
	contact_left = CONTACT_GRACE


func release(id: int) -> void:
	if not active() or source_id != id:
		return
	phase = Phase.RECOVER if phase in [Phase.REVERSE_FALL, Phase.PRONE] else Phase.NONE
	elapsed = 0.0
	contact_left = 0.0


func tick(delta: float) -> void:
	elapsed += delta
	if active():
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
	if phase == Phase.REVERSE_FALL:
		# 元の登りに1歩追加し、移動/アニメの両方を2.0倍にする。
		var along := -CLIMB_SPEED * lerpf(1.0, 0.5, elapsed / CLIMB_TIME)
		if elapsed >= CLIMB_TIME:
			var t := clampf((elapsed - CLIMB_TIME) / (FALL_TIME - CLIMB_TIME), 0.0, 1.0)
			along = lerpf(-CLIMB_SPEED * 0.5, 11.0 / 30.0 * 5.0, smoothstep(0.0, 1.0, t))
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
	var clip_time := elapsed * REVERSE_SPEED if phase == Phase.REVERSE_FALL else elapsed
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
