extends StaticBody3D

## 設置ブロック。一定時間だけ視線と通行を塞ぐ壁を作る。
##
## コリジョンは Platform レイヤー(8)。これで
##   - 視線を遮る（GameManager.SIGHT_MASK = World|Platform に含まれる）
##   - キャラの通行を塞ぐ（キャラの collision_mask に含まれる）
##   - ナビメッシュのベイク対象から外れる（geometry_collision_mask = 1）
## となる。ベイクに乗らないので CPU は経路上にあると押し付けられて止まるが、
## cpu_hunter.gd 側のスタック検知が横へ回り込ませる。

const LIFETIME := 15.0
const FADE := 1.0  # 消える直前に薄くして予告する
const CAMERA_TRANSPARENCY := 0.68
const SHATTER_DELAY := 1.0
const FRAGMENT_TIME := 1.0
const SLIDE_HIT_SPEED := 4.0
const FRAGMENT_COLS := 2
const FRAGMENT_ROWS := 4
const FRAGMENT_SIZE := Vector3(2.42, 1.05, 0.92)
const LOCAL_BOX := AABB(Vector3(-2.55, -0.1, -0.55), Vector3(5.1, 4.7, 1.1))

var _left := LIFETIME
var _camera_obscured := false
var _break_started := false
var _break_elapsed := 0.0
var _shattered := false
var _slide_tangent_local := Vector3.BACK
var _slide_normal_local := Vector3.UP
var _fragments: Array[MeshInstance3D] = []
var _fragment_starts: Array[Vector3] = []
var _fragment_targets: Array[Vector3] = []
var _fragment_rotations: Array[Quaternion] = []
var _material: StandardMaterial3D
var _base_color := Color.WHITE

@onready var impact_pivot: Node3D = $ImpactPivot
@onready var mesh: MeshInstance3D = $ImpactPivot/Mesh
@onready var solid_shape: CollisionShape3D = $Shape
@onready var hit_area: Area3D = $SlideHitArea


func _ready() -> void:
	add_to_group("placed_blocks")
	hit_area.body_entered.connect(_on_slide_hit)
	# GeometryInstance3D.transparency は実際のCompatibility描画で効かなかったため、
	# 壁ごとにマテリアルを複製し、アルファ値を直接変更する。
	var source := mesh.get_active_material(0) as StandardMaterial3D
	if source:
		_material = source.duplicate() as StandardMaterial3D
		_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_base_color = _material.albedo_color
		mesh.material_override = _material
	# 生成したフレームからカメラを通過させ、一瞬だけ寄る動きも起こさない。
	for node in get_tree().get_nodes_in_group("players"):
		if node.is_multiplayer_authority() and node.has_method("register_placed_block_camera"):
			node.register_placed_block_camera(self)


func _process(delta: float) -> void:
	if _break_started:
		var total_time := SHATTER_DELAY + FRAGMENT_TIME
		_break_elapsed = minf(_break_elapsed + delta, total_time)
		if not _shattered:
			var warning_progress := clampf(_break_elapsed / SHATTER_DELAY, 0.0, 1.0)
			var strength := 0.04 + warning_progress * 0.08
			impact_pivot.position.x = sin(warning_progress * TAU * 7.0) * strength
			impact_pivot.rotation.z = sin(warning_progress * TAU * 5.0) * 0.035
			_set_visual_transparency(
				CAMERA_TRANSPARENCY if _camera_obscured else 0.0)
			if _break_elapsed >= SHATTER_DELAY:
				_begin_fragments()
		else:
			var fragment_progress := clampf(
				(_break_elapsed - SHATTER_DELAY) / FRAGMENT_TIME, 0.0, 1.0)
			_update_fragments(fragment_progress)
		if _break_elapsed >= total_time and multiplayer.is_server():
			queue_free.call_deferred()
		return
	_left -= delta
	var fade := 0.0
	if _left < FADE:
		fade = clampf(1.0 - _left / FADE, 0.0, 0.95)
	_set_visual_transparency(maxf(
		fade, CAMERA_TRANSPARENCY if _camera_obscured else 0.0))
	if _left <= 0.0 and multiplayer.is_server():
		# サーバが消せば MultiplayerSpawner が全ピアの複製も消す
		queue_free()


## 滑走中のキャラクターが触れた時だけ、ホストが破砕開始を確定する。
## Area は実体より0.1mだけ広く、StaticBodyに止められる直前の接触を拾う。
func _on_slide_hit(body: Node3D) -> void:
	if not multiplayer.is_server() or _break_started:
		return
	var state = body.get("sync_slide")
	if not state is Vector4:
		return
	var phase := int((state as Vector4).x)
	if phase < SlideRide.Phase.ENTER or phase > SlideRide.Phase.PRONE:
		return
	var yaw := (state as Vector4).z
	var facing := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var downhill := -facing if phase in [SlideRide.Phase.REVERSE_FALL, SlideRide.Phase.PRONE] else facing
	var pitch := absf((state as Vector4).w)
	if multiplayer.has_multiplayer_peer():
		start_shatter.rpc(downhill.normalized(), pitch, body.get_path())
	else:
		start_shatter(downhill.normalized(), pitch, body.get_path())


## 全ピアで同じ予告と破片を再生する。実体は砕ける瞬間まで維持する。
@rpc("authority", "call_local", "reliable")
func start_shatter(downhill: Vector3, pitch: float, hitter: NodePath) -> void:
	if _break_started:
		return
	_break_started = true
	var tangent_world := (downhill * cos(pitch) + Vector3.DOWN * sin(pitch)).normalized()
	var normal_world := (Vector3.UP * cos(pitch) + downhill * sin(pitch)).normalized()
	_slide_tangent_local = (global_basis.inverse() * tangent_world).normalized()
	_slide_normal_local = (global_basis.inverse() * normal_world).normalized()
	hit_area.set_deferred("monitoring", false)
	var body := get_node_or_null(hitter) as CharacterBody3D
	if body == null or not body.is_multiplayer_authority():
		return
	var state = body.get("sync_slide")
	if not state is Vector4:
		return
	var phase := int((state as Vector4).x)
	if phase < SlideRide.Phase.ENTER or phase > SlideRide.Phase.PRONE:
		return
	var along := body.velocity.dot(downhill)
	if along > SLIDE_HIT_SPEED:
		body.velocity -= downhill * (along - SLIDE_HIT_SPEED)


func _begin_fragments() -> void:
	_shattered = true
	impact_pivot.position = Vector3.ZERO
	impact_pivot.rotation = Vector3.ZERO
	mesh.visible = false
	solid_shape.set_deferred("disabled", true)
	var fragment_mesh := BoxMesh.new()
	fragment_mesh.size = FRAGMENT_SIZE
	var side := _slide_normal_local.cross(_slide_tangent_local).normalized()
	var target_basis := Basis(side, _slide_normal_local, _slide_tangent_local).orthonormalized()
	var target_rotation := target_basis.get_rotation_quaternion()
	for row in FRAGMENT_ROWS:
		for col in FRAGMENT_COLS:
			var piece := MeshInstance3D.new()
			piece.name = "Fragment%d" % _fragments.size()
			piece.mesh = fragment_mesh
			piece.material_override = _material
			piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			var start := Vector3(
				(col + 0.5) * (5.0 / FRAGMENT_COLS) - 2.5,
				(row + 0.5) * (4.5 / FRAGMENT_ROWS), 0.0)
			var on_slope := start - _slide_normal_local * start.dot(_slide_normal_local)
			var index := _fragments.size()
			var distance := 1.8 + float(index % 3) * 0.35
			var scatter := (float((index * 5) % 7) - 3.0) * 0.12
			var target := (on_slope + _slide_tangent_local * distance
				+ side * scatter + _slide_normal_local * (FRAGMENT_SIZE.y * 0.5))
			piece.position = start
			add_child(piece)
			_fragments.append(piece)
			_fragment_starts.append(start)
			_fragment_targets.append(target)
			_fragment_rotations.append(target_rotation)


func _update_fragments(progress: float) -> void:
	var eased := smoothstep(0.0, 1.0, progress)
	for i in _fragments.size():
		var piece := _fragments[i]
		piece.position = _fragment_starts[i].lerp(_fragment_targets[i], eased)
		piece.quaternion = Quaternion.IDENTITY.slerp(_fragment_rotations[i], eased)
	_set_visual_transparency(maxf(
		0.95 * eased, CAMERA_TRANSPARENCY if _camera_obscured else 0.0))


func _set_visual_transparency(amount: float) -> void:
	if _material == null:
		return
	var color := _base_color
	color.a = 1.0 - clampf(amount, 0.0, 0.95)
	_material.albedo_color = color


func update_camera_obscured(target_position: Vector3, camera_position: Vector3) -> void:
	_camera_obscured = _segment_intersects_local_box(
		to_local(target_position), to_local(camera_position))


func _segment_intersects_local_box(from: Vector3, to: Vector3) -> bool:
	var direction := to - from
	var box_min := LOCAL_BOX.position
	var box_max := LOCAL_BOX.end
	var t_min := 0.0
	var t_max := 1.0
	for axis in 3:
		if absf(direction[axis]) < 0.00001:
			if from[axis] < box_min[axis] or from[axis] > box_max[axis]:
				return false
			continue
		var inv := 1.0 / direction[axis]
		var t1 := (box_min[axis] - from[axis]) * inv
		var t2 := (box_max[axis] - from[axis]) * inv
		if t1 > t2:
			var swap := t1
			t1 = t2
			t2 = swap
		t_min = maxf(t_min, t1)
		t_max = minf(t_max, t2)
		if t_min > t_max:
			return false
	return true
