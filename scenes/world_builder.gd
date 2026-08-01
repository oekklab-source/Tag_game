class_name WorldBuilder
extends RefCounted

## WorldData のテーブルからマップ形状を組み立てる。
## world.gd の _ready() で、ナビメッシュのベイクより前に全ピアが実行する。
## 手書きの .tscn では 160m 四方 + ギミック多数を維持できないためスクリプト生成にしている。

const RAMP_WIDTH := 14.0
const RAMP_THICK := 0.6
const RAMP_MIN_RUN := 10.0
const RAMP_RUN_PER_RISE := 3.5  # 高低差1mあたりの水平距離（傾斜のなだらかさ）

## --- 滑り台 -------------------------------------------------------------
## スロープ(3.5)より急にして「降りるのは速い」を作る。落差7m -> 走路14m = 26.6°。
## 45°を超えると is_on_floor() が false になり歩行モーションも横操作も死ぬので、
## 「登れない」は幾何ではなく SlideMotion の最低前進速度で保証している。
##
## 走路は直線・一定傾斜の1枚板。以前は曲げていたが、分割したセグメントの
## 継ぎ目（最大11°の折れ）で足が引っかかった。1枚板なら継ぎ目が存在しない
const SLIDE_RUN_PER_RISE := 2.0
const SLIDE_MIN_RUN := 10.0
const SLIDE_WIDTH := 8.0
const SLIDE_THICK := 0.6
## 下端だけこの分だけ低い側の床へ潜り込ませる。
## 上端は絶対に伸ばさない。傾いた板を上へ伸ばすと角が高い側の床から突き出て、
## 入口にちょうど TUCK * sin(26.6°) の段差ができ、そこで足を取られる。
## 伸ばさなければ板の上端の角が床と同じ高さで揃い、平面から斜面への
## 凸の折れになる（凸側は引っかからない）
const SLIDE_END_TUCK := 0.5
const SLIDE_RAIL_W := 0.5
## レールはデッキの内側に載せる（通行幅は 5.0 - 0.5*2 = 4.0m）。
## 高さ1mに抑えるのは SpringArm(長さ4/y+1.6)がレールに引っかかって
## カメラが寄ってしまうのを避けるため
const SLIDE_RAIL_H := 1.0
const SLIDE_AREA_HEIGHT := 4.0  # 滑走 Area の厚み。走路の上に立つ抜け道を塞ぐ
const SLIDE_EXIT_RUN := 5.0     # 出口から先、平地に伸ばす Area の長さ（勢いを逃がす）
const SLIDE_CAP := 18.0         # 滑走の上限速度

## --- 転落防止の柵 -------------------------------------------------------
## これが無いと高いゾーンの縁からどこでも飛び降りられ、滑り台を使う意味がなくなる。
## 落差がこれ以上ある境界にだけ立てる（1〜2mの段差は普通に降りられてよい）
const PARAPET_MIN_DROP := 3.0
## ジャンプ(1.38m)では越えられない高さ。視線を切る 6m 級ではないので
## 「画面では見えているのに can_see は false」の破綻は起こさない
const PARAPET_HEIGHT := 2.5
const PARAPET_THICK := 0.8
const PARAPET_SLIDE_GAP := 11.0  # 滑り台の入口を通す開口（走路8m + 余裕）
const PARAPET_RAMP_GAP := 18.0   # スロープの取り付け口。十字通路がそのまま残る幅
## ジャンプ台の着地口。ここからは飛び降りもできてしまうが、狭い1箇所に限定される。
## 落ちても着地時の速度は歩行のままなので、18m/s 出る滑り台の価値は残る
const PARAPET_PAD_GAP := 7.0
## ナビリンクの端点をゾーンの縁から内側へ寄せる距離。
## 縁ちょうどだとナビメッシュが agent_radius 分だけ縮んでいて乗らない
const NAV_LINK_INSET := 3.0
## 土管リンクの端点を土管の中心からずらす距離。
## 土管が navmesh に空ける穴は「半径1.5 + agent_radius 0.45 + セル量子化」で実測 2.3m。
## ここを超えつつ GIMMICK_CLEARANCE(3.5) の内側なら、周りに壁が生えないことも保証される
const PIPE_LINK_OFFSET := 3.0
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


## _solid() が作れる形。凹形状（門型など）は必ず複数の凸の組み合わせで作る。
## 単一の凹メッシュを作ると create_convex_shape() が見た目と食い違う
enum Shape { BOX, CYLINDER, CONE, SPHERE, CAPSULE, PRISM }

## 丸物の分割数。Web 書き出しの予算があるので上げない（既存の _coin と同じ）
const ROUND_SEGMENTS := 12
const ROUND_RINGS := 6
const GUARD_THICK := 3.0  # 天面ガードの厚み。飛び乗った瞬間に必ず入る高さ
## 丸いプロップの直径は「壁の長さ」をそのまま使うと太すぎるので縮める
const ROUND_PROP_SCALE := 0.55
const CRATE_DEPTH := 3.4  # コンテナの奥行き。壁(1.2)より厚く、通路を潰さない程度


const SPRING_SCENE := preload("res://scenes/gimmicks/spring_pad.tscn")
const BOOST_SCENE := preload("res://scenes/gimmicks/boost_panel.tscn")
const PIPE_SCENE := preload("res://scenes/gimmicks/warp_pipe.tscn")
const QBLOCK_SCENE := preload("res://scenes/gimmicks/question_block.tscn")
const LIFT_SCENE := preload("res://scenes/gimmicks/moving_platform.tscn")
const SPINNER_SCENE := preload("res://scenes/gimmicks/rotating_platform.tscn")
const WALL_TOP_SCRIPT := preload("res://scenes/gimmicks/wall_top.gd")
const SLIDE_SCRIPT := preload("res://scenes/gimmicks/slide.gd")


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
	_build_parapets(map_root, pop_material(Color(0.94, 0.72, 0.32)))
	# 後から置く物が先に置いた物へ重ならないよう、確定した位置を順に積み上げていく
	var occupied := _build_gimmicks(gimmick_root)
	# 滑り台は走路の下に遮蔽ブロックや壁が生えると通れなくなるので、
	# フットプリントを occupied に足してから後続の配置へ渡す
	var slide_paths := _build_slides(map_root, gimmick_root)
	for pts in slide_paths:
		occupied.append_array(pts)
	_build_nav_links(gimmick_root, slide_paths)
	occupied.append_array(
		_build_cover(map_root, pop_material(Color(0.82, 0.62, 0.3)), occupied))
	# 構造物はゾーンごとのアクセント色で建てる。
	# 床（ZONE_COLORS）と分離した色にしないと、地形と一体化して形が読めない
	var accent_mats: Array[StandardMaterial3D] = []
	for idx in WorldData.ZONE_COUNT:
		accent_mats.append(soft_material(WorldData.ZONE_ACCENTS[idx]))
	_build_props(map_root, accent_mats, occupied)
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


## CPU 鬼の経路探索用のリンク。柵とスロープ撤去で高いゾーンは歩いて出入りできなくなり、
## 滑り台の幾何は Platform レイヤーでベイクもされないため、
## これが無いと CLOUD DECK / SKY STEPS が CPU の来ない安全地帯になってしまう。
##
## 滑り台は一方通行にする（bidirectional = false）。双方向にすると
## CPU が「登れる」と誤解して経路を引き、押し戻されて永久に振動する。
## 土管は元から双方向なので、これが CPU にとって唯一の登坂ルートになる。
static func _build_nav_links(root: Node3D, slide_paths: Array) -> void:
	for i in slide_paths.size():
		var pts: Array = slide_paths[i]
		# 入口は柵の開口より手前（高い側の床の上）へ寄せる。境界ちょうどだと
		# ナビメッシュが agent_radius の分だけ内側に縮んでいて乗らない
		var entry: Vector3 = pts[0]
		var inward: Vector3 = (pts[0] - pts[1]).normalized()
		inward.y = 0.0
		_nav_link(root, "SlideLink%d" % i,
			entry + inward.normalized() * NAV_LINK_INSET, pts[2], false)
	var pipes := WorldData.WARP_PIPES
	for i in range(0, pipes.size() - 1, 2):
		var a: Array = pipes[i]
		var b: Array = pipes[i + 1]
		var pa := WorldData.zone_point(a[0], a[1], a[2])
		var pb := WorldData.zone_point(b[0], b[1], b[2])
		# 端点は土管の中心ではなく「相手と反対側の足元」に置く。
		# 土管は半径1.5mの静的ボディなのでナビメッシュに 2.3m ほどの穴が空き、
		# 中心に置いた端点はメッシュに繋がらない。
		# この位置なら端点から相手へ一直線に歩くと必ず土管の口を通るので、
		# 経路をたどるだけで warp_pipe の Area に入る
		var away := Vector3(pa.x - pb.x, 0.0, pa.z - pb.z).normalized() * PIPE_LINK_OFFSET
		_nav_link(root, "PipeLink%d" % i, pa + away, pb - away, true)


static func _nav_link(root: Node3D, node_name: String, from: Vector3, to: Vector3,
		both: bool) -> void:
	var link := NavigationLink3D.new()
	link.name = node_name
	link.start_position = from
	link.end_position = to
	link.bidirectional = both
	root.add_child(link)


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


## ふわふわの基調材。白を混ぜて彩度を落とし、粗さを上げる。
## 影側が沈まないよう、発光はアルベドより「明るい」色にする。
## rim_enabled は Compatibility での挙動が不確実なので使わず、これで縁の明るさを作る
static func soft_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c.lerp(Color.WHITE, 0.08)
	m.roughness = 0.95
	m.metallic = 0.0
	m.metallic_specular = 0.15
	m.emission_enabled = true
	m.emission = c.lerp(Color.WHITE, 0.3)
	m.emission_energy_multiplier = 0.16
	return m


## ネオン。glow_hdr_threshold(1.0) を確実に超える発光。
## 使うのは1ゾーンに2〜3個まで。全面に使うと画面が滲んで
## 「ふわふわ」ではなく「ボケ」になる
static func neon_material(c: Color) -> StandardMaterial3D:
	var m := pop_material(c)
	m.albedo_color = c.lerp(Color.WHITE, 0.15)
	m.emission = c
	m.emission_energy_multiplier = 1.9
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


## 滑り台を架けた境界にはスロープを作らない。
## 歩いて降りられてしまうと滑り台を使う理由が無くなるため
static func _build_ramps(root: Node3D, mat: Material) -> void:
	for pair in WorldData.RAMP_PAIRS_X:
		if not _has_slide(pair[0], pair[1]):
			_ramp(root, pair[0], pair[1], mat, true)
	for pair in WorldData.RAMP_PAIRS_Z:
		if not _has_slide(pair[0], pair[1]):
			_ramp(root, pair[0], pair[1], mat, false)


## 順序を問わずこのゾーン対に滑り台があるか
static func _has_slide(a: int, b: int) -> bool:
	for e in WorldData.SLIDES:
		if (e[0] == a and e[1] == b) or (e[0] == b and e[1] == a):
			return true
	return false


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


## --- 転落防止の柵 -------------------------------------------------------

## 落差のある境界に柵を立て、決められた口（滑り台の入口 / スロープの取り付け口）
## からしか降りられないようにする。これが無いと高いゾーンの縁から
## どこでも飛び降りられ、滑り台もスロープも使う理由が無くなる。
##
## 柵は高い側の床に立てるので、低い側から見ると崖の上の手すりになる。
## 高さ 2.5m はジャンプ(1.38m)では越えられず、視線を切る 6m 級でもない
static func _build_parapets(root: Node3D, mat: Material) -> void:
	for pair in WorldData.RAMP_PAIRS_X:
		_parapet(root, pair[0], pair[1], mat, true)
	for pair in WorldData.RAMP_PAIRS_Z:
		_parapet(root, pair[0], pair[1], mat, false)


## a は西/北側、b は東/南側のゾーン。
## 境界の座標に沿って柵を伸ばし、通してよい場所だけ開口を残す
static func _parapet(root: Node3D, a: int, b: int, mat: Material, along_x: bool) -> void:
	var ya: float = WorldData.ZONE_GROUND[a]
	var yb: float = WorldData.ZONE_GROUND[b]
	if absf(ya - yb) < PARAPET_MIN_DROP:
		return  # 1〜2m の段差は普通に飛び降りてよい
	var hi := a if ya > yb else b
	var boundary := -WorldData.BAND if _low_side_index(a, along_x) == 0 else WorldData.BAND
	# 柵の長さ方向は高い側のゾーンの幅いっぱい
	var perp_idx: int = WorldData.ZONE_ROW[hi] if along_x else WorldData.ZONE_COL[hi]
	var perp_center: float = WorldData.AXIS_CENTER[perp_idx]
	var half: float = WorldData.AXIS_SIZE[perp_idx] * 0.5

	# 通してよい場所を集める。滑り台の入口、ジャンプ台の着地点、
	# 滑り台が無ければ中央のスロープ取り付け口
	var lo := b if hi == a else a
	var gaps: Array = []
	for e in WorldData.SLIDES:
		if e[0] == hi and e[1] == lo:
			gaps.append([perp_center + e[2], PARAPET_SLIDE_GAP * 0.5])
	if gaps.is_empty():
		gaps.append([perp_center, PARAPET_RAMP_GAP * 0.5])
	# ジャンプ台は低い側に置かれ、打ち上げで柵を越えて着地する。
	# 口を空けないと登坂ルートが消える（頂点の余裕が 1.6m しかない経路がある）
	for e in WorldData.SPRING_PADS:
		if e[3] == hi and e[0] == lo:
			var pad := WorldData.zone_point(e[0], e[1], e[2])
			gaps.append([pad.z if along_x else pad.x, PARAPET_PAD_GAP * 0.5])
	gaps.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])

	# 同じゾーンが複数の境界で高い側になるので、名前には境界の軸も入れる。
	# 名前が衝突すると Godot が @StaticBody3D@N へ自動改名し、
	# ピアごとに違う名前になりうる（ノードパスで解決する RPC の前提が崩れる）
	var tag := "%s%d%s" % [WorldData.ZONE_NAMES[hi].substr(0, 0), hi, "X" if along_x else "Z"]
	var cy := WorldData.ZONE_GROUND[hi] + PARAPET_HEIGHT * 0.5
	var cursor := perp_center - half
	var n := 0
	for g in gaps:
		n = _parapet_span(root, tag, n, along_x, boundary, cy, cursor, g[0] - g[1], mat)
		cursor = g[0] + g[1]
	_parapet_span(root, tag, n, along_x, boundary, cy, cursor, perp_center + half, mat)


## 開口の間の1区画。長さが無いなら何も作らない（口が端にある場合）
static func _parapet_span(root: Node3D, tag: String, n: int, along_x: bool, boundary: float,
		cy: float, from: float, to: float, mat: Material) -> int:
	if to - from < 0.5:
		return n
	var mid := (from + to) * 0.5
	var span := to - from
	var pos := Vector3(boundary, cy, mid) if along_x else Vector3(mid, cy, boundary)
	var size := (Vector3(PARAPET_THICK, PARAPET_HEIGHT, span) if along_x
		else Vector3(span, PARAPET_HEIGHT, PARAPET_THICK))
	_box(root, "Parapet%s_%d" % [tag, n], pos, size, mat)
	return n + 1


## --- 滑り台 -------------------------------------------------------------

## WorldData.SLIDES から一方通行のシュートを組み立て、走路の中心線を occupied 用に返す。
##
## 幾何は Platform レイヤー(8) に置く。World(1) にすると走路が歩行面として
## navmesh に焼かれ、CPU 鬼が「登れる」と誤判断して経路を引き、
## 実際には押し戻されて永久に振動する。Platform なら
## ベイクされない・通行は塞ぐ・視線も切る（SIGHT_MASK=9）の3つが同時に満たせる。
##
## 代償として、出口寄りの約5m四方はデッキの下端が agent_height(1.8m) を切るのに
## navmesh 上は歩けることになっている。そこへ入った CPU はデッキの裏に当たるが、
## これは設置ブロックとまったく同じ状況で _avoid_stuck() が横へ逃がしてくれる。
##
## CPU が滑り台を「近道として選ぶ」ことはない（navmesh に無いので目指せない）。
## たまたま走路の上を通れば逃走者と同じように滑り降りる。
## つまり滑り台は逃走者側に有利な道具であり、スロープ11本による全ゾーンの
## 連結は滑り台なしで成立している必要がある（_assert_slide_fits を参照）。
static func _build_slides(map_root: Node3D, gimmick_root: Node3D) -> Array:
	var paths: Array = []
	var deck_mat := pop_material(Color(0.62, 0.88, 1.0))
	var rail_mat := pop_material(Color(1.0, 0.62, 0.86))
	for i in WorldData.SLIDES.size():
		var pts := _slide_path(WorldData.SLIDES[i])
		_slide_body(map_root, i, pts, deck_mat, rail_mat)
		_slide_area(gimmick_root, i, pts)
		paths.append(pts)
	return paths


## 走路の中心線（＝デッキ上面）を3点で返す: 入口 / 出口 / 出口の先。
## 高い側の縁から低い側の床まで一定傾斜でまっすぐ降りる。
##
## 末尾は低い側の床と同じ高さのまま SLIDE_EXIT_RUN だけ直進する区間。
## 傾斜0なので加速はしないが最低前進速度の押し出しは効くため、
## 「出口で必ず前へ抜ける」ことが保証される。ここには幾何を作らない
static func _slide_path(e: Array) -> Array[Vector3]:
	var hi: int = e[0]
	var lo: int = e[1]
	var offset: float = e[2]
	var along_x := WorldData.ZONE_COL[hi] != WorldData.ZONE_COL[lo]
	# 境界は 2ゾーンの軸インデックスのうち小さい方が 0 なら -BAND、そうでなければ +BAND
	var ai := _low_side_index(hi, along_x)
	var bi := _low_side_index(lo, along_x)
	var boundary := -WorldData.BAND if mini(ai, bi) == 0 else WorldData.BAND
	var dir := 1.0 if bi > ai else -1.0  # 低い側へ伸びる向き
	# 高い側の床は重ねしろの分だけ低い側へせり出しているので、そのふちから始める
	var start := boundary + dir * SEAM_OVERLAP
	var ya: float = WorldData.ZONE_GROUND[hi]
	var yb: float = WorldData.ZONE_GROUND[lo]
	var run := maxf(SLIDE_MIN_RUN, absf(ya - yb) * SLIDE_RUN_PER_RISE)
	# 直交軸の座標。2ゾーンは隣接しているので直交側のゾーン中心は共通
	var perp_center: float = WorldData.AXIS_CENTER[
		WorldData.ZONE_ROW[hi] if along_x else WorldData.ZONE_COL[hi]]
	var perp := perp_center + offset
	var pts: Array[Vector3] = [
		_slide_point(along_x, start, perp, ya),
		_slide_point(along_x, start + dir * run, perp, yb),
		_slide_point(along_x, start + dir * (run + SLIDE_EXIT_RUN), perp, yb),
	]
	_assert_slide_fits(hi, lo, along_x, perp_center, pts)
	return pts


## 進行軸/直交軸の値からワールド座標を作る
static func _slide_point(along_x: bool, along: float, across: float, y: float) -> Vector3:
	return Vector3(along, y, across) if along_x else Vector3(across, y, along)


## テーブルを編集して不変条件を破ったら、その場で落として気づけるようにする。
## 走路はゾーン中心を通る十字通路（CORRIDOR_HALF）を塞がず、
## 外周の帯（WALL_OUTER_MARGIN）にも触れてはならない。
##
## ベジェの制御点から解析的に見積もらず、実際に生成した点列で判定する。
## 出口の直進区間はカーブの接線方向へ伸びるので、制御点だけを見ると見落とす
static func _assert_slide_fits(hi: int, lo: int, along_x: bool,
		perp_center: float, pts: Array[Vector3]) -> void:
	var near := INF
	var far := 0.0
	for p in pts:
		var local := absf((p.z if along_x else p.x) - perp_center)
		near = minf(near, local)
		far = maxf(far, local)
	var half_span := SLIDE_WIDTH * 0.5 + SLIDE_RAIL_W
	assert(near - half_span > CORRIDOR_HALF,
		"Slide %d->%d が十字通路を塞いでいる（横オフセットを広げるか bulge を減らす）" % [hi, lo])
	for idx in [hi, lo]:
		var ext := WorldData.zone_extent(idx)
		var limit: float = (ext.y if along_x else ext.x) * 0.5 - WALL_OUTER_MARGIN
		assert(far + half_span < limit,
			"Slide %d->%d がゾーン%d の外周帯へはみ出している" % [hi, lo, idx])


## デッキ1枚と両側のレール。姿勢は Node3D 既定の EULER_ORDER_YXZ で
## 「ヨー -> ピッチ」の順に効く。_box() は body.rotation に代入するだけなので、
## メッシュとコリジョンは必ず同じ姿勢を共有する。
##
## 出口の先（pts[1] -> pts[2]）には幾何を作らない。低い側の床と同じ高さなので
## デッキは床に埋まって無意味だし、レールだけが平地に5m残ってしまう。
## 勢いを逃がす役目は Area 側だけが担う
static func _slide_body(root: Node3D, n: int, pts: Array[Vector3],
		deck_mat: Material, rail_mat: Material) -> void:
	var rot := _slide_rotation(pts[0], pts[1])
	var basis := Basis.from_euler(rot, EULER_ORDER_YXZ)
	# 下端だけ伸ばすので、中心も伸ばした分の半分だけ下へずらす
	var span := pts[0].distance_to(pts[1]) + SLIDE_END_TUCK
	var down := (pts[1] - pts[0]).normalized()
	# 中心線はデッキ「上面」。厚みの半分だけ法線方向に沈める
	var top := (pts[0] + pts[1]) * 0.5 + down * (SLIDE_END_TUCK * 0.5)
	var deck := _box(root, "SlideDeck%d" % n, top - basis.y * (SLIDE_THICK * 0.5),
		Vector3(SLIDE_WIDTH, SLIDE_THICK, span), deck_mat, rot)
	deck.collision_layer = 8
	for s: float in [-1.0, 1.0]:
		var rail := _box(root, "SlideRail%d%s" % [n, "L" if s < 0.0 else "R"],
			top + basis.x * (s * (SLIDE_WIDTH - SLIDE_RAIL_W) * 0.5)
				+ basis.y * (SLIDE_RAIL_H * 0.5),
			Vector3(SLIDE_RAIL_W, SLIDE_RAIL_H, span), rail_mat, rot)
		rail.collision_layer = 8


## 滑走判定の Area。走路の1枚と出口の平地の2枚。
## 形状はデッキと同じ変数から作って上方へ伸ばすので、
## 「Area の外側でデッキの上に立つ」抜け道が構成的に塞がる
static func _slide_area(root: Node3D, n: int, pts: Array[Vector3]) -> void:
	var area := Area3D.new()
	area.name = "Slide%d" % n
	area.collision_layer = 0
	area.collision_mask = 2  # Character
	area.set_script(SLIDE_SCRIPT)
	area.center_line = PackedVector3Array(pts)
	area.cap = SLIDE_CAP
	for i in pts.size() - 1:
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[i + 1]
		var rot := _slide_rotation(a, b)
		var basis := Basis.from_euler(rot, EULER_ORDER_YXZ)
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(SLIDE_WIDTH, SLIDE_AREA_HEIGHT, a.distance_to(b))
		col.shape = box
		col.position = (a + b) * 0.5 + basis.y * (SLIDE_AREA_HEIGHT * 0.5)
		col.rotation = rot
		area.add_child(col)
	root.add_child(area)


## a から b へ向く姿勢。-Z を進行方向にする（既存の向きの規約と同じ）
static func _slide_rotation(a: Vector3, b: Vector3) -> Vector3:
	var d := b - a
	return Vector3(asin(clampf(d.y / d.length(), -1.0, 1.0)), atan2(-d.x, -d.z), 0.0)


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


## 視線を切る構造物。ゾーンごとに4象限へ配り、種類はそのゾーンのテーマから引く。
##
## 袋小路を作らない保証: プロップは外から見て凸な塊だけで、内部に入れる空間を持たない。
## 内部が無い以上、単体では袋小路にならない。閉じたリングを構成しないことは、
## 隣り合うプロップの隙間が常に WALL_GAP(2.5m ＝ agent_radius 0.45 の 2.7倍)
## 以上あることから従う。加えて CORRIDOR_HALF の十字通路と
## WALL_OUTER_MARGIN の外周帯は常に完全に開いている。
static func _build_props(root: Node3D, mats: Array[StandardMaterial3D],
		occupied: Array[Vector3]) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldData.BUILD_SEED + 2
	for idx in WorldData.ZONE_COUNT:
		var center := WorldData.zone_center(idx)
		var ext := WorldData.zone_extent(idx)
		var theme: Array = WorldData.ZONE_THEMES[idx]
		var hi_x := ext.x * 0.5 - WALL_OUTER_MARGIN
		var hi_z := ext.y * 0.5 - WALL_OUTER_MARGIN
		var placed: Array = []  # [中心Vector3, 半径Vector2]
		var n := 0
		# ゾーンの目印を先に建てる。手で置いた座標なので必ず建ち、
		# 後続のプロップはこれを避ける
		var mark: Array = WorldData.ZONE_LANDMARKS[idx]
		var mark_span: float = SIGHT_WALL_MAX_LEN * mark[4] * 0.5
		var mark_pos := Vector3(center.x + mark[1], center.y, center.z + mark[2])
		_prop(root, "Landmark%d" % idx, mark[3], mark_pos, mark_span, true, mats[idx])
		placed.append([mark_pos, _prop_footprint(mark[3], mark_span, true)])

		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				for k in WALLS_PER_QUADRANT:
					if n >= WALLS_PER_ZONE:
						break
					# 乱数はスキップ判定より前に引き切る。
					# こうしておけばキープアウト条件を足しても他の配置がずれない
					var along_x := rng.randi() % 2 == 0
					var want_len := rng.randf_range(SIGHT_WALL_MIN_LEN, SIGHT_WALL_MAX_LEN)
					var u := rng.randf()
					var v := rng.randf()
					var kind := _pick_prop(theme, rng.randf())
					var span := (hi_x if along_x else hi_z) - CORRIDOR_HALF
					if span < SIGHT_WALL_MIN_LEN:
						continue
					var prop_len := minf(want_len, span)
					# 丸物は長すぎると太い柱になってしまうので細めに寄せる
					if kind == WorldData.Prop.TOWER or kind == WorldData.Prop.PIPE:
						prop_len *= ROUND_PROP_SCALE
					# 長手方向は象限の帯の中で、短手方向は十字と外周を避けて配置する
					var along := lerpf(CORRIDOR_HALF + prop_len * 0.5,
						(hi_x if along_x else hi_z) - prop_len * 0.5, u)
					var across := lerpf(CORRIDOR_HALF + 1.0,
						(hi_z if along_x else hi_x) - 1.0, v)
					var lx := (along if along_x else across) * sx
					var lz := (across if along_x else along) * sz
					var half := _prop_footprint(kind, prop_len, along_x)
					var pos := Vector3(center.x + lx, center.y, center.z + lz)
					if _rect_too_close(pos, half, occupied, WALL_CLEARANCE):
						continue
					var clash := false
					for e in placed:
						if _rect_too_close(pos, half + e[1], [e[0]] as Array[Vector3], WALL_GAP):
							clash = true
							break
					if clash:
						continue
					_prop(root, "Prop%d_%d" % [idx, n], kind, pos, prop_len, along_x, mats[idx])
					placed.append([pos, half])
					n += 1


## --- テーマ構造物 -------------------------------------------------------
## いずれも「地面から SIGHT_WALL_HEIGHT 以上まで途切れずに塞ぐ凸の塊」。
## 視線レイ(y=0.85 / 1.55)を確実に遮り、カメラ(最大 3.6m)からも見通せない。
## 天面は 60°超のキャップで終えるので歩行面にならず、孤立したナビ島も生まれない。
## 加えて TopGuard を必ず載せて、飛び乗られても弾き出す。
##
## size は水平方向の代表寸法。footprint(=占有する半径)は _prop_footprint と揃えること

## 円柱＋円錐の塔。母線は atan(高さ/半径) が 60° を超えるようにする
static func _prop_tower(root: Node3D, node_name: String, base: Vector3, d: float,
		mat: Material) -> void:
	var body_h := SIGHT_WALL_HEIGHT * 0.62
	var cap_h := d * 0.5 * 1.85  # 半径に対して 1.85倍 = 61.6°
	_solid(root, node_name, base + Vector3(0, body_h * 0.5, 0),
		Vector3(d, body_h, d), mat, Shape.CYLINDER)
	_solid(root, node_name + "Cap", base + Vector3(0, body_h + cap_h * 0.5, 0),
		Vector3(d * 1.12, cap_h, d * 1.12), mat, Shape.CONE, Vector3.ZERO, 1, true)


## 立ち上がり配管。塔より細く高い
static func _prop_pipe(root: Node3D, node_name: String, base: Vector3, d: float,
		mat: Material) -> void:
	var body_h := SIGHT_WALL_HEIGHT * 0.85
	var cap_h := d * 0.5 * 1.9
	_solid(root, node_name, base + Vector3(0, body_h * 0.5, 0),
		Vector3(d, body_h, d), mat, Shape.CYLINDER)
	_solid(root, node_name + "Cap", base + Vector3(0, body_h + cap_h * 0.5, 0),
		Vector3(d * 1.25, cap_h, d * 1.25), mat, Shape.CONE, Vector3.ZERO, 1, true)


## 貨物コンテナ／積み木。壁より厚みがあり、屋根型の笠木で締める
static func _prop_crate(root: Node3D, node_name: String, base: Vector3, span: float,
		along_x: bool, mat: Material) -> void:
	var box_h := SIGHT_WALL_HEIGHT - WALL_CAP_HEIGHT
	var depth := CRATE_DEPTH
	var size := (Vector3(span, box_h, depth) if along_x else Vector3(depth, box_h, span))
	var body := _solid(root, node_name, base + Vector3(0, box_h * 0.5, 0), size, mat)
	_wall_cap(body, span, along_x, box_h, mat, depth)


## 従来の視線壁。テーマの中では「城壁 / 生垣」として使う
static func _prop_wall(root: Node3D, node_name: String, base: Vector3, span: float,
		along_x: bool, mat: Material) -> void:
	var box_h := SIGHT_WALL_HEIGHT - WALL_CAP_HEIGHT
	var size := (Vector3(span, box_h, SIGHT_WALL_THICK) if along_x
		else Vector3(SIGHT_WALL_THICK, box_h, span))
	var body := _solid(root, node_name, base + Vector3(0, box_h * 0.5, 0), size, mat)
	_wall_cap(body, span, along_x, box_h, mat, SIGHT_WALL_THICK)


## プロップ1個を建てる。base は地面の高さ
static func _prop(root: Node3D, node_name: String, kind: int, base: Vector3,
		span: float, along_x: bool, mat: Material) -> void:
	match kind:
		WorldData.Prop.TOWER:
			_prop_tower(root, node_name, base, span, mat)
		WorldData.Prop.PIPE:
			_prop_pipe(root, node_name, base, span, mat)
		WorldData.Prop.CRATE:
			_prop_crate(root, node_name, base, span, along_x, mat)
		_:
			_prop_wall(root, node_name, base, span, along_x, mat)


## 占有する矩形の半径。配置側のクリアランス判定はこれを使う。
## 丸物は差し渡しがそのまま直径なので正方形で押さえる
static func _prop_footprint(kind: int, span: float, along_x: bool) -> Vector2:
	match kind:
		WorldData.Prop.TOWER, WorldData.Prop.PIPE:
			return Vector2(span, span) * 0.5
		WorldData.Prop.CRATE:
			return (Vector2(span, CRATE_DEPTH) if along_x
				else Vector2(CRATE_DEPTH, span)) * 0.5
		_:
			return (Vector2(span, SIGHT_WALL_THICK) if along_x
				else Vector2(SIGHT_WALL_THICK, span)) * 0.5


## 重み表から種類を1つ引く。u は 0..1 の乱数
static func _pick_prop(theme: Array, u: float) -> int:
	var total := 0.0
	for e in theme:
		total += e[1]
	var t := u * total
	for e in theme:
		t -= e[1]
		if t <= 0.0:
			return e[0]
	return theme[theme.size() - 1][0]


## 壁の天面に屋根型の笠木を付けて、乗っても滑り落ちるようにする。
## PrismMesh は +Y が稜線・Z 方向へ押し出されるので、
## 壁が X 方向に伸びている場合は Y 軸まわりに 90° 回す。
##
## 笠木だけでは塞ぎきれない（稜線の真上ではカプセルの接触法線が真上になり
## 立ててしまう）ので、天面を覆う Area3D を重ねて確実に弾き出す。
static func _wall_cap(body: StaticBody3D, wall_len: float, along_x: bool,
		box_h: float, mat: Material, thick := SIGHT_WALL_THICK) -> void:
	var prism := PrismMesh.new()
	prism.size = Vector3(thick, WALL_CAP_HEIGHT, wall_len)
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
	gbox.size = Vector3(thick, WALL_CAP_HEIGHT + 2.0, wall_len)
	guard.shape = gbox
	guard.position = Vector3(0, (WALL_CAP_HEIGHT + 2.0) * 0.5 - WALL_CAP_HEIGHT * 0.5, 0)
	area.position = Vector3(0, cap_y, 0)
	if along_x:
		area.rotation.y = PI * 0.5
	area.add_child(guard)
	body.add_child(area)


## プロップの天面を覆って上に立てなくする。_wall_cap の TopGuard を汎用化したもの。
## 形（丸い / 尖った）に関係なく確実に弾き出せるので、
## 「ふわふわした丸いシルエット」と「上に立てない」を両立できる。
##
## ただし navmesh のベイク（World レイヤー）はこの Area を見ないので、
## 緩い上面を持つ丸物は Platform レイヤーへ回して Recast から隠すこと。
## でないと構造物の天面に孤立したナビ島ができる
static func _top_guard(body: StaticBody3D, size: Vector3) -> void:
	var area := Area3D.new()
	area.name = "TopGuard"
	area.collision_layer = 0
	area.collision_mask = 2  # Character
	area.set_script(WALL_TOP_SCRIPT)
	var guard := CollisionShape3D.new()
	var gbox := BoxShape3D.new()
	# 天面より上に十分な厚みを持たせ、飛び乗った瞬間に必ず領域へ入るようにする
	gbox.size = Vector3(size.x * 1.05, GUARD_THICK, maxf(size.z, size.x) * 1.05)
	guard.shape = gbox
	area.position = Vector3(0, size.y * 0.5 + GUARD_THICK * 0.4, 0)
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


## 見た目と当たり判定を必ず同じ元データから作る唯一の場所。
## プリミティブのシェイプが厳密に一致する形だけ専用シェイプを使い、
## それ以外（円錐・角柱・潰した球）は必ず mesh.create_convex_shape() で起こす。
## こうしておけば「メッシュだけ変えてコリジョンを直し忘れる」が構造的に起きない。
##
## size の意味は形ごとに違う:
##   BOX / PRISM  (幅, 高さ, 奥行)
##   CYLINDER     (直径, 高さ, -)
##   CONE         (底面の直径, 高さ, -)   ※先端が上
##   SPHERE       (直径, 高さ, -)         ※高さを変えると潰れた球
##   CAPSULE      (直径, 全高, -)
##
## no_stand を立てると天面を覆う Area3D が付き、上に立てなくなる。
## 丸い形は傾斜だけでは防げない（球面の頂点付近は接線角が連続的に0になり、
## 半径3mのドームなら直径4.2mの「立てる平地」が天辺にできる）ため、
## 形に頼らずこの Area で弾き出す。
static func _solid(root: Node3D, node_name: String, pos: Vector3, size: Vector3,
		mat: Material, kind := Shape.BOX, rot := Vector3.ZERO,
		layer := 1, no_stand := false) -> StaticBody3D:
	var mesh: Mesh
	var shape: Shape3D = null
	match kind:
		Shape.CYLINDER:
			var c := CylinderMesh.new()
			c.top_radius = size.x * 0.5
			c.bottom_radius = size.x * 0.5
			c.height = size.y
			c.radial_segments = ROUND_SEGMENTS
			mesh = c
			var s := CylinderShape3D.new()
			s.radius = size.x * 0.5
			s.height = size.y
			shape = s
		Shape.CONE:
			# 母線の傾斜が 60° を超えるようにすれば歩行面にもならない
			var c := CylinderMesh.new()
			c.top_radius = 0.0
			c.bottom_radius = size.x * 0.5
			c.height = size.y
			c.radial_segments = ROUND_SEGMENTS
			mesh = c
		Shape.SPHERE:
			var s := SphereMesh.new()
			s.radius = size.x * 0.5
			s.height = size.y
			s.radial_segments = ROUND_SEGMENTS
			s.rings = ROUND_RINGS
			mesh = s
			if is_equal_approx(size.y, size.x):
				var c := SphereShape3D.new()
				c.radius = size.x * 0.5
				shape = c
		Shape.CAPSULE:
			var c := CapsuleMesh.new()
			c.radius = size.x * 0.5
			c.height = maxf(size.y, size.x * 1.01)  # 全高は直径を下回れない
			c.radial_segments = ROUND_SEGMENTS
			c.rings = ROUND_RINGS
			mesh = c
			var s := CapsuleShape3D.new()
			s.radius = c.radius
			s.height = c.height
			shape = s
		Shape.PRISM:
			var p := PrismMesh.new()
			p.size = size
			mesh = p
		_:
			var b := BoxMesh.new()
			b.size = size
			mesh = b
			var s := BoxShape3D.new()
			s.size = size
			shape = s
	mesh.surface_set_material(0, mat)

	var body := StaticBody3D.new()
	body.name = node_name
	body.position = pos
	body.rotation = rot
	body.collision_layer = layer
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	body.add_child(mi)
	var col := CollisionShape3D.new()
	# 専用シェイプが無い形はメッシュから凸包を起こす。
	# メッシュのパラメータを変えれば当たり判定も自動で追従する
	col.shape = shape if shape != null else mesh.create_convex_shape()
	body.add_child(col)
	root.add_child(body)
	if no_stand:
		_top_guard(body, size)
	return body


## 従来の呼び出し口。既存のコードは全てこちらを通る
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
