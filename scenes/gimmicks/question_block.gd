extends StaticBody3D

## ？ブロック。触れるとアイテムを1つ渡し、一定時間後に復活する。
##
## 6つのギミックの中で唯一サーバ権威。抽選結果を全ピアで一致させる必要があるため、
## ホストがアイテムと取得者を決めて RPC で配信する（見た目の切り替えも RPC 側で行う）。
##
## CPU は反応しない。妨害アイテムを持たせると挙動が読めなくなるため
## （ただし置かれたバナナは CPU も踏む）。

const RESPAWN := 12.0

var _active := true
var _fresh_mat: Material
var _used_mat: Material

@onready var mesh: MeshInstance3D = $Mesh
@onready var mark: Label3D = $Mark


func _ready() -> void:
	_fresh_mat = mesh.mesh.material
	_used_mat = _fresh_mat.duplicate()
	_used_mat.albedo_color = Color(0.42, 0.28, 0.16)
	_used_mat.emission = Color(0.42, 0.28, 0.16)
	_used_mat.emission_energy_multiplier = 0.1
	$Touch.body_entered.connect(_on_touch)


func _process(delta: float) -> void:
	if _active:
		# ふわふわ回して「取れる物」だと分かるようにする
		mesh.rotate_y(delta * 1.2)


func _on_touch(body: Node3D) -> void:
	if not multiplayer.is_server() or not _active:
		return
	if not body.has_method("give_item") or body.is_in_group("cpu_hunters"):
		return
	# Item.NONE(0) を除いた ROCKET / BANANA / BLOCK から抽選する
	_pop.rpc(1 + randi() % 3, body.get_path())


## ノード名はピア間で一致する（プレイヤー=peer_id / CPU=CPUn を
## MultiplayerSpawner が名前ごと複製する）ため NodePath で取得者を指せる
@rpc("authority", "call_local", "reliable")
func _pop(item: int, taker: NodePath) -> void:
	_active = false
	mesh.material_override = _used_mat
	mark.visible = false
	var b := get_node_or_null(taker)
	if b and b.has_method("give_item") and b.is_multiplayer_authority():
		b.give_item(item)
	await get_tree().create_timer(RESPAWN).timeout
	if not is_inside_tree():
		return  # 復活待ちの間にシーンが破棄された場合
	_active = true
	mesh.material_override = _fresh_mat
	mark.visible = true
