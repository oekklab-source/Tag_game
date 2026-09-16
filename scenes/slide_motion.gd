class_name SlideMotion
extends RefCounted

## 滑り台の上での速度計算。Player と CpuHunter が同じ物理で滑る必要があり、
## 逆走時の短い登り（SlideRide）を終えた後は、この式で下り方向を保証する。
##
## 通常の接地移動（velocity を目標速度で毎フレーム上書き）とは排他。
## 滑走中は上書きを止めて、代わりにこの関数の結果をそのまま velocity にする。


## v         現在の速度
## dir       その地点の水平最急降下方向（正規化済み）
## accel     斜面から算出した加速度 m/s^2（平坦な出口区間では 0）
## cap       この滑り台での上限速度
## steer     左右の寄せの効き
## input     プレイヤー/AI の移動方向（水平・正規化済み。無入力なら ZERO）
## min_speed 走路上で維持される最低前進速度
static func step(v: Vector3, delta: float, dir: Vector3, accel: float, cap: float,
		steer: float, input: Vector3, min_speed: float) -> Vector3:
	var hv := Vector3(v.x, 0.0, v.z)
	hv += dir * accel * delta
	hv += Vector3(input.x, 0.0, input.z) * steer * delta
	# 操作を加えた後で下り成分を保証する。逆走の短い登りは SlideRide が担当。
	# 前フレームの入力で上りに転じても次フレームで押し戻されるので、
	# 走路を登り切ることはできない（滑走中は飛びつきも開始しない）
	var along := hv.dot(dir)
	if along < min_speed:
		hv += dir * (min_speed - along)
	if hv.length() > cap:
		hv = hv.normalized() * cap
	# 垂直方向は触らない。重力とスナップに任せる
	return Vector3(hv.x, v.y, hv.z)
