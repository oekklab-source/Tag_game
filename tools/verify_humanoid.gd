extends SceneTree

## humanoid.tscn が glTF から正しく組み上がるかをヘッドレスで確認する検証スクリプト。
## 実行: godot --headless --path <project> --script res://tools/verify_humanoid.gd
##
## 着せ替え（Humanoid.SKINS）を1つずつ着せて全項目を確認する。全スキンで
## **ボーン名とアニメ名がまったく同じ**であることがこの仕組みの前提なので、
## 新しい服を足したらまずこれを通すこと。


func _process(_delta: float) -> bool:
	var humanoid: Node3D = load("res://scenes/humanoid.tscn").instantiate()
	root.add_child(humanoid)
	for id in Humanoid.SKINS.size():
		humanoid.set_skin(id)
		_check(humanoid, id)
	quit()
	return true


func _check(humanoid: Node3D, id: int) -> void:
	var model := humanoid.get_node("Model")
	print("=== skin %d: %s ===" % [id, Humanoid.SKINS[id]["name"]])
	print("--- node tree ---")
	_dump(humanoid, 0)

	var player: AnimationPlayer = model.find_child("AnimationPlayer", true, false)
	print("--- animations ---")
	for anim_name in player.get_animation_list():
		var anim := player.get_animation(anim_name)
		print("  %s  len=%.2fs  loop=%d" % [anim_name, anim.length, anim.loop_mode])

	print("--- bounds / facing ---")
	var aabb := _mesh_aabb(humanoid)
	print("  aabb pos=%s size=%s" % [aabb.position, aabb.size])
	# 顔は正面。Godot の前方は -Z なので顔側の z が負なら正しい向き
	print("  facing: front z=%.3f  back z=%.3f" % [aabb.position.z, aabb.end.z])
	var skel: Skeleton3D = model.find_child("Skeleton3D", true, false)
	print("  bones=%d" % skel.get_bone_count())
	var foot := skel.get_bone_global_pose(skel.find_bone("Foot.L")).origin
	print("  Foot.L rest z(-Zが前)=%.3f x=%.3f" % [foot.z, foot.x])

	print("--- state machine ---")
	# update_motion は速度を時定数で平滑化する（ネットワーク越しの推定値が
	# 跳ねても脚の回転が痙攣しないように）。1秒ぶんの delta を渡せば収束するので、
	# 1回の呼び出しで最終状態を見られる
	var step := 1.0
	humanoid.update_motion(8.0, true, step)
	print("  run     -> %s speed_scale=%.2f" % [player.current_animation, player.speed_scale])
	humanoid.update_motion(0.0, true, step)
	print("  idle    -> %s" % player.current_animation)
	humanoid.update_motion(4.0, false, step)
	print("  air     -> %s" % player.current_animation)
	humanoid.set_diving(true)
	humanoid.update_motion(9.0, true, step)
	print("  diving  -> %s" % player.current_animation)
	humanoid.set_diving(false)
	# 転倒はダイブより優先。走っている速度を渡しても Slip になること
	humanoid.set_stunned(true)
	humanoid.update_motion(9.0, true, step)
	print("  stunned -> %s" % player.current_animation)
	humanoid.set_stunned(false)
	humanoid.update_motion(0.0, true, step)
	print("  recover -> %s" % player.current_animation)

	# 役割色をやめたので material_override は付かない。素材はスキンが持つものが
	# そのまま出るのが正しい（空のマテリアルが混じると Blender 側の塗り忘れ）
	print("--- materials ---")
	for part in ["Body", "Face", "Costume"]:
		var mesh: MeshInstance3D = model.find_child(part, true, false)
		if mesh == null:
			print("  %s: なし" % part)
			continue
		var names := []
		for i in mesh.mesh.get_surface_count():
			var mat := mesh.mesh.surface_get_material(i)
			names.append(mat.resource_name if mat else "*** 未設定 ***")
		print("  %s override=%s surfaces=%s" % [part, mesh.material_override, names])


func _dump(node: Node, depth: int) -> void:
	print("  ".repeat(depth) + "- %s (%s)" % [node.name, node.get_class()])
	if depth >= 3:
		return
	for child in node.get_children():
		_dump(child, depth + 1)


func _mesh_aabb(node: Node) -> AABB:
	var out := AABB()
	var first := true
	for mesh in _all_meshes(node):
		var box := mesh.global_transform * mesh.get_aabb()
		out = box if first else out.merge(box)
		first = false
	return out


func _all_meshes(node: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		found.append(node)
	for child in node.get_children():
		found.append_array(_all_meshes(child))
	return found
