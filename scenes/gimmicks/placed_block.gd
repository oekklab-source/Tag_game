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
const SLIDE_COLLISION_LIFETIME := 5.0
const CAMERA_TRANSPARENCY := 0.68
const LOCAL_BOX := AABB(Vector3(-2.55, -0.1, -0.55), Vector3(5.1, 4.7, 1.1))

var _left := LIFETIME
var _slide_hit_reported := false
var _camera_obscured := false
var _material: StandardMaterial3D
var _base_color := Color.WHITE

@onready var mesh: MeshInstance3D = $Mesh


func _ready() -> void:
	add_to_group("placed_blocks")
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
	_left -= delta
	var fade := 0.0
	if _left < FADE:
		fade = clampf(1.0 - _left / FADE, 0.0, 0.95)
	_set_visual_transparency(maxf(
		fade, CAMERA_TRANSPARENCY if _camera_obscured else 0.0))
	if _left <= 0.0 and multiplayer.is_server():
		# サーバが消せば MultiplayerSpawner が全ピアの複製も消す
		queue_free()


## 滑走中のキャラクターが接触したピアから呼ぶ。消滅時刻を接触開始から
## 最大5秒後へ縮め、全ピアで既存の最終1秒フェードを同時に再利用する。
func report_slide_collision() -> void:
	if _slide_hit_reported:
		return
	_slide_hit_reported = true
	if multiplayer.is_server():
		_broadcast_slide_collision_expiry()
	else:
		_request_slide_collision_expiry.rpc_id(1)


@rpc("any_peer", "reliable")
func _request_slide_collision_expiry() -> void:
	if (multiplayer.is_server() and _left > SLIDE_COLLISION_LIFETIME
			and _valid_remote_slide_collision(multiplayer.get_remote_sender_id())):
		_broadcast_slide_collision_expiry()


func _valid_remote_slide_collision(sender_id: int) -> bool:
	# クライアントから任意のブロックを消せないよう、同期済みの位置と滑走姿勢を
	# サーバ側でも確認する。通信遅延分として当たり判定を1mだけ広げる。
	for node in get_tree().get_nodes_in_group("players"):
		if String(node.name).to_int() != sender_id:
			continue
		var body := node as Node3D
		if body == null or not LOCAL_BOX.grow(1.0).has_point(to_local(body.global_position)):
			return false
		var slide: Vector4 = node.get("sync_slide")
		return bool(node.get("diving")) or int(slide.x) > SlideRide.Phase.NONE
	return false


func _broadcast_slide_collision_expiry() -> void:
	_apply_slide_collision_expiry()
	if not multiplayer.get_peers().is_empty():
		_sync_slide_collision_expiry.rpc()


@rpc("authority", "reliable")
func _sync_slide_collision_expiry() -> void:
	_apply_slide_collision_expiry()


func _apply_slide_collision_expiry() -> void:
	_slide_hit_reported = true
	_left = minf(_left, SLIDE_COLLISION_LIFETIME)


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
