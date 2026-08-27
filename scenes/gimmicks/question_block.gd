extends StaticBody3D

## アイテムボックス（プレゼント箱）。触れるとアイテムを1つ渡し、一定時間後に復活する。
##
## 6つのギミックの中で唯一サーバ権威。抽選結果を全ピアで一致させる必要があるため、
## ホストがアイテムと取得者を決めて RPC で配信する（見た目の切り替えも RPC 側で行う）。
##
## CPU は反応しない。妨害アイテムを持たせると挙動が読めなくなるため
## （ただし置かれたバナナは CPU も踏む）。

const RESPAWN := 12.0

var _active := true
var _used_mat: Material

@onready var model: Node3D = $Model
@onready var _body: GeometryInstance3D = model.find_child("Body", true, false)


func _ready() -> void:
	# item_box.glb は包装紙・リボンと複数の色を持つので、元のマテリアルを
	# 複製して暗くするのではなく、material_override で全サーフェスを
	# 一括で単色に差し替える（未取得中の見た目に戻すのも null を戻すだけでよい）
	_used_mat = StandardMaterial3D.new()
	_used_mat.albedo_color = Color(0.42, 0.28, 0.16)
	$Touch.body_entered.connect(_on_touch)


func _process(delta: float) -> void:
	if _active:
		# ふわふわ回して「取れる物」だと分かるようにする
		model.rotate_y(delta * 1.2)


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
	_body.material_override = _used_mat
	var b := get_node_or_null(taker)
	if b and b.has_method("give_item") and b.is_multiplayer_authority():
		b.give_item(item)
	await get_tree().create_timer(RESPAWN).timeout
	if not is_inside_tree():
		return  # 復活待ちの間にシーンが破棄された場合
	_active = true
	_body.material_override = null
