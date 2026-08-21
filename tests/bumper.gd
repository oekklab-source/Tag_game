extends Node

## バンパーが実際に弾き返すかを確かめる。
##
##   godot --headless --path . res://tests/bumper.tscn --quit-after 900
##
## 見るところは2つ:
##   1. どの向きから当たっても「バンパーから離れる向き」へ速度が向くこと
##   2. 天面に落ちても弾かれること（上に立てないの保証をこの Area が兼ねている）
##
## 以前ここには当たり判定の無い緑のドームが飾りとして置いてあり、
## 走ると素通りしてしまっていた。素通りに戻っていないかの回帰でもある。

const APPROACH := 8.0  # 走り込む速度（Player.SPEED 相当）
const SETTLE := 24     # 弾かれた後、向きを見るまでに回す物理フレーム


func _ready() -> void:
	await get_tree().process_frame
	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world
	for i in 20:
		await get_tree().physics_frame

	var player: Node3D = world.get_node_or_null("Players/1")
	if player == null:
		print("FAIL: プレイヤーがスポーンしていない")
		get_tree().quit()
		return

	var bumpers: Array[Node3D] = []
	for n in world.get_node("NavRegion/Map").get_children():
		if String(n.name).begins_with("Bumper"):
			bumpers.append(n)
	print("bumpers: %d" % bumpers.size())
	if bumpers.is_empty():
		print("FAIL: バンパーが1つも建っていない")
		get_tree().quit()
		return
	print("  Hit エリアあり: %d / %d" % [
		bumpers.filter(func(b: Node3D) -> bool: return b.has_node("Hit")).size(),
		bumpers.size()])

	var target: Node3D = bumpers[0]
	print("\n--- 横から当たる（%s） ---" % target.name)
	for deg in [0.0, 90.0, 180.0, 270.0]:
		var dir := Vector3(cos(deg_to_rad(deg)), 0.0, sin(deg_to_rad(deg)))
		await _hit(player, target, target.global_position + dir * 4.6, -dir * APPROACH, deg)

	print("\n--- 真上から落ちる ---")
	await _hit(player, target, target.global_position + Vector3(0, 3.0, 0),
		Vector3(0, -4.0, 0), -1.0)
	get_tree().quit()


## start へ置いて vel で撃ち込み、離れる向きへ弾かれたかを見る
func _hit(player: Node3D, target: Node3D, start: Vector3, vel: Vector3,
		deg: float) -> void:
	player.teleport(start)
	await get_tree().physics_frame
	player.velocity = vel
	var closest := INF
	for i in SETTLE:
		await get_tree().physics_frame
		closest = minf(closest, _flat_dist(player.global_position, target.global_position))
	var away := player.global_position - target.global_position
	away.y = 0.0
	var moved := _flat_dist(player.global_position, target.global_position)
	# 弾かれていれば「最接近点より離れた場所」に居て、速度も外を向く
	var out := Vector2(player.velocity.x, player.velocity.z).dot(
		Vector2(away.x, away.z).normalized())
	var label := "上から" if deg < 0.0 else "%3.0f°から" % deg
	print("  %s: 最接近 %.2fm -> 現在 %.2fm  外向き速度 %+.2f m/s  %s"
		% [label, closest, moved, out,
			"OK" if moved > closest + 0.3 and out > 0.0 else "FAIL"])


func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
