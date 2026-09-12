extends Area3D

## ダッシュパネル（レインボーロードのダッシュ板）。8m 角の正方形。
## 踏むと**その人自身の進行方向へ**蹴り出し、一定時間のスピードアップを与える。
##
## ベルトコンベアだった頃は搬送方向が固定で、逆から入ると押し戻されて
## 通り抜けられなかった。今は蹴り出す向きを踏んだ人から取るので、
## **四方どこから乗っても素通りでき、必ず自分の行きたい方へ加速する。**
## パネル自身の向き（-Z）は、止まったまま乗られた時の最後の保険にしか使わない。
## 逃走者も鬼も同じように使える対称ギミック。
##
## **正方形で、山型（シェブロン）も四方ぶん置いてある**のはこのため。
## 5m x 10m の長方形だと「長い方が正面」に見えて仕様と食い違う。
## 片方向の矢印にすると、逆から乗った人が「矢印と逆へ加速する」ことになり、
## 見た目が仕様に嘘をつく。
##
## body_entered は全ピアで発火するため、効果の適用は必ず
## 「そのボディの権威ピア」に限定する（見た目の脈動と火花は全ピアで動かす）。

const BOOST_MULT := 2.0
const BOOST_TIME := 3.0
const KICK := 7.0
## 進行方向とみなす下限。これを割ったら本人の向きへ蹴る。
## 真上から落ちてきた人・止まって乗った人を明後日の方向へ飛ばさないため
const MIN_SPEED := 1.0

const BEACON_SHADER := preload("res://scenes/beacon.gdshader")

## 虹の段は中心（Wave0）から外側へ番号が振ってある。
## 段は中心の板 → 四方の山型4段 → 外周の枠、と形が変わるが、
## **番号 = 中心からの距離**なので、位相を番号ぶん遅らせれば
## 光の波が中心から四方へ同時に広がる。
## 「どちらへ蹴るか」を持たない見た目にするための形で、
## ここを負にすると波が内向きになり、吸い込まれる板に見えてしまう
const WAVE_SPEED := 6.0
const WAVE_STEP := 0.85
const PULSE_MIN := 0.25
const PULSE_MAX := 1.60
## 風の筋は虹の段の半歩ぶん先を走らせる。同位相だと段に埋もれて見えない
const WIND_LEAD := 0.55
const WIND_MIN := 0.18
const WIND_MAX := 1.00
## 火花が噴いて消えきるまで
const BURST_TIME := 0.45

var _waves: Array[BaseMaterial3D] = []
var _winds: Array[ShaderMaterial] = []

## 踏んだ瞬間だけ噴く火花。glb 同梱の静的メッシュで、ふだんは隠してある
## （このプロジェクトはパーティクルを使わず、加算合成の飾りを Tween で動かす）。
## 金・シアン・マゼンタの3色ぶんに分かれているのは、1メッシュに1マテリアルしか
## 持たせない流儀のため。3つまとめて同じ Tween で動かす
var _sparks: Array[GeometryInstance3D] = []
var _spark_mats: Array[ShaderMaterial] = []
var _spark_homes: Array[Transform3D] = []
var _spark_tween: Tween


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	var model: Node3D = $Mesh/DashPadModel/DashPad
	# 脈動は共有リソースを避けてインスタンス固有のマテリアルで行う
	# （同じ glb を読む他のパネルまで一緒に光ってしまうため）
	var i := 0
	while true:
		var wave: MeshInstance3D = model.get_node_or_null("Wave%d" % i)
		if wave == null:
			break
		var mat: BaseMaterial3D = wave.mesh.surface_get_material(0).duplicate()
		wave.set_surface_override_material(0, mat)
		_waves.append(mat)
		i += 1
	i = 0
	while true:
		var wind := model.get_node_or_null("Wind%d" % i) as GeometryInstance3D
		if wind == null:
			break
		# 風の筋は板1枚なので揺らさない。明滅の速さだけで流れて見せる
		_winds.append(_glow(wind, 1.1, 0.0, true))
		i += 1
	i = 0
	while true:
		var spark := model.get_node_or_null("Spark%d" % i) as GeometryInstance3D
		if spark == null:
			break
		_sparks.append(spark)
		_spark_homes.append(spark.transform)
		# 粒は黄金角に散らしてあるので、bob を入れると1粒ずつばらけて舞う
		_spark_mats.append(_glow(spark, 1.5, 0.10, false))
		i += 1


## glb の不透明材を加算合成の自発光シェーダへ差し替える
## （question_block.gd / manhole.gd の同名ヘルパと同じ形）。
##
## 色は glb のマテリアルからそのまま引き継ぐ。ここで色を持つと
## Blender 側の配色と二重管理になり、片方だけ直したときに黙ってずれる
func _glow(node: GeometryInstance3D, energy: float,
		bob: float, shown: bool) -> ShaderMaterial:
	var src := node.mesh.surface_get_material(0) as BaseMaterial3D
	var m := ShaderMaterial.new()
	m.shader = BEACON_SHADER
	m.set_shader_parameter("albedo", src.albedo_color if src != null else Color.WHITE)
	m.set_shader_parameter("energy", energy)
	m.set_shader_parameter("fade_height", 0.0)
	m.set_shader_parameter("bob", bob)
	m.set_shader_parameter("stripe", 0.0)
	m.set_shader_parameter("fade", 1.0)
	node.material_override = m
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visible = shown
	return m


func _process(_delta: float) -> void:
	# 位相は GameManager.world_time から取る。ラウンド開始で全ピア同時にリセットされるため、
	# どの画面でも波が同じ位置に見える（Time.get_ticks_msec() だと peer ごとにずれる）
	var t: float = GameManager.world_time * WAVE_SPEED
	for i in _waves.size():
		_waves[i].emission_energy_multiplier = lerpf(PULSE_MIN, PULSE_MAX,
			0.5 + 0.5 * sin(t - i * WAVE_STEP))
	for i in _winds.size():
		_winds[i].set_shader_parameter("fade", lerpf(WIND_MIN, WIND_MAX,
			0.5 + 0.5 * sin(t - i * WAVE_STEP + WIND_LEAD)))


func _on_body_entered(body: Node3D) -> void:
	if not body.has_method("apply_boost"):
		return
	# 火花は権威ゲートより手前で噴く。踏んだ瞬間は全ピアの画面で見えてほしい
	_burst_sparks()
	if not body.is_multiplayer_authority():
		return
	body.apply_boost(BOOST_MULT, BOOST_TIME, _travel_dir(body) * KICK)


## 踏まれた瞬間に火花が外へ広がって舞い上がり、消える。
## 連続で踏まれても最後の1回だけが走るよう、動いている Tween は捨てて貼り直す
func _burst_sparks() -> void:
	if _sparks.is_empty():
		return
	if _spark_tween != null and _spark_tween.is_valid():
		_spark_tween.kill()
	_spark_tween = create_tween().set_parallel(true)
	for i in _sparks.size():
		var spark := _sparks[i]
		spark.transform = _spark_homes[i]
		spark.scale = Vector3.ONE * 0.3
		spark.visible = true
		_spark_mats[i].set_shader_parameter("fade", 1.0)
		_spark_tween.tween_property(spark, "scale", Vector3.ONE * 1.8, BURST_TIME) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_spark_tween.tween_property(spark, "position",
				_spark_homes[i].origin + Vector3(0, 0.6, 0), BURST_TIME) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# 広がりきる手前から明るさを抜く。広がりと同時に薄めると、
	# 光が同じ量のまま外周へ引き伸ばされて一番大きい時が一番地味になる
	_spark_tween.tween_method(_set_spark_fade, 1.0, 0.0, BURST_TIME * 0.55) \
		.set_delay(BURST_TIME * 0.45)
	_spark_tween.finished.connect(_hide_sparks)


## tween_method はメソッド参照しか取れないので、シェーダパラメータ用に包む。
## 3色ぶんまとめて同じ値を入れる（別々に抜くと色ごとに消え残る）
func _set_spark_fade(v: float) -> void:
	for m in _spark_mats:
		m.set_shader_parameter("fade", v)


## 消えたあとは隠しておく。見えない火花を回し続けないため
func _hide_sparks() -> void:
	for i in _sparks.size():
		_sparks[i].visible = false
		_sparks[i].transform = _spark_homes[i]


## 蹴り出す向き。踏んだ人の水平速度をそのまま使うのがこのギミックの本体で、
## 「全方向から乗れる」はここ1か所で成立している
func _travel_dir(body: Node3D) -> Vector3:
	var v: Vector3 = body.velocity
	var dir := Vector3(v.x, 0.0, v.z)
	if dir.length() < MIN_SPEED:
		dir = -body.global_transform.basis.z
		dir.y = 0.0
	if dir.length() < 0.01:
		dir = -global_transform.basis.z
		dir.y = 0.0
	return dir.normalized()
