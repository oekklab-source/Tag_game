extends Area3D

## 光の柱によるワープポータル。ペアの光の柱へ飛び出す。
##
## 地面にマンホール等の物理的な障害物や静的コリジョンを持たず、
## ナビメッシュに穴を空けないため、CPU もプレイヤーも普通に通過・利用できる。
## 遠くからでも見つけられるよう、天へ伸びる光柱・舞う結晶で構成されている。
##
## 効果の適用は「そのボディの権威ピア」に限定する。ワープ後の位置は
## 既存の位置レプリケーションで他ピアへ伝わるため RPC は不要。

const EXIT_HEIGHT := 1.0   # 出口からどれだけ高い位置に出すか
const EXIT_UP := 6.0       # 飛び出す勢い
## 出口で足す水平方向の勢い。真上にしか飛ばさないと、入った時と同じ座標へ
## そのまま落ちてくる。空中では横移動が弱い（AIR_ACCEL）ので、無入力だと
## warp_lock(0.9s) が切れる前後で同じ地点へ戻って再突入し、無限ループになる。
## 「進行方向」に軽く逃がしておけば、無操作でも判定の外へ着地する
const EXIT_FORWARD := 4.0
const CPU_EXIT_OFFSET := 4.0
## CPU は「今向かっている場所までの距離がこれ以上短くなる」時だけ入る。
## そうしないと単に近くを通っただけで意味なくワープしてしまう。
## 基準は逃走者ではなく CPU の目的地であること — 逃走者を基準にすると、
## 位置を知らないはずの CPU が逃走者に引き寄せられる（全知の抜け道になる）
const CPU_SHORTCUT_MIN := 15.0

const SHARDS_SPIN := 0.44  # 舞う結晶の角速度(rad/s)
const BEACON_ENERGY_DEFAULT := 1.3
const BEACON_ENERGY_BURST := 3.8

const BEACON_SHADER := preload("res://scenes/beacon.gdshader")
## 加算合成は淡い空の上で白く寄るので、彩度を高めにとって水色に見えるようにする
const GLOW_COLOR := Color(0.38, 0.80, 1.0)

var pair: Node3D  # 対になるワープポータル（WorldBuilder が生成時に相互設定する）

var _beacon: GeometryInstance3D
var _shards: Node3D
var _beacon_mat: ShaderMaterial
var _burst_tween: Tween


func _ready() -> void:
	var model: Node3D = $Model
	_shards = model.find_child("Shards", true, false)
	_beacon = model.find_child("Beacon", true, false)
	# glb のマテリアルは Principled BSDF 由来の不透明材なので、加算合成の自発光シェーダへ差し替える
	# 光柱は遠景で見つけてもらうのが役目なので、結晶より強く光らせる
	if _beacon != null:
		_beacon_mat = _glow(_beacon, BEACON_ENERGY_DEFAULT, 14.0, 0.0, 0.35)
	if _shards is GeometryInstance3D:
		_glow(_shards as GeometryInstance3D, 1.0, 0.0, 0.25, 0.0)
	body_entered.connect(_on_body_entered)


func _process(delta: float) -> void:
	# 目印をゆっくり回して「生きている」と分からせる。当たり判定が無いので
	# 全ピアで揃える必要がなく、各ピアの delta のままでよい
	if _shards != null:
		_shards.rotate_y(delta * -SHARDS_SPIN)


## 自発光シェーダマテリアルを生成して適用する
func _glow(node: GeometryInstance3D, energy: float, fade_height: float, bob: float,
		stripe: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = BEACON_SHADER
	m.set_shader_parameter("albedo", GLOW_COLOR)
	m.set_shader_parameter("energy", energy)
	m.set_shader_parameter("fade_height", fade_height)
	m.set_shader_parameter("bob", bob)
	m.set_shader_parameter("stripe", stripe)
	node.material_override = m
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return m


func _on_body_entered(body: Node3D) -> void:
	if pair == null or not body.has_method("warp_to") or not body.is_multiplayer_authority():
		return
	if body.warp_lock > 0.0:
		return  # 出口側で即座に戻ってしまうのを防ぐ
	if _is_cpu(body) and not _cpu_wants(body):
		return
	# 演出は入口と出口の両方で要るが、発動できるかを判断できるのは権威ピアだけ
	# （warp_lock も _cpu_wants も権威ピアにしか無い状態）。spring_pad のように
	# 各ピアが独立に判断すると演出だけが食い違うので、RPC で配る。
	# 出口側は出現位置が判定の外に出ると body_entered が鳴らないため、pair を明示的に叩く。
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


## ワープ発動時の光パルス演出。ノードパスがピア間で一致することが前提
## （WorldBuilder が Manhole%d と明示的に名前を振っている）
@rpc("any_peer", "call_local", "reliable")
func _burst() -> void:
	if _burst_tween != null and _burst_tween.is_valid():
		_burst_tween.kill()
	_burst_tween = create_tween()

	# 光柱の発光強度を一瞬跳ね上げてから徐々に元の輝きに戻す
	if _beacon_mat != null:
		_beacon_mat.set_shader_parameter("energy", BEACON_ENERGY_BURST)
		_burst_tween.tween_method(
			func(val: float) -> void: _beacon_mat.set_shader_parameter("energy", val),
			BEACON_ENERGY_BURST, BEACON_ENERGY_DEFAULT, 0.45
		).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	# 舞う結晶を一瞬ふわっと広げて余韻を残すパルス演出
	if _shards != null:
		_shards.scale = Vector3.ONE * 1.25
		_burst_tween.parallel().tween_property(_shards, "scale", Vector3.ONE, 0.45) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


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
