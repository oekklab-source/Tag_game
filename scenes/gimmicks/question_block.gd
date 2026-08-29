extends StaticBody3D

## アイテムボックス（プレゼント箱）。触れるとアイテムを1つ渡し、一定時間後に復活する。
##
## 6つのギミックの中で唯一サーバ権威。抽選結果を全ピアで一致させる必要があるため、
## ホストがアイテムと取得者を決めて RPC で配信する（見た目の切り替えも RPC 側で行う）。
##
## CPU 鬼も取る。以前は「挙動が読めなくなる」として除外していたが、
## 逃走者だけが妨害手段を持つのは非対称で、鬼が弱すぎる原因でもあった。
## CPU の使いどころは cpu_hunter.gd の _try_use_item に集約してあり、
## 「先回りできている時だけ置く」ので読めない動きにはならない。

const RESPAWN := 12.0

var _active := true

@onready var model: Node3D = $Model
@onready var _shape: CollisionShape3D = $Shape


func _ready() -> void:
	$Touch.body_entered.connect(_on_touch)


func _process(delta: float) -> void:
	if _active:
		# ふわふわ回して「取れる物」だと分かるようにする
		model.rotate_y(delta * 1.2)


func _on_touch(body: Node3D) -> void:
	if not multiplayer.is_server() or not _active:
		return
	if not body.has_method("give_item"):
		return
	# Item.NONE(0) を除いた ROCKET / BANANA / BLOCK から抽選する
	_pop.rpc(1 + randi() % 3, body.get_path())


## ノード名はピア間で一致する（プレイヤー=peer_id / CPU=CPUn を
## MultiplayerSpawner が名前ごと複製する）ため NodePath で取得者を指せる
@rpc("authority", "call_local", "reliable")
func _pop(item: int, taker: NodePath) -> void:
	_active = false
	_set_present(false)
	var b := get_node_or_null(taker)
	if b and b.has_method("give_item") and b.is_multiplayer_authority():
		b.give_item(item)
	await get_tree().create_timer(RESPAWN).timeout
	if not is_inside_tree():
		return  # 復活待ちの間にシーンが破棄された場合
	_active = true
	_set_present(true)


## 取られている間は箱ごと消す。見えないだけで壁として残ると
## 「無い物にぶつかる」ので、本体の当たり判定も一緒に切る
## （body_entered の最中に触るので deferred で反映させる）
func _set_present(on: bool) -> void:
	model.visible = on
	_shape.set_deferred("disabled", not on)
