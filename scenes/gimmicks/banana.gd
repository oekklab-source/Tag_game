extends Area3D

## バナナ。踏んだキャラが一定時間転倒して操作不能になる。
##
## 被弾はサーバが決めて RPC で配信する（？ブロックと同じ形）。
## 効果の適用は被害者の権威ピアだけが行い、削除はサーバが行って
## MultiplayerSpawner に全ピアへ伝えさせる。

const STUN := 1.5
const LIFETIME := 30.0  # 拾われないまま残り続けないように自然消滅させる
const FLOOR_MASK := 9   # World(1) + Platform(8)。床・滑り台・置き壁に着地する
const FLOOR_PROBE := 0.08
const THROW_GRAVITY := 9.30  # 速度1.5倍で約16m・最高点約4mになる投げ専用重力

var _used := false
var _landed := false
var launch_velocity := Vector3.ZERO
var thrower_peer_id := -1
var _velocity := Vector3.ZERO


func _ready() -> void:
	_velocity = launch_velocity
	body_entered.connect(_on_body_entered)
	if multiplayer.is_server():
		await get_tree().create_timer(LIFETIME).timeout
		if is_inside_tree() and not _used:
			queue_free()


func _process(delta: float) -> void:
	rotate_y(delta * 2.0)  # 目印になるよう回しておく


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server() or _used or _landed:
		return
	var gravity := THROW_GRAVITY if thrower_peer_id >= 0 \
		else float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	_velocity.y -= gravity * delta
	var next := global_position + _velocity * delta
	var q := PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0.0, FLOOR_PROBE, 0.0),
		next - Vector3(0.0, FLOOR_PROBE, 0.0),
		FLOOR_MASK)
	q.collide_with_areas = false
	q.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		global_position = next
	elif hit.normal.y < 0.55:
		# 壁へ当たったら貫通させず、水平速度を失ってその場から落下する。
		global_position = hit.position + hit.normal * FLOOR_PROBE
		_velocity.x = 0.0
		_velocity.z = 0.0
	else:
		global_position = hit.position
		_velocity = Vector3.ZERO
		_landed = true


func _on_body_entered(body: Node3D) -> void:
	if not multiplayer.is_server() or _used:
		return
	if not body.has_method("apply_stun"):
		return
	if not _landed and thrower_peer_id >= 0 \
			and String(body.name).to_int() == thrower_peer_id:
		return
	_used = true
	_hit.rpc(body.get_path())


## ノード名はピア間で一致する（プレイヤー=peer_id / CPU=CPUn）ため NodePath で被害者を指せる
@rpc("authority", "call_local", "reliable")
func _hit(victim: NodePath) -> void:
	_used = true
	visible = false
	var b := get_node_or_null(victim)
	if b and b.has_method("apply_stun") and b.is_multiplayer_authority():
		b.apply_stun(STUN)
	if multiplayer.is_server():
		# サーバが消せば MultiplayerSpawner が全ピアの複製も消す
		queue_free.call_deferred()
