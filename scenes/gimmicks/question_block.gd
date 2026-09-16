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
## フタが跳ね上がってキラキラが消えきるまで。RESPAWN から差し引くので復活周期は変わらない
const OPEN_TIME := 0.66

const BEACON_SHADER := preload("res://scenes/beacon.gdshader")
## 開封エフェクトの色。リボン(0.99,0.93,0.80)に寄せた金〜クリーム白。
## 加算合成は明るい床の上で白へ寄るので、彩度を高めに取っておく
const SPARK_COLOR := Color(1.0, 0.82, 0.38)

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

## 開封の瞬間だけ出るキラキラ。Burst=足元へ広がる光の輪、Confetti=外へ舞う紙吹雪。
## どちらも glb 同梱の静的メッシュで、ふだんは隠してある
var _burst: GeometryInstance3D
var _confetti: GeometryInstance3D
var _burst_mat: ShaderMaterial
var _confetti_mat: ShaderMaterial
var _burst_home: Transform3D
var _confetti_home: Transform3D


func _ready() -> void:
	_model_scale = model.scale
	_base = model.find_child("Base", true, false)
	_lid = model.find_child("Lid", true, false)
	if _base != null:
		_base_home = _base.transform
	if _lid != null:
		_lid_home = _lid.transform
	_burst = model.find_child("Burst", true, false) as GeometryInstance3D
	_confetti = model.find_child("Confetti", true, false) as GeometryInstance3D
	if _burst != null:
		_burst_home = _burst.transform
		# 輪は板1枚なので揺らさない。広がる速さだけで見せる
		_burst_mat = _glow(_burst, 1.6, 0.0)
	if _confetti != null:
		_confetti_home = _confetti.transform
		# 紙片は黄金角に散らしてあるので、bob を入れると1枚ずつばらけて舞う
		_confetti_mat = _glow(_confetti, 1.3, 0.14)
	body_entered.connect(_on_touch)


func _process(delta: float) -> void:
	if _active:
		# ふわふわ回して「取れる物」だと分かるようにする
		model.rotate_y(delta * 1.2)
	elif _confetti != null and _confetti.visible:
		# 舞っている間だけ紙吹雪を回す。装飾なので各ピアの delta のままでよい
		_confetti.rotate_y(delta * 1.6)


## glb の不透明材を加算合成の自発光シェーダへ差し替える（manhole.gd の同名ヘルパと同じ形）。
## ふだんは出さない飾りなので、隠した状態で返す
func _glow(node: GeometryInstance3D, energy: float, bob: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = BEACON_SHADER
	m.set_shader_parameter("albedo", SPARK_COLOR)
	m.set_shader_parameter("energy", energy)
	m.set_shader_parameter("fade_height", 0.0)
	m.set_shader_parameter("bob", bob)
	m.set_shader_parameter("stripe", 0.0)
	m.set_shader_parameter("fade", 1.0)
	node.material_override = m
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visible = false
	return m


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


## フタが跳ね上がって開き、光の輪と紙吹雪が散り、そのあと箱ごと縮んで消える。
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
	t.tween_property(_lid, "position", _lid_home.origin + Vector3(0, 1.5, 0), 0.26) \
		.set_delay(0.07).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(_lid, "rotation", Vector3(0.9, 3.4, 0.6), 0.30).set_delay(0.07)
	_add_sparkle(t)
	# 開ききったところで両方すぼめて消す。
	# キラキラはここでは消さない。箱が先に消え、そのあと紙吹雪だけが
	# 舞って消えるのが一番「開いた」ように見える
	for part in [_base, _lid]:
		t.tween_property(part, "scale", Vector3.ZERO, 0.14) \
			.set_delay(0.34).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	await t.finished


## 開封 Tween に光の輪と紙吹雪を相乗りさせる。どちらもフタが飛ぶのと同時（0.07s）に出す
func _add_sparkle(t: Tween) -> void:
	if _burst != null:
		_burst.visible = true
		_burst.transform = _burst_home
		_burst.scale = Vector3(0.35, 1.0, 0.35)
		_burst_mat.set_shader_parameter("fade", 1.0)
		# 輪は素早く外へ抜けきる。長く残すと「輪っかが置いてある」ように見える
		t.tween_property(_burst, "scale", Vector3(2.2, 1.0, 2.2), 0.34) \
			.set_delay(0.07).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		# 広がりきる間は明るさを保ち、最後だけ抜く。広がりと同時に薄めていくと、
		# 光が同じ量のまま円周に引き伸ばされるので、一番大きい時が一番地味になる
		t.tween_method(_set_burst_fade, 1.0, 0.0, 0.20).set_delay(0.21)
	if _confetti != null:
		_confetti.visible = true
		_confetti.transform = _confetti_home
		_confetti.scale = Vector3.ONE * 0.25
		_confetti_mat.set_shader_parameter("fade", 1.0)
		# 外へ広がりながら舞い上がる
		t.tween_property(_confetti, "scale", Vector3.ONE * 1.9, 0.59) \
			.set_delay(0.07).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		t.tween_property(_confetti, "position", _confetti_home.origin + Vector3(0, 1.0, 0), 0.59) \
			.set_delay(0.07).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		# 輪より遅れて消す。箱が消えたあとも紙吹雪だけが残って余韻になる。
		# 0.42 + 0.24 = OPEN_TIME。この枝が演出の一番長い枝になる
		t.tween_method(_set_confetti_fade, 1.0, 0.0, 0.24).set_delay(0.42)


## tween_method はメソッド参照しか取れないので、シェーダパラメータ用に1つずつ包む
func _set_burst_fade(v: float) -> void:
	_burst_mat.set_shader_parameter("fade", v)


func _set_confetti_fade(v: float) -> void:
	_confetti_mat.set_shader_parameter("fade", v)


## 復活時のポン。箱ごと膨らませるので Model を動かす（Base/Lid は姿勢を戻した直後）
func _pop_in() -> void:
	model.scale = Vector3.ZERO
	create_tween().tween_property(model, "scale", _model_scale, 0.25) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## 姿勢を初期状態へ戻す。キラキラも隠して fade を戻しておかないと、
## 2回目の開封で「消えたまま」の紙吹雪が出て何も見えなくなる
func _reset_parts() -> void:
	if _base != null:
		_base.transform = _base_home
	if _lid != null:
		_lid.transform = _lid_home
	if _burst != null:
		_burst.transform = _burst_home
		_burst.visible = false
		_burst_mat.set_shader_parameter("fade", 1.0)
	if _confetti != null:
		_confetti.transform = _confetti_home
		_confetti.visible = false
		_confetti_mat.set_shader_parameter("fade", 1.0)


## 取られている間は箱ごと消す。判定シェイプも一緒に切っておかないと
## 見えない箱に触れて再抽選が起きてしまう
## （body_entered の最中に触るので deferred で反映させる）
func _set_present(on: bool) -> void:
	model.visible = on
	_shape.set_deferred("disabled", not on)
	if not on:
		# 消える時点でキラキラは散りきっている。ここで隠しておかないと
		# 復活を待つ11秒の間、見えない紙吹雪を回し続けることになる
		if _burst != null:
			_burst.visible = false
		if _confetti != null:
			_confetti.visible = false
