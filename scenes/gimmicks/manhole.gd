extends Area3D

## マンホールのワープ。ペアのマンホールのフタが開いて、そこから飛び出す。
##
## 以前は土管だった。土管は collision_layer=1 の StaticBody3D だったので
## ナビメッシュに半径 2.3m の穴を空けており、CPU はそこを迂回していた。
## マンホールはフタが地面と面一で静的コリジョンを持たないため穴が空かず、
## CPU も人も普通に上を歩ける。代わりに「踏んだら即ワープ」になるので、
## 判定はフタの上（半径1.1m）だけに絞ってある。
##
## 地面と同じ高さになると遠くから見つけられなくなるので、モデル
## （assets/props/manhole.glb）に光柱・回転リング・舞う結晶を含めてある。
##
## 効果の適用は「そのボディの権威ピア」に限定する。ワープ後の位置は
## 既存の位置レプリケーションで他ピアへ伝わるため RPC は不要。

const EXIT_HEIGHT := 1.0   # 出口のフタからどれだけ高い位置に出すか
const EXIT_UP := 6.0       # 飛び出す勢い
## 出口で足す水平方向の勢い。真上にしか飛ばさないと、入った時と同じ座標へ
## そのまま落ちてくる。空中では横移動が弱い（AIR_ACCEL）ので、無入力だと
## warp_lock(0.9s) が切れる前後で同じフタへ戻って再突入し、無限ループになる。
## 「進行方向」に軽く逃がしておけば、無操作でも判定の外へ着地する
const EXIT_FORWARD := 4.0
const CPU_EXIT_OFFSET := 4.0
## CPU は「今向かっている場所までの距離がこれ以上短くなる」時だけ入る。
## そうしないと単に近くを通っただけで意味なくワープしてしまう。
## 基準は逃走者ではなく CPU の目的地であること — 逃走者を基準にすると、
## 位置を知らないはずの CPU が逃走者に引き寄せられる（全知の抜け道になる）
const CPU_SHORTCUT_MIN := 15.0

## フタが開く角度。Lid は原点がヒンジ（枠の内縁）に置いてあるので、
## rotation.x を回すだけで開く（build_manhole.py で仕込んである）
const LID_OPEN := -110.0
const HALO_SPIN := 0.8  # 回転リングの角速度(rad/s)

const BEACON_SHADER := preload("res://scenes/beacon.gdshader")
## 加算合成は淡い空の上で白く寄るので、彩度を高めにとって水色に見えるようにする
const GLOW_COLOR := Color(0.38, 0.80, 1.0)

var pair: Node3D  # 対になるマンホール（WorldBuilder が生成時に相互設定する）

var _lid: Node3D
var _halo: Node3D
var _shards: Node3D
var _lid_tween: Tween


func _ready() -> void:
	var model: Node3D = $Model
	_lid = model.find_child("Lid", true, false)
	_halo = model.find_child("Halo", true, false)
	_shards = model.find_child("Shards", true, false)
	# glb のマテリアルは Principled BSDF 由来の不透明材なので、そのままだと
	# 光柱が「灰色の円錐」にしか見えない。加算合成の自発光へ差し替える
	# 光柱は遠景で見つけてもらうのが役目なので、結晶より強く光らせる
	_glow(model.find_child("Beacon", true, false), 1.3, 14.0, 0.0, 0.35)
	_glow(_shards, 1.0, 0.0, 0.25, 0.0)
	_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body_entered.connect(_on_body_entered)


func _process(delta: float) -> void:
	# 目印をゆっくり回して「生きている」と分からせる。当たり判定が無いので
	# 全ピアで揃える必要がなく、各ピアの delta のままでよい
	_halo.rotate_y(delta * HALO_SPIN)
	_shards.rotate_y(delta * -HALO_SPIN * 0.55)


func _glow(node: GeometryInstance3D, energy: float, fade_height: float, bob: float,
		stripe: float) -> void:
	var m := ShaderMaterial.new()
	m.shader = BEACON_SHADER
	m.set_shader_parameter("albedo", GLOW_COLOR)
	m.set_shader_parameter("energy", energy)
	m.set_shader_parameter("fade_height", fade_height)
	m.set_shader_parameter("bob", bob)
	m.set_shader_parameter("stripe", stripe)
	node.material_override = m
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _on_body_entered(body: Node3D) -> void:
	if pair == null or not body.has_method("warp_to") or not body.is_multiplayer_authority():
		return
	if body.warp_lock > 0.0:
		return  # 出口側のマンホールで即座に戻ってしまうのを防ぐ
	if _is_cpu(body) and not _cpu_wants(body):
		return
	# 演出は入口と出口の両方で要るが、発動できるかを判断できるのは権威ピアだけ
	# （warp_lock も _cpu_wants も権威ピアにしか無い状態）。spring_pad のように
	# 各ピアが独立に判断すると演出だけが食い違うので、question_block と同じく
	# RPC で配る。出口側のフタは、出現位置が判定の外に出ると body_entered が
	# 鳴らないため、pair を明示的に叩く必要もある。
	# 発火元はホストではなく「そのボディの権威ピア」= クライアントでありうるので "any_peer"
	rpc(&"_burst")
	pair.rpc(&"_burst")
	# 「進行方向」= 入った時に実際に動いていた向き。移動していなければ
	# 向いている方向で代える（直立で踏んでも真上だけには飛ばさない）
	var vel_flat := Vector3(body.velocity.x, 0.0, body.velocity.z)
	var dir := (vel_flat.normalized() if vel_flat.length() > 0.5
		else -body.global_transform.basis.z)
	if _is_cpu(body):
		dir = _cpu_exit_dir(body, dir)
		body.warp_to(pair.global_position + dir * CPU_EXIT_OFFSET + Vector3(0, EXIT_HEIGHT, 0),
			EXIT_UP, dir * EXIT_FORWARD)
	else:
		body.warp_to(pair.global_position + Vector3(0, EXIT_HEIGHT, 0), EXIT_UP,
			dir * EXIT_FORWARD)


## フタをバタンと開いて閉じる。ノードパスがピア間で一致することが前提
## （WorldBuilder が Manhole%d と明示的に名前を振っている）
@rpc("any_peer", "call_local", "reliable")
func _burst() -> void:
	if _lid_tween != null and _lid_tween.is_valid():
		_lid_tween.kill()  # 連続で踏まれた時に2本の Tween がフタを取り合わないように
	_lid_tween = create_tween()
	_lid_tween.tween_property(_lid, "rotation:x", deg_to_rad(LID_OPEN), 0.12) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_lid_tween.tween_property(_lid, "rotation:x", 0.0, 0.45) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _is_cpu(body: Node3D) -> bool:
	return body.is_in_group("cpu_hunters") or body.is_in_group("cpu_runners")


func _cpu_exit_dir(cpu: Node3D, fallback: Vector3) -> Vector3:
	if cpu.has_method("get_ai_goal"):
		var to_goal: Vector3 = cpu.get_ai_goal() - pair.global_position
		to_goal.y = 0.0
		if to_goal.length() > 0.1:
			return to_goal.normalized()
	fallback.y = 0.0
	return fallback.normalized() if fallback.length() > 0.1 else Vector3.FORWARD


func _cpu_wants(cpu: Node3D) -> bool:
	if not cpu.has_method("get_ai_goal"):
		return false
	var goal: Vector3 = cpu.get_ai_goal()
	var here := global_position.distance_to(goal)
	var there := pair.global_position.distance_to(goal)
	return here - there >= CPU_SHORTCUT_MIN
