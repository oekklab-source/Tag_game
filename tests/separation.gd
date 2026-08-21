extends Node

## キャラ同士が重なっても必ずほどけることを確かめる。
##
##   godot --headless --path . res://tests/separation.tscn --quit-after 1200
##
## player.tscn / cpu_hunter.tscn は collision_mask に Character(2) を含むので
## キャラ同士が衝突するが、CharacterBody3D 同士は move_and_slide() で
## 互いを押せない。対策（CharacterSeparation）が無いと:
##   1. 相手の頭に乗る -> is_on_floor() が true になって重力が止まり、
##      空中で静止したまま落ちてこない（＝「浮くバグ」）
##   2. 横に重なる     -> 双方が相手を壁と見なして楔状に固まり、動けない
##
## 相手役には CPU 鬼を使う。ヘッドレスの単独ピアではプレイヤーは1体しか
## 権威を持てず（ノード名 = peer_id）、2体目は物理を回さないため。
## CPU はサーバ権威なのでここで動く。ただし巡回で勝手に歩き回ると測定が
## ぶれるので、置いたあとは物理を止めて「動かない障害物」にする。

const SETTLE_FRAMES := 120
## カプセル半径 0.35 の2倍。これ以上離れていれば重なっていない
const CLEAR_GAP := 0.7

var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world
	for i in 30:
		await get_tree().physics_frame

	var player: CharacterBody3D = world.get_node_or_null("Players/1")
	if player == null:
		print("FAIL: Players/1 が見つからない")
		get_tree().quit()
		return

	var ground := WorldData.zone_center(WorldData.zone_index(Vector3.ZERO))
	world.spawn_cpu_hunter(ground + Vector3(0, 0.5, 0))
	await get_tree().physics_frame
	var cpu: CharacterBody3D = world.get_node_or_null("Players/CPU1")
	if cpu == null:
		print("FAIL: CPU 鬼を湧かせられなかった")
		get_tree().quit()
		return
	for i in 30:
		await get_tree().physics_frame
	# 以降は動かない障害物として扱う（巡回で歩かれると測定できない）
	cpu.set_physics_process(false)
	cpu.velocity = Vector3.ZERO
	var base := cpu.global_position

	await _check("相手の頭の上に置いた場合", player, cpu, base + Vector3(0, 1.9, 0), base.y)
	await _check("ほぼ同座標に重ねた場合", player, cpu, base + Vector3(0.05, 0, 0.05), base.y)

	print("--- 結果: %s ---" % ("ALL OK" if _fails == 0 else "%d 件 FAIL" % _fails))
	get_tree().quit()


func _check(title: String, player: CharacterBody3D, cpu: CharacterBody3D,
		start: Vector3, ground_y: float) -> void:
	player.teleport(start)
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame

	var d := player.global_position - cpu.global_position
	var gap := Vector2(d.x, d.z).length()
	var height := player.global_position.y - ground_y
	print("--- %s ---" % title)
	_report("水平距離 %.2f m" % gap, gap >= CLEAR_GAP, "重なったまま抜けられていない")
	_report("地面からの高さ %.2f m" % height, height < 0.6,
		"相手の上に乗ったまま空中で静止している")
	_report("接地 %s" % player.is_on_floor(), player.is_on_floor(), "床に立てていない")


func _report(what: String, ok: bool, why: String) -> void:
	if not ok:
		_fails += 1
	print("  %s  %s" % [what, "OK" if ok else "FAIL（%s）" % why])
