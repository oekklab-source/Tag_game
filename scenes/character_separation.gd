class_name CharacterSeparation
extends RefCounted

## キャラ同士の重なりをほどく。
##
## player.tscn / cpu_hunter.tscn は collision_mask に Character(2) を含むので
## キャラ同士が衝突するが、CharacterBody3D 同士は move_and_slide() で
## 互いを押せない。そのため重なると:
##   - 横に重なった場合  : 双方が相手を壁と見なして楔状に固まり、動けなくなる
##   - 相手の頭に乗った場合: is_on_floor() が true になって重力が止まり、
##                          空中で静止したまま落ちてこない
## どちらも自力では抜けられないので、水平の分離速度を明示的に足してほどく。
##
## Player と CpuHunter で挙動が違うと片方だけ抜けられなくなるため、
## SlideMotion と同じく実装は1箇所に置く。

## カプセル半径 0.35 の2倍(0.7)＋余裕。この距離より近ければ押す
const RADIUS := 0.8
## 最大の分離速度 m/s。Player.BASE_SPEED(7.0) より遅くしてあるので、
## 押し合いが通常の移動に打ち勝って操作を奪うことはない
const FORCE := 5.0
## 高低差がこれを超える相手は別の階層にいる（カプセル全高1.8）。押さない
const LEVEL := 1.9
## 床と見なされる面の法線。move_and_slide() の接地判定と揃えてある
const FLOOR_NORMAL_Y := 0.6


## body が重なっている他キャラから離れるための水平速度。
##
## 位置は全ピアにレプリケートされているので、各権威ピアが自分の分だけ
## 計算すれば双方が反対向きへ離れる（RPC は不要）。
## 戻り値は carry_velocity と同じ「足して動かして引く」使い方をすること。
## 引かずに velocity へ残すと毎フレーム蓄積して吹き飛ぶ。
static func push(body: Node3D) -> Vector3:
	var tree := body.get_tree()
	if tree == null:
		return Vector3.ZERO
	var out := _push_from(body, tree.get_nodes_in_group("players"))
	return out + _push_from(body, tree.get_nodes_in_group("cpu_hunters"))


static func _push_from(body: Node3D, others: Array) -> Vector3:
	var out := Vector3.ZERO
	for other in others:
		if other == body or not is_instance_valid(other):
			continue
		var d: Vector3 = body.global_position - (other as Node3D).global_position
		if absf(d.y) > LEVEL:
			continue
		var flat := Vector2(d.x, d.z)
		var dist := flat.length()
		if dist > RADIUS:
			continue
		var dir := Vector2.ZERO
		if dist > 0.01:
			dir = flat / dist
		else:
			# 真上・真下にぴったり重なると向きが決まらない。ノード名 = peer_id なので
			# 名前から決めた角度は全ピアで一致し、かつ相手とは必ず別の向きになる
			dir = Vector2.RIGHT.rotated(float(absi(hash(String(body.name))) % 628) * 0.01)
		out += Vector3(dir.x, 0.0, dir.y) * FORCE * (1.0 - dist / RADIUS)
	return out


## 他キャラの頭の上に乗っているか。
##
## 直前の move_and_slide() の結果を読むので、is_on_floor() と同じく
## 「前フレームの接地」を表す。_physics_process の冒頭で呼べば整合する。
## true の間は接地扱いを外して重力を効かせ、push() で横へ滑り落とす。
static func on_character(body: CharacterBody3D) -> bool:
	for i in body.get_slide_collision_count():
		var c := body.get_slide_collision(i)
		if c.get_normal().y <= FLOOR_NORMAL_Y:
			continue
		var n := c.get_collider()
		if n is Node and (n.is_in_group("players") or n.is_in_group("cpu_hunters")):
			return true
	return false
