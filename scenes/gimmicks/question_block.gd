extends Area3D

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
## フタが跳ね上がって箱ごと消えるまで。RESPAWN から差し引くので復活周期は変わらない
const OPEN_TIME := 0.42

var _active := true

@onready var model: Node3D = $Model
@onready var _shape: CollisionShape3D = $Shape

## glb の Base(下箱+リボン下部) / Lid(フタ+リボン上部+蝶結び)。
## Lid は原点がフタ中心にあるので、回すとその場で傾く
var _base: Node3D
var _lid: Node3D
var _base_home: Transform3D
var _lid_home: Transform3D
var _model_scale := Vector3.ONE


func _ready() -> void:
	_model_scale = model.scale
	_base = model.find_child("Base", true, false)
	_lid = model.find_child("Lid", true, false)
	if _base != null:
		_base_home = _base.transform
	if _lid != null:
		_lid_home = _lid.transform
	body_entered.connect(_on_touch)


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
	_active = false  # 回転を止め、演出中の再取得も塞ぐ
	# アイテムは触れた時点で渡す（演出の完了を待たせない）
	var b := get_node_or_null(taker)
	if b and b.has_method("give_item") and b.is_multiplayer_authority():
		b.give_item(item)
	# 開封中は見た目も当たり判定も残す。先に消すと「無い物にぶつかる」の逆で
	# 「見えている物をすり抜ける」ことになる
	await _open()
	if not is_inside_tree():
		return
	_set_present(false)
	await get_tree().create_timer(RESPAWN - OPEN_TIME).timeout
	if not is_inside_tree():
		return  # 復活待ちの間にシーンが破棄された場合
	_reset_parts()
	_active = true
	_set_present(true)
	_pop_in()


## フタが跳ね上がって開き、そのあと箱ごと縮んで消える。
## 演出は全ピアで走る（_pop が call_local）。
func _open() -> void:
	if _base == null or _lid == null:
		# glb が旧構成（1メッシュ）の場合。演出は諦めて尺だけ合わせる
		await get_tree().create_timer(OPEN_TIME).timeout
		return
	var t := create_tween().set_parallel(true)
	# ため：一度沈んでから跳ね上がる。フタが飛ぶ勢いの理由になる
	t.tween_property(_base, "scale", Vector3(1.15, 0.80, 1.15), 0.07)
	t.tween_property(_base, "scale", Vector3(0.94, 1.08, 0.94), 0.12) \
		.set_delay(0.07).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# フタは跳ねと同時に飛び出し、傾きながら回る
	t.tween_property(_lid, "position", _lid_home.origin + Vector3(0, 1.1, 0), 0.26) \
		.set_delay(0.07).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(_lid, "rotation", Vector3(0.5, 2.2, 0.35), 0.30).set_delay(0.07)
	# 開ききったところで両方すぼめて消す
	for part in [_base, _lid]:
		t.tween_property(part, "scale", Vector3.ZERO, 0.14) \
			.set_delay(0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	await t.finished


## 復活時のポン。箱ごと膨らませるので Model を動かす（Base/Lid は姿勢を戻した直後）
func _pop_in() -> void:
	model.scale = Vector3.ZERO
	create_tween().tween_property(model, "scale", _model_scale, 0.25) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _reset_parts() -> void:
	if _base != null:
		_base.transform = _base_home
	if _lid != null:
		_lid.transform = _lid_home


## 取られている間は箱ごと消す。判定シェイプも一緒に切っておかないと
## 見えない箱に触れて再抽選が起きてしまう
## （body_entered の最中に触るので deferred で反映させる）
func _set_present(on: bool) -> void:
	model.visible = on
	_shape.set_deferred("disabled", not on)
