extends Node3D
## 外周の天面だけが傾く。滞在時間はホストでキャラクターごとに管理する。
const WAIT := 5.0
const THICK := 0.3
const DURATION := 1.6
var caps: Array[AnimatableBody3D] = []
var outward: Array[Vector3] = []
var lengths: Array[float] = []
var rests: Array[Transform3D] = []
var ages: Dictionary = {}
var stays: Dictionary = {}

static func install(map_root: Node3D, decor_root: Node3D, material: Material) -> Node3D:
	var rim := Node3D.new()
	rim.set_script(load("res://scenes/perimeter_rim.gd"))
	rim.name = "PerimeterRim"
	map_root.add_child(rim)
	var half := WorldData.WORLD_HALF
	var top := WorldData.SLAB_BOTTOM + WorldData.WALL_HEIGHT
	for side in [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT]:
		var tangent: Vector3 = Vector3.UP.cross(side)
		var count := 20
		var width := (half * 2.0 + 2.0) / count
		for i in count:
			var center: Vector3 = side * (half + 0.5) + tangent * (-half - 1.0 + width * (i + 0.5))
			center.y = top - THICK * 0.5
			rim.add_cap(center, side, width, material)
	for signs in [Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(1, 0, 1), Vector3(-1, 0, 1)]:
		var center: Vector3 = signs * (half - WorldBuilder.WALL_CORNER_CHAMFER * 0.5)
		center.y = top - THICK * 0.5
		rim.add_cap(center, signs.normalized(), WorldBuilder.WALL_CORNER_CHAMFER * sqrt(2.0), material)
		var cap: AnimatableBody3D = rim.caps.back()
		for child in cap.get_children():
			cap.remove_child(child)
			child.free()
		WorldBuilder.corner_prism(cap, signs, top - THICK, top, material)

	add_giant(decor_root)
	return rim

func add_cap(center: Vector3, direction: Vector3, length: float, material: Material) -> void:
	var cap := AnimatableBody3D.new()
	cap.name = "Cap%d" % caps.size()
	cap.position = center
	cap.basis = Basis(Vector3.UP.cross(direction), Vector3.UP, direction)
	cap.sync_to_physics = false
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(length, THICK, 1.0)
	mesh.mesh = box
	mesh.material_override = material
	cap.add_child(mesh)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = box.size
	col.shape = shape
	cap.add_child(col)
	add_child(cap)
	caps.append(cap)
	outward.append(direction)
	lengths.append(length)
	rests.append(cap.transform)

static func add_giant(root: Node3D) -> void:
	var giant: Node3D = preload("res://assets/character/fallguy.glb").instantiate()
	giant.name = "UnpaintedGiant"
	giant.position = Vector3(-580, -420, 580)
	# 黄色いバネの谷（南西角）から約707m先。顔を角へ向ける。
	giant.rotation.y = deg_to_rad(135.0)
	giant.scale = Vector3.ONE * 240.0
	root.add_child(giant)
	var anim := giant.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if anim:
		anim.play("Idle")
		anim.advance(0.0)
		anim.pause()
	var clay := StandardMaterial3D.new()
	clay.albedo_color = Color(0.82, 0.82, 0.82)
	clay.roughness = 1.0
	for node in giant.find_children("*", "MeshInstance3D", true, false):
		node.material_override = clay
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	giant.process_mode = Node.PROCESS_MODE_DISABLED

func actors() -> Array:
	return get_tree().get_nodes_in_group("players") + get_tree().get_nodes_in_group("cpu_hunters") + get_tree().get_nodes_in_group("cpu_runners")

func cap_under(body: Node3D) -> int:
	for i in caps.size():
		var p := rests[i].affine_inverse() * to_local(body.global_position)
		# 足元で判定し、壁の側面や通過中の空中キャラは数えない。
		if absf(p.x) <= lengths[i] * 0.5 + 0.05 and (absf(p.z) <= 0.65 or (i >= 80 and p.z >= 0.0 and p.z <= 4.25 - absf(p.x))) and p.y >= 0.05 and p.y <= 0.35:
			return i
	return -1

func _physics_process(delta: float) -> void:
	for i in ages.keys():
		ages[i] += delta
		var age: float = ages[i]
		var weight := minf(age / 0.35, 1.0) if age < 1.0 else maxf((DURATION - age) / 0.6, 0.0)
		caps[i].transform = rests[i] * Transform3D(Basis(Vector3.RIGHT, deg_to_rad(70.0) * weight), Vector3.ZERO)
		if age >= DURATION:
			caps[i].transform = rests[i]
			ages.erase(i)
	if not multiplayer.is_server():
		return
	var live := {}
	for body in actors():
		var id: int = body.get_instance_id()
		var index := cap_under(body)
		if index < 0 or absf(body.velocity.y) > 0.5:
			continue
		live[id] = true
		stays[id] = float(stays.get(id, 0.0)) + delta
		if stays[id] >= WAIT and not ages.has(index):
			stays.erase(id)
			if multiplayer.has_multiplayer_peer():
				tip.rpc(index)
			else:
				tip(index)
	for id in stays.keys():
		if not live.has(id):
			stays.erase(id)

@rpc("authority", "call_local", "reliable")
func tip(index: int) -> void:
	if index < 0 or index >= caps.size():
		return
	ages[index] = 0.0
	for body in actors():
		if body.is_multiplayer_authority() and cap_under(body) == index:
			# 内向き入力で壁の根元に戻れないよう、外向き速度を短時間保持する。
			body.launch(outward[index] * 8.0 + Vector3.UP * 1.5)
			body.hold_bumper_bounce(outward[index] * 8.0, 1.2)

