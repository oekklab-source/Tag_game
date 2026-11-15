extends Area3D

## ダッシュパネル（レースゲームでおなじみの、山型の矢印が流れるダッシュ板）。8m 角の正方形。
## 踏むと**その人自身の進行方向へ**蹴り出し、一定時間のスピードアップを与える。
##
## ベルトコンベアだった頃は搬送方向が固定で、逆から入ると押し戻されて
## 通り抜けられなかった。今は蹴り出す向きを踏んだ人から取るので、
## **四方どこから乗っても素通りでき、必ず自分の行きたい方へ加速する。**
## パネル自身の向き（-Z）は、止まったまま乗られた時の最後の保険にしか使わない。
## 逃走者も鬼も同じように使える対称ギミック。
##
## **正方形**なのはこのため。5m x 10m の長方形だと「長い方が正面」に見えて仕様と食い違う。
##
## 山型（シェブロン）は一方向だが、**蹴る向きは踏んだ人の進行方向のまま**。
## 山型は向きの指示ではなく「加速する板」の記号として扱う。
## 以前は「片方向の矢印だと逆から乗った人が矢印と逆へ加速して見た目が仕様に嘘をつく」
## として四方ぶん置いていたが、2026-10-04 に本家の見た目を優先して一方向にした。
##
## body_entered は全ピアで発火するため、効果の適用は必ず
## 「そのボディの権威ピア」に限定する（見た目の流れと火花は全ピアで動かす）。

const BOOST_MULT := 2.0
const BOOST_TIME := 3.0
const KICK := 7.0
## 進行方向とみなす下限。これを割ったら本人の向きへ蹴る。
## 真上から落ちてきた人・止まって乗った人を明後日の方向へ飛ばさないため
const MIN_SPEED := 1.0

const BEACON_SHADER := preload("res://scenes/beacon.gdshader")

const PLATE_SHADER := preload("res://scenes/gimmicks/boost_panel.gdshader")

## 山型が流れる速さ（タイル/秒。タイル1枚 = 3.84m）。
## **正であること。** 絵は UV.y に足した分だけ Blender の +Y（= Godot の -Z = パネルの前）へ
## 流れるので、負にすると山型が後ろへ流れて「戻される板」に見える
const SCROLL_SPEED := 1.2
## 光沢の帯が板の端から端まで流れる速さ（周/秒）。山型より遅くして、別の動きとして見せる
const SHEEN_SPEED := 0.45
## 火花が噴いて消えきるまで
const BURST_TIME := 0.45

## 板（Plate）の描画。パネルごとに新しく作る。シェーダパラメータはマテリアルごとの値なので、
## 共有すると1枚のパネルの位相や光沢を変えたとき同じ glb を読む全パネルが巻き込まれる
var _plate: ShaderMaterial

## 踏んだ瞬間だけ噴く火花。glb 同梱の静的メッシュで、ふだんは隠してある
## （このプロジェクトはパーティクルを使わず、加算合成の飾りを Tween で動かす）。
## 金・ピンク・白の3色ぶんに分かれているのは、1メッシュに1マテリアルしか
## 持たせない流儀のため。3つまとめて同じ Tween で動かす
var _sparks: Array[GeometryInstance3D] = []
var _spark_mats: Array[ShaderMaterial] = []
var _spark_homes: Array[Transform3D] = []
var _spark_tween: Tween

## スマホだけ、画面に映っていない間は虹の波を止める(発熱対策。PC では null のまま毎フレーム回す)。
## 8枚 x 9マテリアルを毎フレーム書き換えていて、画面外でも止まらなかった。
## 波の位相は毎回 world_time から計算していて状態を持たないので、画面に戻った瞬間から
## 正しい位置で光る(止めていた間の分が遅れて見えることはない)
var _on_screen: VisibleOnScreenNotifier3D


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	if PhonePerf.enabled():
		_on_screen = VisibleOnScreenNotifier3D.new()
		# 板(8m 角)に、踏んだときに舞い上がる火花のぶんの高さを足した箱
		_on_screen.aabb = AABB(Vector3(-4.5, -0.2, -4.5), Vector3(9.0, 2.6, 9.0))
		add_child(_on_screen)
	var model: Node3D = $Mesh/DashPadModel/DashPad
	# 板の絵（山型・グラデーション）は glb のマテリアルが持つ。ここで画像を持つと
	# Blender 側と二重管理になり、片方だけ直したときに黙ってずれる（_glow() と同じ流儀）。
	# マテリアルはパネルごとに新しく作る
	var plate := model.get_node("Plate") as MeshInstance3D
	var src := plate.mesh.surface_get_material(0) as BaseMaterial3D
	_plate = ShaderMaterial.new()
	_plate.shader = PLATE_SHADER
	_plate.set_shader_parameter("tile", src.albedo_texture if src != null else null)
	plate.material_override = _plate
	var i := 0
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
	if _on_screen != null and not _on_screen.is_on_screen():
		return
	# 位相は GameManager.world_time から取る。ラウンド開始で全ピア同時にリセットされるため、
	# どの画面でも山型が同じ位置に見える（Time.get_ticks_msec() だと peer ごとにずれる）
	var t: float = GameManager.world_time
	_plate.set_shader_parameter("scroll", fposmod(t * SCROLL_SPEED, 1.0))
	_plate.set_shader_parameter("sheen", fposmod(t * SHEEN_SPEED, 1.0))


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
