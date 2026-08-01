class_name SlideMotion
extends RefCounted

## 滑り台の上での速度計算。Player と CpuHunter が同じ物理で滑る必要があり、
## 「登れない」保証がこの式そのものなので、複製せず1箇所に置く。
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
	# 進行方向成分が最低速度を下回ったら必ず引き上げる。
	# 前フレームの入力で上りに転じても次フレームで押し戻されるので、
	# 走路を登り切ることは原理的にできない（滑走中はジャンプも封じてある）
	var along := hv.dot(dir)
	if along < min_speed:
		hv += dir * (min_speed - along)
	hv += Vector3(input.x, 0.0, input.z) * steer * delta
	if hv.length() > cap:
		hv = hv.normalized() * cap
	# 垂直方向は触らない。重力とスナップに任せる
	return Vector3(hv.x, v.y, hv.z)
