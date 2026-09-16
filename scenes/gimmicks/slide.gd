extends Area3D

## 滑り台の滑走判定。降りるのは速いが登れない一方通行の近道。
##
## 1本の滑り台につき Area は1つだけ。走路の中心線（center_line）を持ち、
## 体の位置から最寄りセグメントを引いてその地点の傾斜と向きを決める。
## セグメントごとに Area を作ると1本で11個、4本で44個になるため投影で済ませる。
##
## Area3D の body_entered は全ピアで発火するので、効果の適用は
## 「そのボディの権威ピア」に限定する（spring_pad.gd / boost_panel.gd と同じ規約）。
## 位置は既存のレプリケーションで他ピアへ伝わるため RPC は不要。

## 走路の中心線。WorldBuilder が add_child の前に設定する
@export var center_line := PackedVector3Array()
@export var cap := 18.0

## 斜面に沿った重力成分をそのまま使うと歩行速度(7.0)に対して物足りないので割り増す。
## 26.6° で 9.8 * sin(26.6°) * 1.6 ≒ 7.0 m/s^2。
## 走路14mを初速8m/sで入ると出口で約15m/s（ダッシュの1.4倍）になる
const GRAVITY := 9.8
const GRAVITY_SCALE := 1.6


func _ready() -> void:
	body_exited.connect(_release)


func _release(body: Node3D) -> void:
	if body.has_method("release_slide") and body.is_multiplayer_authority():
		body.release_slide(get_instance_id())


func _physics_process(_delta: float) -> void:
	if center_line.size() < 2:
		return
	for body in get_overlapping_bodies():
		if not body.has_method("apply_slide") or not body.is_multiplayer_authority():
			continue
		var i := _nearest_segment(body.global_position)
		var d: Vector3 = center_line[i + 1] - center_line[i]
		var flat := Vector3(d.x, 0.0, d.z)
		var run := flat.length()
		if run < 0.01:
			continue
		# Area は斜面の上方/出口平地まで伸びるため、重なりだけで滑らせない。
		# 足元が実際の斜面上へ入ってから開始し、出口線を越えた瞬間に解放する。
		var along := (body.global_position - center_line[i]).dot(flat / run)
		var surface_y := center_line[i].y + d.y * clampf(along / run, 0.0, 1.0)
		if d.y >= -0.01 or along < 0.0 or along >= run \
				or body.global_position.y < surface_y - 0.35 \
				or body.global_position.y > surface_y + 0.75:
			_release(body)
			continue
		var pitch := atan2(-d.y, run)
		body.apply_slide(flat / run, GRAVITY * sin(pitch) * GRAVITY_SCALE, cap,
			pitch, run - along < 2.0, get_instance_id())


## 体の真下のセグメントを線分への射影距離で選ぶ。
## 折り返しのない滑らかな走路なので、最短距離のセグメントが必ず正しい区間になる
func _nearest_segment(pos: Vector3) -> int:
	var best := 0
	var best_d := INF
	for i in center_line.size() - 1:
		var a: Vector3 = center_line[i]
		var ab: Vector3 = center_line[i + 1] - a
		var t := clampf((pos - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var d := pos.distance_squared_to(a + ab * t)
		if d < best_d:
			best_d = d
			best = i
	return best
