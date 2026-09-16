extends Node

## ダッシュパネル（レインボーロードのダッシュ板）のモデル構造・虹の波・
## 全方向からの通り抜け・配置を総合検証する。
##
##   godot --headless --path . res://tests/boost_panel.tscn
##
## 見るところは6つ:
##   1. glb の台座と虹の段が名前どおり取れて、根が回っていないこと
##   2. **段差にならない高さに収まっていること**。ベルトコンベアだった頃の
##      側枠（0.50m）が残っていると、横から乗るときに引っかかる
##   3. 蹴り出す向きが「踏んだ人の進行方向」であること。
##      パネル自身の向きに引きずられたらここで落ちる
##   4. **四方どの向きからでも通り抜けられ、どれでもバフが出ること**。
##      ベルトだった頃は逆走できないのが仕様だったので、ここが逆転している
##   5. 虹の段のマテリアルがパネルごとに独立していること
##      （共有のままだと1枚踏むたびに全パネルが一緒に光る）
##   6. 火花3色がふだんは出ておらず、当たり判定に関わらない飾りであること

const BOOST := preload("res://scenes/gimmicks/boost_panel.tscn")
const SETTLE := 12  # 置いた後、着地するまで回す物理フレーム
const PUSH := 90    # 端から端まで押し込む物理フレーム（約1.5秒）
## 正方形なので四方とも同じ距離。当たり判定 BoxShape3D(8, 1.6, 8) より

var _fail := 0


func _ready() -> void:
	print("=== ダッシュパネル（レインボーロードのダッシュ板）の総合検証 ===")
	_check_model()
	_check_flat()
	_check_effects()
	_check_kick_dir()
	_check_placement()
	await _check_cross_all_ways()
	print("=== %s ===" % ("すべての検証に合格しました" if _fail == 0
		else "%d 件の検証に失敗しました" % _fail))
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(label: String, cond: bool, extra := "") -> void:
	if not cond:
		_fail += 1
	print("  %s: %s%s" % [label, "OK" if cond else "FAIL",
		"" if extra.is_empty() else "  (%s)" % extra])


func _model_of(panel: Area3D) -> Node3D:
	return panel.get_node_or_null("Mesh/DashPadModel/DashPad")


## --- 1. glb の構造 -----------------------------------------------------

func _check_model() -> void:
	var panel: Area3D = BOOST.instantiate()
	add_child(panel)
	var model := _model_of(panel)
	_ok("DashPad ノード", model != null)
	if model == null:
		panel.queue_free()
		return
	_ok("台座 Base", model.get_node_or_null("Base") != null)
	_ok("虹が6段", panel._waves.size() == 6, "%d 段" % panel._waves.size())
	_ok("風の筋が3組", panel._winds.size() == 3, "%d 組" % panel._winds.size())
	# 虹の段のローカル座標をそのまま使うので、モデルの根が回転していないことが前提
	_ok("モデルの根が無回転", model.transform.basis.is_equal_approx(Basis.IDENTITY),
		str(model.transform.basis.get_euler()))

	# 5. マテリアルはパネルごとに複製されていること
	var other: Area3D = BOOST.instantiate()
	add_child(other)
	_ok("虹の段のマテリアルがパネルごとに独立",
		panel._waves[0] != other._waves[0])
	# 波が外向きに流れること。位相を段の番号ぶん遅らせるので正でなければならない
	_ok("光の波が中心から四方へ流れる", panel.WAVE_STEP > 0.0,
		"位相差 %+.2f rad/段" % panel.WAVE_STEP)
	other.queue_free()
	panel.queue_free()


## --- 2. 段差にならない高さ ---------------------------------------------

## 「全方向から乗れる」はこの高さが根拠。ここが崩れると横入りで足を取られる
func _check_flat() -> void:
	var panel: Area3D = BOOST.instantiate()
	add_child(panel)
	var model := _model_of(panel)
	var lo := INF
	var hi := -INF
	for child in model.get_children():
		var mi := child as MeshInstance3D
		if mi == null:
			continue
		# 火花は踏んだ瞬間だけ噴く加算合成の飾り。ふだんは非表示で当たり判定にも
		# 関わらないので、床の段差を見るこの検証からは外す（_check_effects が見る）
		if String(mi.name).begins_with("Spark"):
			continue
		var box: AABB = mi.transform * mi.mesh.get_aabb()
		lo = minf(lo, box.position.y)
		hi = maxf(hi, box.end.y)
	_ok("床から浮いていない", absf(lo) < 0.01, "最下面 y=%.3f" % lo)
	_ok("段差にならない高さ", hi < 0.2, "全高 %.3fm" % hi)
	_check_square(model)
	panel.queue_free()


## **正方形であること。** 「四方から乗れる」仕様に見た目を合わせるための形なので、
## どこかの辺が伸びたら「長い方が正面」に見えてしまう。
## 当たり判定 BoxShape3D(8, 1.6, 8) とも揃っていること
func _check_square(model: Node3D) -> void:
	var box := AABB()
	var first := true
	for child in model.get_children():
		var mi := child as MeshInstance3D
		if mi == null or String(mi.name).begins_with("Spark"):
			continue
		var b: AABB = mi.transform * mi.mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	_ok("正方形", is_equal_approx(box.size.x, box.size.z),
		"%.2fm x %.2fm" % [box.size.x, box.size.z])
	_ok("当たり判定と同じ差し渡し",
		absf(box.size.x - WorldBuilder.PAD_HALF * 2.0) < 0.01,
		"モデル %.2fm / 判定 %.2fm" % [box.size.x, WorldBuilder.PAD_HALF * 2.0])


## --- 6. 火花は飾りであって床ではない -----------------------------------

## パーティクルノードを使わず glb 同梱の静的メッシュを加算合成で噴かせているので、
## 「ふだん出ていない・影を落とさない・シェーダが当たっている」の3点で飾りだと保証する
func _check_effects() -> void:
	var panel: Area3D = BOOST.instantiate()
	add_child(panel)
	_ok("火花が3色", panel._sparks.size() == 3, "%d 色" % panel._sparks.size())
	var seen: Array[Color] = []
	for spark in panel._sparks:
		_ok("%s はふだん出ていない" % spark.name, not spark.visible)
		var mat := spark.material_override as ShaderMaterial
		_ok("%s は加算合成シェーダで描く" % spark.name, mat != null)
		_ok("%s は影を落とさない" % spark.name,
			spark.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		if mat != null:
			# 色は glb のマテリアルから引き継ぐ。取りこぼすと3色とも白で噴く
			var c: Color = mat.get_shader_parameter("albedo")
			_ok("%s の色が glb から来ている" % spark.name, not seen.has(c), str(c))
			seen.append(c)
	panel.queue_free()


## --- 3. 蹴り出す向きは踏んだ人の進行方向 -------------------------------

func _check_kick_dir() -> void:
	var panel: Area3D = BOOST.instantiate()
	add_child(panel)
	var player: Node3D = load("res://scenes/player.tscn").instantiate()
	player.name = "1"
	add_child(player)

	# パネルは -Z 向きに置いてある。そのどれとも違う向きで走り込んでも、
	# 蹴り出しは必ず本人の進行方向へ揃うこと
	for dir in [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT,
			Vector3(1, 0, 1).normalized()]:
		player.velocity = dir * 6.0
		var kick: Vector3 = panel._travel_dir(player)
		_ok("進行方向 %s へ蹴る" % dir, kick.is_equal_approx(dir),
			"蹴り出し %s" % kick)

	# 止まったまま乗られたら本人の向きを使う（真上から落ちてきた場合）
	player.velocity = Vector3(0, -8.0, 0)
	player.rotation.y = deg_to_rad(90.0)
	var facing := -player.global_transform.basis.z
	_ok("止まっていれば本人の向きへ蹴る",
		panel._travel_dir(player).is_equal_approx(
			Vector3(facing.x, 0.0, facing.z).normalized()))
	# **queue_free() では間に合わない。** 次の検証も権威を持つピアID "1" で
	# プレイヤーを足すので、消えきる前だと名前が衝突して改名され、
	# 権威を失ったプレイヤーが teleport にも _physics_process にも入らず一歩も動かない
	remove_child(player)
	player.free()
	panel.queue_free()


## --- 4. 配置 -----------------------------------------------------------

func _check_placement() -> void:
	# パネルは10mあるので中心だけでなく長辺の両端もスロープに掛かっていないこと
	for i in WorldData.BOOST_PANELS.size():
		var e: Array = WorldData.BOOST_PANELS[i]
		WorldBuilder._assert_clear_of_ramps(
			e[0], WorldData.zone_point(e[0], e[1], e[2]), "BoostPanel%d" % i)
		for edge_pos in WorldBuilder.boost_panel_edges(e):
			WorldBuilder._assert_clear_of_ramps(e[0], edge_pos, "BoostPanel%d の縁" % i)
	_ok("%d か所すべて四辺までスロープ干渉なし" % WorldData.BOOST_PANELS.size(), true)


## --- 5. 四方どこからでも通り抜けられる ---------------------------------

func _check_cross_all_ways() -> void:
	# world.tscn は待ち受けポートを掴むので、ここでは床とパネルとプレイヤーだけの
	# 最小構成で回す（ゲームを起動したままでも走らせられるようにするため）
	add_child(_floor())
	var panel: Area3D = BOOST.instantiate()
	add_child(panel)
	var player: Node3D = load("res://scenes/player.tscn").instantiate()
	# 権威はノード名（= ピアID）から決まる。world.tscn と同じく "1" で足す
	player.name = "1"
	add_child(player)
	await get_tree().physics_frame

	var fwd := -panel.global_transform.basis.z
	fwd = Vector3(fwd.x, 0.0, fwd.z).normalized()
	var side := fwd.cross(Vector3.UP)
	# 正方形（8m角）なので、四方とも縁から 1m 外に置いて突っ込ませる
	var out_dist: float = WorldBuilder.PAD_HALF + 1.0
	for run in [["順方向", fwd, out_dist],
			["逆方向", -fwd, out_dist],
			["横から", side, out_dist],
			["逆の横から", -side, out_dist]]:
		await _cross(panel, player, run[0], run[1], run[2])


## 外側から中心へ向かって全力で走り込み、反対側まで抜けられるかを見る。
## 距離は入口と同じだけ反対側へ出るまで。
##
## **速度を外から代入してはいけない。** player.gd の _physics_process が
## 毎フレーム入力から速度を組み直すので、代入した値はその場で消える。
## 進みたい向きへ本人を向けて move_forward を押すのが実際の走行と同じ経路になり、
## _travel_dir が読む velocity もゲーム中と同じものになる
func _cross(panel: Area3D, player: Node3D, label: String,
		dir: Vector3, out_dist: float) -> void:
	player.buffs.clear()
	player.teleport(panel.global_position - dir * out_dist + Vector3(0, 0.05, 0))
	player.velocity = Vector3.ZERO
	player.rotation.y = atan2(-dir.x, -dir.z)  # プレイヤーの前は -Z
	for i in SETTLE:
		await get_tree().physics_frame
	var farthest := -INF
	Input.action_press("move_forward")
	for i in PUSH:
		await get_tree().physics_frame
		farthest = maxf(farthest, (player.global_position - panel.global_position).dot(dir))
	Input.action_release("move_forward")
	_ok("%sから通り抜けられる" % label, farthest > out_dist,
		"中心の先 %.2fm まで到達（%.2fm 必要）" % [farthest, out_dist])
	_ok("%sでもバフが出る" % label,
		is_equal_approx(player.buffs.get_mult(&"speed"), 2.0),
		"x%.2f" % player.buffs.get_mult(&"speed"))


## 検証用の床。プレイヤーの collision_mask(11) に含まれるレイヤ1に置く
func _floor() -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 60)
	shape.shape = box
	shape.position = Vector3(0, -0.5, 0)
	body.add_child(shape)
	return body
