extends StaticBody3D

## 土管ワープ。ペアの土管の真上へ飛び出す。
## 本体は静的コリジョンなのでナビメッシュに障害物として焼かれ、CPU は迂回する。
##
## 効果の適用は「そのボディの権威ピア」に限定する。ワープ後の位置は
## 既存の位置レプリケーションで他ピアへ伝わるため RPC は不要。

const EXIT_HEIGHT := 3.0   # 出口の土管の上どれだけ高い位置に出すか
const EXIT_UP := 6.0       # 飛び出す勢い
## 出口で足す水平方向の勢い。真上にしか飛ばさないと、入った時と同じ座標へ
## そのまま落ちてくる。空中では横移動が弱い（AIR_ACCEL）ので、無入力だと
## warp_lock(0.9s) が切れる前後で同じ土管の口へ戻って再突入し、無限ループになる。
## 「進行方向」に軽く逃がしておけば、無操作でも口の外へ着地する
const EXIT_FORWARD := 4.0
const CPU_EXIT_OFFSET := 4.0
## CPU は「今向かっている場所までの距離がこれ以上短くなる」時だけ入る。
## そうしないと単に近くを通っただけで意味なくワープしてしまう。
## 基準は逃走者ではなく CPU の目的地であること — 逃走者を基準にすると、
## 位置を知らないはずの CPU が逃走者に引き寄せられる（全知の抜け道になる）
const CPU_SHORTCUT_MIN := 15.0

var pair: Node3D  # 対になる土管（WorldBuilder が生成時に相互設定する）


func _ready() -> void:
	$Mouth.body_entered.connect(_on_mouth_entered)


func _on_mouth_entered(body: Node3D) -> void:
	if pair == null or not body.has_method("warp_to") or not body.is_multiplayer_authority():
		return
	if body.warp_lock > 0.0:
		return  # 出口側の土管で即座に戻ってしまうのを防ぐ
	if _is_cpu(body) and not _cpu_wants(body):
		return
	# 「進行方向」= 入った時に実際に動いていた向き。移動していなければ
	# 向いている方向で代える（直立で突っ込んでも真上だけには飛ばさない）
	var vel_flat := Vector3(body.velocity.x, 0.0, body.velocity.z)
	var dir := (vel_flat.normalized() if vel_flat.length() > 0.5
		else -body.global_transform.basis.z)
	if _is_cpu(body):
		dir = _cpu_exit_dir(body, dir)
		body.warp_to(pair.global_position + dir * CPU_EXIT_OFFSET + Vector3(0, EXIT_HEIGHT, 0),
			EXIT_UP, dir * EXIT_FORWARD)
	else:
		body.warp_to(pair.global_position + Vector3(0, EXIT_HEIGHT, 0), EXIT_UP,
			dir * EXIT_FORWARD)

func _is_cpu(body: Node3D) -> bool:
	return body.is_in_group("cpu_hunters") or body.is_in_group("cpu_runners")


func _cpu_exit_dir(cpu: Node3D, fallback: Vector3) -> Vector3:
	if cpu.has_method("get_ai_goal"):
		var to_goal: Vector3 = cpu.get_ai_goal() - pair.global_position
		to_goal.y = 0.0
		if to_goal.length() > 0.1:
			return to_goal.normalized()
	fallback.y = 0.0
	return fallback.normalized() if fallback.length() > 0.1 else Vector3.FORWARD


func _cpu_wants(cpu: Node3D) -> bool:
	if not cpu.has_method("get_ai_goal"):
		return false
	var goal: Vector3 = cpu.get_ai_goal()
	var here := global_position.distance_to(goal)
	var there := pair.global_position.distance_to(goal)
	return here - there >= CPU_SHORTCUT_MIN
