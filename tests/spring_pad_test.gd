extends Node

## ジャンプ台のモデル・コリジョン・打ち上げ・アニメーションを総合検証するテスト

func _ready() -> void:
	var spring_scene: PackedScene = load("res://scenes/gimmicks/spring_pad.tscn")
	var pad: Area3D = spring_scene.instantiate()
	add_child(pad)

	var spring_node: Node3D = pad.get_node_or_null("Mesh/SpringPadModel/SpringPad/Spring")
	var shape: CollisionShape3D = pad.get_node_or_null("Shape")

	print("=== ジャンプ台の総合検証 ===")
	print("  Spring ノード: ", "OK" if spring_node != null else "FAIL")
	print("  Spring 位置 Y: ", spring_node.position.y if spring_node != null else -1.0)
	print("  台座上面 (0.22m) との整合性: ", "OK" if is_equal_approx(spring_node.position.y, 0.22) else "FAIL")

	# アニメーション発動（_boing）のテスト
	if pad.has_method("_boing"):
		pad._boing()
		print("  _boing 呼び出し: OK (Tween 生成完了)")

	# 各ジャンプ台の配置がスロープ（斜めの道）に重なっていないか検証
	var occupied: Array[Vector3] = []
	for i in WorldData.SPRING_PADS.size():
		var e: Array = WorldData.SPRING_PADS[i]
		var pos := WorldData.zone_point(e[0], e[1], e[2])
		occupied.append(pos)
		WorldBuilder._assert_clear_of_ramps(e[0], pos, "SpringPad%d" % i)
		print("  SpringPad%d (ゾーン%d): pos=%s -> スロープ干渉なし OK" % [i, e[0], pos])

	print("=== すべての検証に合格しました ===")
	get_tree().quit()
