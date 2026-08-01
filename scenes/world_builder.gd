class_name WorldBuilder
extends RefCounted

## WorldData のテーブルからマップ形状を組み立てる。
## world.gd の _ready() で、ナビメッシュのベイクより前に全ピアが実行する。
## 手書きの .tscn では 160m 四方 + ギミック多数を維持できないためスクリプト生成にしている。

const RAMP_WIDTH := 14.0
const RAMP_THICK := 0.6
const RAMP_MIN_RUN := 10.0
const RAMP_RUN_PER_RISE := 3.5  # 高低差1mあたりの水平距離（傾斜のなだらかさ）
## 遮蔽ブロックは「跳び乗れるパルクール用の家具」（2〜5m）。
## 視線を切る役目は下の 6m 壁が担うので数は絞る
const COVER_PER_ZONE := 3

## 死角を作る壁。
## 高さ 6m の根拠: 三人称カメラは SpringArm が y+1.6・長さ4・仰角上限30° なので
## 最大 y≒3.6m。6m ならカメラからも見えず、視線レイ（y1.5発射）と判定が一致する。
## 3m 程度だと「画面では壁越しに見えているのに can_see は false」になり破綻する。
## この値は笠木を含めた総高で、箱の部分は SIGHT_WALL_HEIGHT - WALL_CAP_HEIGHT。
const SIGHT_WALL_HEIGHT := 6.0
const SIGHT_WALL_THICK := 1.2
## 天面の笠木（屋根型）。傾斜は atan(1.2 / 0.6) ≒ 63° で、
## CharacterBody3D.floor_max_angle の既定 45° を超えるため床とみなされず滑り落ちる。
## ジャンプ台（頂点8.6m）やロケットで飛び乗っても壁の上には立てない。
## 副次効果として Recast の agent_max_slope(45°) も超えるので、
## 壁の上に歩行面＝孤立したナビ島が生成されなくなる
const WALL_CAP_HEIGHT := 1.2
const SIGHT_WALL_MIN_LEN := 6.0
const SIGHT_WALL_MAX_LEN := 9.0
## 4象限 x この回数だけ試行し、ゾーンあたり WALLS_PER_ZONE 枚に達したら打ち切る。
## 袋小路が生まれない保証は「軸平行の単一ボックスのみ・中央十字と外周帯が常に空く」
## という配置制約側にあるので、試行回数を上げても崩れない（テスト T2d で実測している）
const WALLS_PER_QUADRANT := 12
const WALLS_PER_ZONE := 11
## ゾーン中心を通る幅18mの十字は必ず空ける。
## _ramp() は全てのスロープをゾーンの中心線上に置くので、
## ここを空けておけば「中心 <-> 4方向のスロープ口」の連結が構成上保証される。
## SPAWN_CLEARANCE(10) も自動的に満たされる（最も寄っても local(9,9)=半径12.7m）
const CORRIDOR_HALF := 9.0
const WALL_OUTER_MARGIN := 2.5  # ゾーン外周から空ける帯
const WALL_GAP := 2.5           # 壁同士の最低隙間（CPU が通れる幅）
const WALL_CLEARANCE := 2.0     # ギミック・遮蔽ブロックの脇を通れるだけの距離
## 隣接ゾーンの床は突き合わせだとボクセル化で継ぎ目が分断されたり、
## 隙間から落下しうるので、必ずこの分だけ重ねる（スロープの取り付け位置も追従する）
const SEAM_OVERLAP := 1.0
## 各ゾーン中心はスポーン地点なので、遮蔽ブロックを置かない半径
const SPAWN_CLEARANCE := 10.0
## ギミックの上や真横に遮蔽ブロックを置かないための余裕
const GIMMICK_CLEARANCE := 3.5


const SPRING_SCENE := preload("res://scenes/gimmicks/spring_pad.tscn")
const BOOST_SCENE := preload("res://scenes/gimmicks/boost_panel.tscn")
const PIPE_SCENE := preload("res://scenes/gimmicks/warp_pipe.tscn")
const QBLOCK_SCENE := preload("res://scenes/gimmicks/question_block.tscn")
const LIFT_SCENE := preload("res://scenes/gimmicks/moving_platform.tscn")
const SPINNER_SCENE := preload("res://scenes/gimmicks/rotating_platform.tscn")
const WALL_TOP_SCRIPT := preload("res://scenes/gimmicks/wall_top.gd")


static func build(map_root: Node3D, gimmick_root: Node3D, decor_root: Node3D) -> void:
	var checker := _checker_texture()
	var zone_mats: Array[StandardMaterial3D] = []
	for idx in WorldData.ZONE_COUNT:
		var m := pop_material(WorldData.ZONE_COLORS[idx])
		_apply_checker(m, checker)
		zone_mats.append(m)
	_build_slabs(map_root, zone_mats)
	# スロープは「道」として床から浮き立つ暖色に（白系だと光を受けて飛んでしまう）
	var ramp_mat := pop_material(Color(0.86, 0.5, 0.24))
	_apply_checker(ramp_mat, checker)
	_build_ramps(map_root, ramp_mat)
	_build_walls(map_root, pop_material(Color(0.32, 0.26, 0.48)))
	# 後から置く物が先に置いた物へ重ならないよう、確定した位置を順に積み上げていく
	var occupied := _build_gimmicks(gimmick_root)
	occupied.append_array(
		_build_cover(map_root, pop_material(Color(0.82, 0.62, 0.3)), occupied))
	_build_sight_walls(map_root, pop_material(Color(0.30, 0.34, 0.55)), occupied)
	_build_decor(decor_root)


## 2x2 の市松模様。ワールド空間トライプラナーで貼るので UV 作成が不要になり、
## 全てのスラブとスロープで模様が途切れずに繋がる
static func _checker_texture() -> ImageTexture:
	var img := Image.create(2, 2, false, Image.FORMAT_RGB8)
	img.set_pixel(0, 0, Color.WHITE)
	img.set_pixel(1, 1, Color.WHITE)
	img.set_pixel(1, 0, Color(0.84, 0.84, 0.84))
	img.set_pixel(0, 1, Color(0.84, 0.84, 0.84))
	return ImageTexture.create_from_image(img)


static func _apply_checker(m: StandardMaterial3D, tex: Texture2D) -> void:
	m.albedo_texture = tex
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3(0.125, 0.125, 0.125)  # 1マス4m


## ノード名は明示的に振る。？ブロックの RPC はノードパスで解決されるため、
## 全ピアで名前が一致していることが前提になる（自動採番に任せない）。
static func _build_gimmicks(root: Node3D) -> Array[Vector3]:
	var occupied: Array[Vector3] = []
	for i in WorldData.SPRING_PADS.size():
		var e: Array = WorldData.SPRING_PADS[i]
		occupied.append(_place(root, SPRING_SCENE, "SpringPad%d" % i, e))
	for i in WorldData.BOOST_PANELS.size():
		var e: Array = WorldData.BOOST_PANELS[i]
		occupied.append(_place(root, BOOST_SCENE, "BoostPanel%d" % i, e, e[3]))
	for i in WorldData.QUESTION_BLOCKS.size():
		var e: Array = WorldData.QUESTION_BLOCKS[i]
		occupied.append(_place(root, QBLOCK_SCENE, "QuestionBlock%d" % i, e))
	# 土管はテーブル上で2本ずつペアになっているので相互に参照させる
	var pipes: Array[Node3D] = []
	for i in WorldData.WARP_PIPES.size():
		var e: Array = WorldData.WARP_PIPES[i]
		occupied.append(_place(root, PIPE_SCENE, "WarpPipe%d" % i, e))
		pipes.append(root.get_node("WarpPipe%d" % i))
	for i in range(0, pipes.size() - 1, 2):
		pipes[i].pair = pipes[i + 1]
		pipes[i + 1].pair = pipes[i]
	# 動く床・回転床は高さ指定があるので個別に配置する
	for i in WorldData.MOVING_PLATFORMS.size():
		var e: Array = WorldData.MOVING_PLATFORMS[i]
		var n: Node3D = LIFT_SCENE.instantiate()
		n.name = "MovingPlatform%d" % i
		n.position = WorldData.zone_point(e[0], e[1], e[3]) + Vector3(0, e[2], 0)
		n.travel = Vector3(e[4], e[5], e[6])
		n.period = e[7]
		root.add_child(n)
		# 開始位置だけでなく通り道の終端も押さえる。
		# でないとリフトが往復する先に壁や遮蔽ブロックが建ってしまう
		occupied.append(n.position)
		occupied.append(n.position + n.travel)
	for i in WorldData.ROTATING_PLATFORMS.size():
		var e: Array = WorldData.ROTATING_PLATFORMS[i]
		var n: Node3D = SPINNER_SCENE.instantiate()
		n.name = "RotatingPlatform%d" % i
		n.position = WorldData.zone_point(e[0], e[1], e[3]) + Vector3(0, e[2], 0)
		n.spin = e[4]
		root.add_child(n)
		occupied.append(n.position)
	return occupied


static func _place(root: Node3D, scene: PackedScene, node_name: String,
		e: Array, yaw_deg := 0.0) -> Vector3:
	var n: Node3D = scene.instantiate()
	n.name = node_name
	n.position = WorldData.zone_point(e[0], e[1], e[2])
	n.rotation.y = deg_to_rad(yaw_deg)
	root.add_child(n)
	return n.position


## マリオ風のPOPな見た目の素。彩度の高いアルベドに弱い自己発光を足すことで、
## 影側の面が濁らず色が残る（gl_compatibility でも確実に効く）。
static func pop_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.85
	m.metallic = 0.0
	m.metallic_specular = 0.2
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = 0.15
	return m


static func _build_slabs(root: Node3D, mats: Array[StandardMaterial3D]) -> void:
	for idx in WorldData.ZONE_COUNT:
		var center := WorldData.zone_center(idx)
		var ext := WorldData.zone_extent(idx)
		var col: int = WorldData.ZONE_COL[idx]
		var row: int = WorldData.ZONE_ROW[idx]
		var x0 := center.x - ext.x * 0.5
		var x1 := center.x + ext.x * 0.5
		var z0 := center.z - ext.y * 0.5
		var z1 := center.z + ext.y * 0.5
		if col > 0:
			x0 -= SEAM_OVERLAP
		if col < 2:
			x1 += SEAM_OVERLAP
		if row > 0:
			z0 -= SEAM_OVERLAP
		if row < 2:
			z1 += SEAM_OVERLAP
		var h: float = center.y - WorldData.SLAB_BOTTOM
		_box(root, "Zone%d" % idx,
			Vector3((x0 + x1) * 0.5, center.y - h * 0.5, (z0 + z1) * 0.5),
			Vector3(x1 - x0, h, z1 - z0), mats[idx])


static func _build_ramps(root: Node3D, mat: Material) -> void:
	for pair in WorldData.RAMP_PAIRS_X:
		_ramp(root, pair[0], pair[1], mat, true)
	for pair in WorldData.RAMP_PAIRS_Z:
		_ramp(root, pair[0], pair[1], mat, false)


## a は西/北側、b は東/南側のゾーン。
## スロープは境界から「低い側のゾーン」へ向かって伸ばすので、
## 高い側の崖のふちにぴたりと接続され、低い側の床に滑らかに着地する。
static func _ramp(root: Node3D, a: int, b: int, mat: Material, along_x: bool) -> void:
	var ya: float = WorldData.ZONE_GROUND[a]
	var yb: float = WorldData.ZONE_GROUND[b]
	var rise := absf(yb - ya)
	if rise < 0.05:
		return  # 段差なし。床同士が直接つながっている
	var run := maxf(RAMP_MIN_RUN, rise * RAMP_RUN_PER_RISE)
	var hyp := sqrt(run * run + rise * rise)
	var angle := atan2(rise, run)
	var dir := -1.0 if ya < yb else 1.0  # 低い側へ伸びる向き
	var mid_y := (ya + yb) * 0.5 - RAMP_THICK * 0.5
	# 高い側の床は重ねしろの分だけ低い側へせり出しているので、そのふちから始める
	var start := WorldData.BAND * (-1.0 if _low_side_index(a, along_x) == 0 else 1.0) \
		+ dir * SEAM_OVERLAP
	if along_x:
		var cz: float = WorldData.AXIS_CENTER[WorldData.ZONE_ROW[a]]
		_box(root, "RampX%d_%d" % [a, b],
			Vector3(start + dir * run * 0.5, mid_y, cz),
			Vector3(hyp, RAMP_THICK, RAMP_WIDTH), mat,
			Vector3(0.0, 0.0, -dir * angle))
	else:
		var cx: float = WorldData.AXIS_CENTER[WorldData.ZONE_COL[a]]
		_box(root, "RampZ%d_%d" % [a, b],
			Vector3(cx, mid_y, start + dir * run * 0.5),
			Vector3(RAMP_WIDTH, RAMP_THICK, hyp), mat,
			Vector3(dir * angle, 0.0, 0.0))


## 境界の符号を決める（a が西/北端のゾーンなら境界は -BAND）
static func _low_side_index(a: int, along_x: bool) -> int:
	return WorldData.ZONE_COL[a] if along_x else WorldData.ZONE_ROW[a]


static func _build_walls(root: Node3D, mat: Material) -> void:
	var h := WorldData.WALL_HEIGHT
	var half := WorldData.WORLD_HALF
	var cy: float = WorldData.SLAB_BOTTOM + h * 0.5
	var span := half * 2.0 + 2.0
	_box(root, "WallN", Vector3(0, cy, -half - 0.5), Vector3(span, h, 1.0), mat)
	_box(root, "WallS", Vector3(0, cy, half + 0.5), Vector3(span, h, 1.0), mat)
	_box(root, "WallW", Vector3(-half - 0.5, cy, 0), Vector3(1.0, h, span), mat)
	_box(root, "WallE", Vector3(half + 0.5, cy, 0), Vector3(1.0, h, span), mat)


## 遮蔽ブロック。配置は固定シードの乱数なので全ピアで同一になる。
## 実際に置けた位置を返し、壁がその上に重ならないようにする
static func _build_cover(root: Node3D, mat: Material, occupied: Array[Vector3]) -> Array[Vector3]:
	var placed: Array[Vector3] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldData.BUILD_SEED
	for idx in WorldData.ZONE_COUNT:
		var center := WorldData.zone_center(idx)
		var ext := WorldData.zone_extent(idx)
		# スロープの取り付け部にかからないよう内側にマージンを取る
		var mx := ext.x * 0.5 - 13.0
		var mz := ext.y * 0.5 - 13.0
		for n in COVER_PER_ZONE:
			var w := rng.randf_range(3.0, 7.0)
			var bh := rng.randf_range(2.0, 5.0)
			var d := rng.randf_range(3.0, 7.0)
			var lx := rng.randf_range(-mx, mx)
			var lz := rng.randf_range(-mz, mz)
			# 各ゾーンの中心はスポーン地点（逃走者=中央 / 鬼=外周）なので必ず空ける
			if Vector2(lx, lz).length() < SPAWN_CLEARANCE:
				continue
			var pos := Vector3(center.x + lx, center.y + bh * 0.5, center.z + lz)
			if _too_close(pos, occupied, maxf(w, d) * 0.5 + GIMMICK_CLEARANCE):
				continue
			_box(root, "Cover%d_%d" % [idx, n], pos, Vector3(w, bh, d), mat)
			placed.append(pos)
	return placed


## 視線を切るための壁。ゾーンごとに4象限へ最大2枚ずつ置く。
##
## 袋小路を作らない保証: 壁は軸平行の単一ボックスのみ（L字・回転なし）で
## 1象限あたり最大2枚なので、閉じたリングは幾何学的に構成できない。
## 加えて CORRIDOR_HALF の十字通路と WALL_OUTER_MARGIN の外周帯が常に空いている。
static func _build_sight_walls(root: Node3D, mat: Material, occupied: Array[Vector3]) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldData.BUILD_SEED + 2
	for idx in WorldData.ZONE_COUNT:
		var center := WorldData.zone_center(idx)
		var ext := WorldData.zone_extent(idx)
		var hi_x := ext.x * 0.5 - WALL_OUTER_MARGIN
		var hi_z := ext.y * 0.5 - WALL_OUTER_MARGIN
		var placed: Array = []  # [中心Vector3, 半径Vector2]
		var n := 0
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				for k in WALLS_PER_QUADRANT:
					if n >= WALLS_PER_ZONE:
						break
					# 乱数はスキップ判定より前に引き切る。
					# こうしておけばキープアウト条件を足しても他の壁の位置がずれない
					var along_x := rng.randi() % 2 == 0
					var want_len := rng.randf_range(SIGHT_WALL_MIN_LEN, SIGHT_WALL_MAX_LEN)
					var u := rng.randf()
					var v := rng.randf()
					var span := (hi_x if along_x else hi_z) - CORRIDOR_HALF
					if span < SIGHT_WALL_MIN_LEN:
						continue
					var wall_len := minf(want_len, span)
					# 長手方向は象限の帯の中で、短手方向は十字と外周を避けて配置する
					var along := lerpf(CORRIDOR_HALF + wall_len * 0.5,
						(hi_x if along_x else hi_z) - wall_len * 0.5, u)
					var across := lerpf(CORRIDOR_HALF + 1.0,
						(hi_z if along_x else hi_x) - 1.0, v)
					var lx := (along if along_x else across) * sx
					var lz := (across if along_x else along) * sz
					var half := Vector2(wall_len, SIGHT_WALL_THICK) * 0.5
					if not along_x:
						half = Vector2(SIGHT_WALL_THICK, wall_len) * 0.5
					var pos := Vector3(center.x + lx,
						center.y + SIGHT_WALL_HEIGHT * 0.5, center.z + lz)
					if _rect_too_close(pos, half, occupied, WALL_CLEARANCE):
						continue
					var clash := false
					for e in placed:
						if _rect_too_close(pos, half + e[1], [e[0]] as Array[Vector3], WALL_GAP):
							clash = true
							break
					if clash:
						continue
					# 箱の高さは笠木の分だけ引き、天面に屋根型の笠木を載せる
					var box_h := SIGHT_WALL_HEIGHT - WALL_CAP_HEIGHT
					var body := _box(root, "SightWall%d_%d" % [idx, n],
						Vector3(pos.x, center.y + box_h * 0.5, pos.z),
						Vector3(half.x * 2.0, box_h, half.y * 2.0), mat)
					_wall_cap(body, wall_len, along_x, box_h, mat)
					placed.append([pos, half])
					n += 1


## 壁の天面に屋根型の笠木を付けて、乗っても滑り落ちるようにする。
## PrismMesh は +Y が稜線・Z 方向へ押し出されるので、
## 壁が X 方向に伸びている場合は Y 軸まわりに 90° 回す。
##
## 笠木だけでは塞ぎきれない（稜線の真上ではカプセルの接触法線が真上になり
## 立ててしまう）ので、天面を覆う Area3D を重ねて確実に弾き出す。
static func _wall_cap(body: StaticBody3D, wall_len: float, along_x: bool,
		box_h: float, mat: Material) -> void:
	var prism := PrismMesh.new()
	prism.size = Vector3(SIGHT_WALL_THICK, WALL_CAP_HEIGHT, wall_len)
	prism.material = mat
	var mesh := MeshInstance3D.new()
	mesh.mesh = prism
	var col := CollisionShape3D.new()
	# メッシュから凸形状を起こすので、見た目と当たり判定が必ず一致する
	col.shape = prism.create_convex_shape()
	var cap_y := box_h * 0.5 + WALL_CAP_HEIGHT * 0.5
	for c: Node3D in [mesh, col]:
		c.position = Vector3(0, cap_y, 0)
		if along_x:
			c.rotation.y = PI * 0.5
		body.add_child(c)

	var area := Area3D.new()
	area.name = "TopGuard"
	area.collision_layer = 0
	area.collision_mask = 2  # Character
	area.set_script(WALL_TOP_SCRIPT)
	var guard := CollisionShape3D.new()
	var gbox := BoxShape3D.new()
	# 笠木の上に十分な厚みを持たせ、飛び乗った瞬間に必ず領域へ入るようにする
	gbox.size = Vector3(SIGHT_WALL_THICK, WALL_CAP_HEIGHT + 2.0, wall_len)
	guard.shape = gbox
	guard.position = Vector3(0, (WALL_CAP_HEIGHT + 2.0) * 0.5 - WALL_CAP_HEIGHT * 0.5, 0)
	area.position = Vector3(0, cap_y, 0)
	if along_x:
		area.rotation.y = PI * 0.5
	area.add_child(guard)
	body.add_child(area)


## 壁は回転しないので、広げた AABB への点内包判定で厳密に足りる
static func _rect_too_close(c: Vector3, half: Vector2, pts: Array[Vector3], pad: float) -> bool:
	for p in pts:
		if absf(p.x - c.x) < half.x + pad and absf(p.z - c.z) < half.y + pad:
			return true
	return false


static func _too_close(pos: Vector3, points: Array[Vector3], radius: float) -> bool:
	for p in points:
		if Vector2(pos.x - p.x, pos.z - p.z).length() < radius:
			return true
	return false


## --- 装飾 --------------------------------------------------------------
## 当たり判定なしの飾り。すべて MultiMeshInstance3D にまとめるので
## 総数 250 個あってもドローコールは4本で済む（Web 書き出し向け）。

static func _build_decor(root: Node3D) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldData.BUILD_SEED + 1

	# 雲: 3個の潰した球を寄せて1つの雲にする。遠景なので距離カリングはしない
	var clouds: Array[Transform3D] = []
	for i in 24:
		var c := Vector3(rng.randf_range(-78.0, 78.0), rng.randf_range(40.0, 62.0),
			rng.randf_range(-78.0, 78.0))
		for k in 3:
			var s := rng.randf_range(2.5, 5.0)
			clouds.append(Transform3D(
				Basis.from_scale(Vector3(s, s * 0.55, s)),
				c + Vector3(rng.randf_range(-4.0, 4.0), rng.randf_range(-0.8, 0.8),
					rng.randf_range(-3.0, 3.0))))
	_multimesh(root, "Clouds", _sphere(Color(1, 1, 1), 0.3), clouds, 0.0)

	# 茂み: 各ゾーンの外周に沿って
	var bushes: Array[Transform3D] = []
	for idx in WorldData.ZONE_COUNT:
		var c := WorldData.zone_center(idx)
		var ext := WorldData.zone_extent(idx)
		for k in 6:
			var a := TAU * k / 6.0 + rng.randf_range(-0.3, 0.3)
			var p := Vector3(c.x + cos(a) * ext.x * 0.42, c.y,
				c.z + sin(a) * ext.y * 0.42)
			var s := rng.randf_range(1.6, 2.8)
			bushes.append(Transform3D(Basis.from_scale(Vector3(s, s * 0.55, s)), p))
	_multimesh(root, "Bushes", _sphere(Color(0.18, 0.6, 0.24), 0.12), bushes)

	# コイン: ジャンプ台の上に弧を描いて「ここから跳べる」と示す
	var coins: Array[Transform3D] = []
	for e in WorldData.SPRING_PADS:
		var base := WorldData.zone_point(e[0], e[1], e[2])
		for k in 7:
			var t := k / 6.0
			coins.append(Transform3D(Basis.from_euler(Vector3(PI * 0.5, 0, 0)),
				base + Vector3(0, 2.5 + sin(t * PI) * 5.5, (t - 0.5) * 9.0)))
	for e in WorldData.WARP_PIPES:
		var base := WorldData.zone_point(e[0], e[1], e[2])
		for k in 8:
			var a := TAU * k / 8.0
			coins.append(Transform3D(Basis.from_euler(Vector3(PI * 0.5, a, 0)),
				base + Vector3(cos(a) * 3.2, 3.4, sin(a) * 3.2)))
	_multimesh(root, "Coins", _coin(), coins)

	# チェッカー旗: 外壁沿いの目印
	var flags: Array[Transform3D] = []
	var half := WorldData.WORLD_HALF
	for k in 10:
		var t := (k + 0.5) / 10.0 * 2.0 * half - half
		flags.append(Transform3D(Basis.IDENTITY, Vector3(t, 2.0, -half + 1.5)))
		flags.append(Transform3D(Basis.IDENTITY, Vector3(t, 2.0, half - 1.5)))
		flags.append(Transform3D(Basis.IDENTITY, Vector3(-half + 1.5, 2.0, t)))
		flags.append(Transform3D(Basis.IDENTITY, Vector3(half - 1.5, 2.0, t)))
	_multimesh(root, "Flags", _flag(), flags, 130.0)


static func _sphere(c: Color, emission := 0.6) -> Mesh:
	var m := SphereMesh.new()
	m.radius = 1.0
	m.height = 2.0
	m.radial_segments = 10
	m.rings = 5
	var mat := pop_material(c)
	mat.emission_energy_multiplier = emission
	m.material = mat
	return m


static func _coin() -> Mesh:
	var m := CylinderMesh.new()
	m.top_radius = 0.42
	m.bottom_radius = 0.42
	m.height = 0.09
	m.radial_segments = 12
	var mat := pop_material(Color(1, 0.78, 0.1))
	mat.emission_energy_multiplier = 0.9
	m.material = mat
	return m


static func _flag() -> Mesh:
	var m := BoxMesh.new()
	m.size = Vector3(0.25, 4.0, 0.25)
	m.material = pop_material(Color(0.9, 0.9, 0.95))
	return m


static func _multimesh(root: Node3D, node_name: String, mesh: Mesh,
		transforms: Array[Transform3D], range_end := 90.0) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = range_end
	mmi.visibility_range_end_margin = 15.0 if range_end > 0.0 else 0.0
	root.add_child(mmi)


static func _box(root: Node3D, node_name: String, pos: Vector3, size: Vector3,
		mat: Material, rot := Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = pos
	body.rotation = rot
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	box.material = mat
	mesh.mesh = box
	body.add_child(mesh)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	root.add_child(body)
	return body
