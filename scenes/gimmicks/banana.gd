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

var _used := false
var _fall_velocity := 0.0
var _landed := false


func _ready() -> void:
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
	var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	_fall_velocity -= gravity * delta
	var next := global_position + Vector3(0.0, _fall_velocity * delta, 0.0)
	var q := PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0.0, FLOOR_PROBE, 0.0),
		next - Vector3(0.0, FLOOR_PROBE, 0.0),
		FLOOR_MASK)
	q.collide_with_areas = false
	q.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		global_position = next
	else:
		global_position = hit.position
		_fall_velocity = 0.0
		_landed = true


func _on_body_entered(body: Node3D) -> void:
	if not multiplayer.is_server() or _used:
		return
	if not body.has_method("apply_stun"):
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
