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
const SLIDE_AREA_SIDE_INSET := 0.05  # 手すり外側を巻き込まないよう左右を少し狭める
const SLIDE_EXIT_RUN := 1.5     # 出口から先、平地に伸ばす Area の長さ（下側から近づきやすくする）
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
## マンホールのリンクの端点を、マンホールの中心からずらす距離。
## 中心に両端点を置くと CPU は「相手のフタの上」へ直接移動してしまい、
## 途中でフタを踏まないのでワープが発動しない。相手と反対側の足元へ逃がしておけば、
## 端点から相手へ一直線に歩くと必ずフタの上（判定 半径1.1m）を通る。
## GIMMICK_CLEARANCE(3.5) の内側なので、この位置に壁が生えないことも保証される
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
## 外周4隅の面取り長さ。壁が直角に交差したままだと move_and_slide() が
## 2枚の壁の法線を相殺してキャラがその場で詰まる（部屋の角にハマる典型例）。
## 対角の壁面で1つに減らし、速度を斜めへ逃がせるようにする
const WALL_CORNER_CHAMFER := 4.0
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


## --- 描画の集約 ---------------------------------------------------------
## 同じ形・同じマテリアルの構造物を1本の MultiMesh にまとめる。
## 描画コストに乗るのは MeshInstance3D だけなので、当たり判定の
## StaticBody3D + CollisionShape3D は今まで通り1個ずつ残したままでよい。
##
## 見た目と当たり判定の一致（この設計の一番の肝）は、
## MultiMesh のインスタンス transform と CollisionShape3D の両方を
## _solid() の中で同じ pos / size / rot から作ることで保つ。
## 集約の都合でどちらか片方だけを触れる場所は作らない。
##
## 形は単位サイズ（一辺1 / 直径1 / 高さ1）で持ち、大きさはインスタンスの
## 拡大率で作る。そうしないと大きさ違いが全部別グループになって集約にならない。
## 軸に沿った拡大なので法線は逆転置行列で正しく補正される
## （円柱の側面法線は水平のままだし、円錐は傾きが変わるのが正しい）。
##
## 除外する形が2つある:
##   CAPSULE - 全高に半球が含まれるので、単位形状を非等方に拡大しても元の形に戻らない
##   CONE    - 側面の法線が斜めなので、非等方に拡大すると陰影が変わる。
##             箱と角柱の法線は軸に沿っているので拡大しても向きが変わらず、
##             円柱の側面法線は水平なので縦の拡大に影響されない（だから集約してよい）。
##             円錐だけは屋根として大きく映るので、見た目を優先して個別に描く
class Batch:
	extends RefCounted

	## key -> [単位メッシュ, Array[Transform3D]]
	var _groups := {}

	func add(kind: int, pos: Vector3, size: Vector3, rot: Vector3,
			mat: Material, shadow: bool) -> void:
		var key := "%d_%d_%d" % [kind, mat.get_instance_id(), 1 if shadow else 0]
		if not _groups.has(key):
			_groups[key] = [_unit_mesh(kind, mat), [] as Array[Transform3D], shadow]
		# ローカルで拡大してから回す（R * S）。逆順にすると斜めに歪む
		var basis := Basis.from_euler(rot, EULER_ORDER_YXZ) * Basis.from_scale(size)
		_groups[key][1].append(Transform3D(basis, pos))

	static func can_batch(kind: int) -> bool:
		return kind != Shape.CAPSULE and kind != Shape.CONE

	func flush(root: Node3D) -> void:
		var n := 0
		for key in _groups:
			var g: Array = _groups[key]
			var transforms: Array[Transform3D] = g[1]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = g[0]
			mm.instance_count = transforms.size()
			for i in transforms.size():
				mm.set_instance_transform(i, transforms[i])
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "PropBatch%d" % n
			mmi.multimesh = mm
			if not g[2]:
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(mmi)
			n += 1

	func stats() -> String:
		var total := 0
		for key in _groups:
			total += (_groups[key][1] as Array).size()
		return "%d個 -> %d本" % [total, _groups.size()]

	## 内部クラスからは外側の static func を呼べないので、ここだけは
	## _set_subdiv() を使わず直接代入する（定数は外側から引ける）
	static func _unit_mesh(kind: int, mat: Material) -> Mesh:
		var mesh: Mesh
		match kind:
			Shape.CYLINDER, Shape.CONE:
				var c := CylinderMesh.new()
				c.top_radius = 0.0 if kind == Shape.CONE else 0.5
				c.bottom_radius = 0.5
				c.height = 1.0
				c.radial_segments = ROUND_SEGMENTS
				mesh = c
			Shape.SPHERE:
				var s := SphereMesh.new()
				s.radius = 0.5
				s.height = 1.0
				s.radial_segments = ROUND_SEGMENTS
				s.rings = ROUND_RINGS
				mesh = s
			Shape.PRISM:
				var p := PrismMesh.new()
				p.size = Vector3.ONE
				p.subdivide_width = BATCH_BOX_SUBDIV
				p.subdivide_height = BATCH_BOX_SUBDIV
				p.subdivide_depth = BATCH_BOX_SUBDIV
				mesh = p
			_:
				var b := BoxMesh.new()
				b.size = Vector3.ONE
				b.subdivide_width = BATCH_BOX_SUBDIV
				b.subdivide_height = BATCH_BOX_SUBDIV
				b.subdivide_depth = BATCH_BOX_SUBDIV
				mesh = b
		mesh.surface_set_material(0, mat)
		return mesh

## 丸物の分割数。塔と配管の胴は MultiMesh へ集約済み、円錐の笠と球は
## 個数が知れているので、頂点が増えてもドローコールは1本も増えない
const ROUND_SEGMENTS := 20
## リングだけ控えめなのは、潰した球（バンパー）が専用シェイプを持てず
## create_convex_shape() で凸包を起こすため。頂点数が当たり判定のコストへ直結する。
## シルエットの滑らかさは radial_segments がほぼ全部決めるので実害は無い
const ROUND_RINGS := 8
## 平らな面をこの長さごとに分割する。
## gl_compatibility はフォグを頂点シェーダで計算するので、55m 四方の床を
## 2枚の三角形で貼ると距離が対角線に沿って線形補間され、対角線の折れ目と
## 段になった帯がそのまま画面に出る（旧 tests/shots/ground.png の赤い床）。
##
## 誤差は区間長の2乗で効くので、55m を 9m に割るだけで約37分の1になる。
## 4.5m まで詰めた版と撮り比べたが画素の差はほぼ無く、三角形だけが
## 1万5千本増えた。見た目が同じなら軽い方を採る。
## 重いと感じたら上げるだけで全体の分割が一段荒くなる（レバーはこの1定数）
const MESH_SEGMENT_M := 9.0
## 1辺あたりの分割上限。外周壁(162m)でも 24 で頭打ちにする
const MESH_SEGMENT_MAX := 24
## MultiMesh の単位メッシュは 1x1x1 をインスタンス側で拡大するので実寸が無い。
## 集約するプロップは 6〜9m しかないので固定値で足りる
const BATCH_BOX_SUBDIV := 2
const GUARD_THICK := 3.0  # 天面ガードの厚み。飛び乗った瞬間に必ず入る高さ
## 丸いプロップの直径は「壁の長さ」をそのまま使うと太すぎるので縮める
const ROUND_PROP_SCALE := 0.55
const CRATE_DEPTH := 3.4  # コンテナの奥行き。壁(1.2)より厚く、通路を潰さない程度


## --- バンパー -----------------------------------------------------------
## 以前ここには当たり判定の無い緑のドームを飾りとして撒いていたが、
## 走ると素通りしてしまい、置いてある意味が無かった。
## 実体のある丸い障害物にして、触れると外向きに弾き返す。
##
## Platform レイヤー(8)に置く。丸い天面はどう作っても頂点付近が平らになるので、
## World(1) に置くと「登れないのに歩ける」孤立したナビ島がドームの上に焼かれる。
## Platform ならベイクされず、通行は塞ぎ、視線も切れる。
## 高さを 3.5m 未満に抑えてあるので、切れるのは低い側の視線レイ(y=0.85)だけ。
## 高い側(y=1.55)は通り、can_see は「どちらか通れば視認」なので
## 「画面では見えているのに見つからない」の破綻は起こらない
## ゾーンあたりの数は絞る。バンパーが増えるほど視線を切るプロップの居場所が減り、
## 逃走者が隠れる場所が痩せる（遮蔽の役目を負うのは 6m のプロップ側）
const BUMPER_PER_ZONE := 2
const BUMPER_TRIES := 3  # 象限あたりの試行回数。置けるのは象限に1個まで
const QUADRANTS: Array[Vector2] = [
	Vector2(-1, -1), Vector2(-1, 1), Vector2(1, -1), Vector2(1, 1)]
const BUMPER_D := 4.4  # 差し渡し
const BUMPER_H := 2.2
const BUMPER_PAD := 0.5  # 弾き返す Area を幾何より外へ張り出す量
const BUMPER_VISUAL_STYLE := 9  # 7: リングクッション / 9: 半透明ドーム


const SPRING_SCENE := preload("res://scenes/gimmicks/spring_pad.tscn")
const BOOST_SCENE := preload("res://scenes/gimmicks/boost_panel.tscn")
const MANHOLE_SCENE := preload("res://scenes/gimmicks/manhole.tscn")
const QBLOCK_SCENE := preload("res://scenes/gimmicks/question_block.tscn")
const LIFT_SCENE := preload("res://scenes/gimmicks/moving_platform.tscn")
const SPINNER_SCENE := preload("res://scenes/gimmicks/rotating_platform.tscn")
const WALL_TOP_SCRIPT := preload("res://scenes/gimmicks/wall_top.gd")
const SLIDE_SCRIPT := preload("res://scenes/gimmicks/slide.gd")
const BUMPER_SCRIPT := preload("res://scenes/gimmicks/bumper.gd")
const FLOAT_SHADER := preload("res://scenes/decor_float.gdshader")


static func build(map_root: Node3D, gimmick_root: Node3D, decor_root: Node3D) -> void:
	var zone_mats: Array[StandardMaterial3D] = []
	for idx in WorldData.ZONE_COUNT:
		zone_mats.append(pop_material(WorldData.ZONE_COLORS[idx]))
	_build_slabs(map_root, zone_mats)
	# スロープは設置されている各ゾーンのテーマ色で生成
	_build_ramps(map_root, zone_mats)
	var wall_mat := pop_material(Color(0.24, 0.18, 0.38))
	_build_walls(map_root, wall_mat)
	_build_wall_corners(map_root, wall_mat)
	_build_parapets(map_root, zone_mats)
	# 後から置く物が先に置いた物へ重ならないよう、確定した位置を順に積み上げていく
	var occupied := _build_gimmicks(gimmick_root, zone_mats)
	# 滑り台の走路は「面」なので点列では守れない。矩形のキープアウトとして
	# 後続の配置へ渡す（詳細は _slide_rects）
	var slide_paths := _build_slides(map_root, gimmick_root)
	var keepout := _slide_rects(slide_paths)
	keepout.append_array(_landmark_rects())
	_build_nav_links(gimmick_root, slide_paths)
	# 構造物・遮蔽ブロック・バンパーは各ゾーンのテーマ色で統一して建てる
	var accent_mats: Array[StandardMaterial3D] = []
	for idx in WorldData.ZONE_COUNT:
		accent_mats.append(soft_material(WorldData.ZONE_COLORS[idx]))
	occupied.append_array(
		_build_cover(map_root, accent_mats, occupied, keepout))
	# バンパーはプロップより先に建てて、自分の矩形を keepout へ積む。
	# こうしないと後から建つ壁がバンパーにめり込む
	_build_bumpers(map_root, accent_mats, occupied, keepout)
	# 構造物の描画は MultiMesh へ集約する。当たり判定は _solid() が
	# 1個ずつ StaticBody3D として作ったまま残るので、通行・視線・ベイクは変わらない
	var batch := Batch.new()
	_build_props(map_root, accent_mats, occupied, keepout, batch)
	batch.flush(map_root)
	_build_decor(decor_root)


## ノード名は明示的に振る。？ブロックの RPC はノードパスで解決されるため、
## 全ピアで名前が一致していることが前提になる（自動採番に任せない）。
static func _build_gimmicks(root: Node3D, mats: Array[StandardMaterial3D] = []) -> Array[Vector3]:
	var occupied: Array[Vector3] = []
	for i in WorldData.SPRING_PADS.size():
		var e: Array = WorldData.SPRING_PADS[i]
		var pos := _place(root, SPRING_SCENE, "SpringPad%d" % i, e)
		_assert_clear_of_ramps(e[0], pos, "SpringPad%d" % i)
		occupied.append(pos)
	for i in WorldData.BOOST_PANELS.size():
		var e: Array = WorldData.BOOST_PANELS[i]
		var pos := _place(root, BOOST_SCENE, "BoostPanel%d" % i, e, e[3])
		_assert_clear_of_ramps(e[0], pos, "BoostPanel%d" % i)
		occupied.append(pos)
	for i in WorldData.QUESTION_BLOCKS.size():
		var e: Array = WorldData.QUESTION_BLOCKS[i]
		occupied.append(_place(root, QBLOCK_SCENE, "QuestionBlock%d" % i, e))
	# マンホールはテーブル上で2基ずつペアになっているので相互に参照させる
	var manholes: Array[Node3D] = []
	for i in WorldData.MANHOLES.size():
		var e: Array = WorldData.MANHOLES[i]
		var pos := _place(root, MANHOLE_SCENE, "Manhole%d" % i, e)
		_assert_clear_of_ramps(e[0], pos, "Manhole%d" % i)
		occupied.append(pos)
		manholes.append(root.get_node("Manhole%d" % i))
	for i in range(0, manholes.size() - 1, 2):
		manholes[i].pair = manholes[i + 1]
		manholes[i + 1].pair = manholes[i]
	# 動く床・回転床は高さ指定があるので個別に配置する
	for i in WorldData.MOVING_PLATFORMS.size():
		var e: Array = WorldData.MOVING_PLATFORMS[i]
		var n: Node3D = LIFT_SCENE.instantiate()
		n.name = "MovingPlatform%d" % i
		n.position = WorldData.zone_point(e[0], e[1], e[3]) + Vector3(0, e[2], 0)
		n.travel = Vector3(e[4], e[5], e[6])
		n.period = e[7]
		if not mats.is_empty() and e[0] < mats.size():
			var mesh_inst := n.get_node_or_null("Mesh") as MeshInstance3D
			if mesh_inst != null:
				mesh_inst.material_override = mats[e[0]]
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
		if not mats.is_empty() and e[0] < mats.size():
			var mesh_inst := n.get_node_or_null("Mesh") as MeshInstance3D
			if mesh_inst != null:
				mesh_inst.material_override = mats[e[0]]
		root.add_child(n)
		occupied.append(n.position)
	return occupied


## CPU 鬼の経路探索用のリンク。柵とスロープ撤去で高いゾーンは歩いて出入りできなくなり、
## 滑り台の幾何は Platform レイヤーでベイクもされないため、
## これが無いと CLOUD DECK / SKY STEPS が CPU の来ない安全地帯になってしまう。
##
## 滑り台は一方通行にする（bidirectional = false）。双方向にすると
## CPU が「登れる」と誤解して経路を引き、押し戻されて永久に振動する。
## マンホールは元から双方向なので、これが CPU にとって唯一の登坂ルートになる。
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
	var holes := WorldData.MANHOLES
	for i in range(0, holes.size() - 1, 2):
		var a: Array = holes[i]
		var b: Array = holes[i + 1]
		var pa := WorldData.zone_point(a[0], a[1], a[2])
		var pb := WorldData.zone_point(b[0], b[1], b[2])
		# 端点はマンホールの中心ではなく「相手と反対側の足元」に置く。
		# 中心に置くと CPU は相手のフタの上へ直接移動してしまい、途中で
		# フタを踏まないのでワープが起きない。この位置なら端点から相手へ
		# 一直線に歩くと必ずフタの上を通るので、経路をたどるだけで
		# manhole の Area に入る
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


## ふわふわの基調材。彩度を保ちつつ適度な粗さを設定。
## 影側が沈まないよう、発光はアルベドよりわずかに明るい色にする。
## rim_enabled は Compatibility での挙動が不確実なので使わず、これで縁の明るさを作る
static func soft_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c.lerp(Color.WHITE, 0.02)
	m.roughness = 0.95
	m.metallic = 0.0
	m.metallic_specular = 0.15
	m.emission_enabled = true
	m.emission = c.lerp(Color.WHITE, 0.12)
	m.emission_energy_multiplier = 0.14
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
		var ground_y: float = WorldData.ZONE_GROUND[idx]
		var x0 := center.x - ext.x * 0.5
		var x1 := center.x + ext.x * 0.5
		var z0 := center.z - ext.y * 0.5
		var z1 := center.z + ext.y * 0.5
		# 隣接ゾーンと同じ高さ（段差なし）の場合は、同一平面でのポリゴン重複による
		# Z-fighting（点滅・ガビガビ）を防ぐため重ねしろをつけず突き合わせにする。
		# 段差がある場合（崖）は隙間落下防止のため従来どおり重ねしろを設ける。
		if col > 0 and absf(ground_y - WorldData.ZONE_GROUND[idx - 1]) >= 0.05:
			x0 -= SEAM_OVERLAP
		if col < 2 and absf(ground_y - WorldData.ZONE_GROUND[idx + 1]) >= 0.05:
			x1 += SEAM_OVERLAP
		if row > 0 and absf(ground_y - WorldData.ZONE_GROUND[idx - 3]) >= 0.05:
			z0 -= SEAM_OVERLAP
		if row < 2 and absf(ground_y - WorldData.ZONE_GROUND[idx + 3]) >= 0.05:
			z1 += SEAM_OVERLAP
		var h: float = center.y - WorldData.SLAB_BOTTOM
		_box(root, "Zone%d" % idx,
			Vector3((x0 + x1) * 0.5, center.y - h * 0.5, (z0 + z1) * 0.5),
			Vector3(x1 - x0, h, z1 - z0), mats[idx])


## 滑り台を架けた境界にはスロープを作らない。
## 歩いて降りられてしまうと滑り台を使う理由が無くなるため
static func _build_ramps(root: Node3D, mats: Array[StandardMaterial3D]) -> void:
	for pair in WorldData.RAMP_PAIRS_X:
		if not _has_slide(pair[0], pair[1]):
			_ramp(root, pair[0], pair[1], mats, true)
	for pair in WorldData.RAMP_PAIRS_Z:
		if not _has_slide(pair[0], pair[1]):
			_ramp(root, pair[0], pair[1], mats, false)


## 順序を問わずこのゾーン対に滑り台があるか
static func _has_slide(a: int, b: int) -> bool:
	for e in WorldData.SLIDES:
		if (e[0] == a and e[1] == b) or (e[0] == b and e[1] == a):
			return true
	return false


## a は西/北側、b は東/南側のゾーン。
## スロープは境界から「低い側のゾーン」へ向かって伸ばすので、
## 高い側の崖のふちにぴたりと接続され、低い側の床に滑らかに着地する。
static func _ramp(root: Node3D, a: int, b: int, mats: Array[StandardMaterial3D], along_x: bool) -> void:
	var ya: float = WorldData.ZONE_GROUND[a]
	var yb: float = WorldData.ZONE_GROUND[b]
	var rise := absf(yb - ya)
	if rise < 0.05:
		return  # 段差なし。床同士が直接つながっている
	var lo := a if ya < yb else b
	var mat: Material = mats[lo] if lo < mats.size() else null
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


## テーブルを編集して不変条件を破ったら、その場で落として気づけるようにする
## (_assert_slide_fits と同じ方針)。マンホールやジャンプ台などのギミックは
## 地面と面一に置かれる前提のため、傾斜の途中に置くとめり込みや動作不良の原因になる
static func _assert_clear_of_ramps(idx: int, pos: Vector3, node_name: String) -> void:
	for pair in WorldData.RAMP_PAIRS_X:
		_assert_clear_of_ramp(idx, pos, pair[0], pair[1], true, node_name)
	for pair in WorldData.RAMP_PAIRS_Z:
		_assert_clear_of_ramp(idx, pos, pair[0], pair[1], false, node_name)


## a-b 間のランプ(スロープ)が占める範囲に pos が入っていないか確認する。
## _ramp() と同じ式で「低い側のゾーンへ rise*RAMP_RUN_PER_RISE(最低 RAMP_MIN_RUN) だけ
## 食い込む」範囲を求め、対象ゾーンがその低い側で無ければ何もしない
static func _assert_clear_of_ramp(idx: int, pos: Vector3, a: int, b: int,
		along_x: bool, node_name: String) -> void:
	var ya: float = WorldData.ZONE_GROUND[a]
	var yb: float = WorldData.ZONE_GROUND[b]
	var rise := absf(yb - ya)
	if rise < 0.05 or _has_slide(a, b):
		return  # 段差なし。またはこの境界はスロープの代わりに滑り台がある
	var run := maxf(RAMP_MIN_RUN, rise * RAMP_RUN_PER_RISE)
	var dir := -1.0 if ya < yb else 1.0
	var boundary := WorldData.BAND * (-1.0 if _low_side_index(a, along_x) == 0 else 1.0)
	var low_zone := b if dir > 0.0 else a
	if idx != low_zone:
		return
	var near := boundary
	var far := boundary + dir * run
	var lo := minf(near, far)
	var hi := maxf(near, far)
	var along: float = pos.x if along_x else pos.z
	var across: float = pos.z if along_x else pos.x
	var cross_center: float = WorldData.AXIS_CENTER[
		WorldData.ZONE_ROW[a] if along_x else WorldData.ZONE_COL[a]]
	var in_run := along > lo and along < hi
	var in_width := absf(across - cross_center) < RAMP_WIDTH * 0.5
	assert(not (in_run and in_width),
		"%s がゾーン%dのランプ(%d<->%d)の傾斜面に置かれている" % [node_name, idx, a, b])


## --- 転落防止の柵 -------------------------------------------------------

## 落差のある境界に柵を立て、決められた口（滑り台の入口 / スロープの取り付け口）
## からしか降りられないようにする。これが無いと高いゾーンの縁から
## どこでも飛び降りられ、滑り台もスロープも使う理由が無くなる。
##
## 柵は高い側の床に立てるので、低い側から見ると崖の上の手すりになる。
## 高さ 2.5m はジャンプ(1.38m)では越えられず、視線を切る 6m 級でもない
static func _build_parapets(root: Node3D, mats: Array[StandardMaterial3D]) -> void:
	for pair in WorldData.RAMP_PAIRS_X:
		_parapet(root, pair[0], pair[1], mats, true)
	for pair in WorldData.RAMP_PAIRS_Z:
		_parapet(root, pair[0], pair[1], mats, false)


## a は西/北側、b は東/南側のゾーン。
## 境界の座標に沿って柵を伸ばし、通してよい場所だけ開口を残す
static func _parapet(root: Node3D, a: int, b: int, mats: Array[StandardMaterial3D], along_x: bool) -> void:
	var ya: float = WorldData.ZONE_GROUND[a]
	var yb: float = WorldData.ZONE_GROUND[b]
	if absf(ya - yb) < PARAPET_MIN_DROP:
		return  # 1〜2m の段差は普通に飛び降りてよい
	var hi := a if ya > yb else b
	var mat: Material = mats[hi] if hi < mats.size() else null
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
	_no_shadow(_box(root, "Parapet%s_%d" % [tag, n], pos, size, mat))
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
	var deck_mat := pop_material(Color(0.30, 0.74, 0.98))
	var rail_mat := pop_material(Color(0.98, 0.34, 0.70))
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
		# デッキが走路ぶんの影を落とすので、レールの影は増えても見えない
		_no_shadow(rail)


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
		box.size = Vector3(SLIDE_WIDTH - SLIDE_AREA_SIDE_INSET * 2.0, SLIDE_AREA_HEIGHT, a.distance_to(b))
		col.shape = box
		col.position = (a + b) * 0.5 + basis.y * (SLIDE_AREA_HEIGHT * 0.5)
		col.rotation = rot
		area.add_child(col)
	root.add_child(area)


## a から b へ向く姿勢。-Z を進行方向にする（既存の向きの規約と同じ）
static func _slide_rotation(a: Vector3, b: Vector3) -> Vector3:
	var d := b - a
	return Vector3(asin(clampf(d.y / d.length(), -1.0, 1.0)), atan2(-d.x, -d.z), 0.0)


## --- キープアウト矩形 ---------------------------------------------------
## 走路のように「線ではなく面」で場所を占める物は、点列を occupied へ足すだけでは
## 守れない。点と点の間（走路の中ほど）が素通しになり、そこに壁やプロップが生えて
## 滑り台を貫通する。平面視の矩形で持ち、面同士で判定する。
##
## 滑り台は必ず X か Z のどちらかに平行なので（_slide_path は直交軸の座標を
## 動かさない）、軸平行の矩形1枚で走路全体を厳密に表せる。
## 高さは見ない: 走路は入口の 8m から出口の 0m まで降りてくるので、
## 「下をくぐれる高さ」が保証できる区間が存在しないため
static func _slide_rects(paths: Array) -> Array:
	var rects: Array = []
	var side := SLIDE_WIDTH * 0.5 + SLIDE_RAIL_W
	for pts in paths:
		var a: Vector3 = pts[0]
		var b: Vector3 = pts[pts.size() - 1]
		rects.append([(a + b) * 0.5, Vector3(
			absf(b.x - a.x), 0.0, absf(b.z - a.z)) * 0.5
			+ Vector3(side, 0.0, side)])
	return rects


## ゾーンの目印は手置きで、条件に関係なく必ず建つ。だから場所を選ぶ側（バンパー）
## より先にキープアウトへ積んでおかないと、目印の位置を先に取られてめり込む。
## 円錐の笠木が胴より一回り太いぶんだけ余裕を持たせる
static func _landmark_rects() -> Array:
	var rects: Array = []
	for mark in WorldData.ZONE_LANDMARKS:
		var r: float = SIGHT_WALL_MAX_LEN * mark[4] * 0.5 * 0.5 * 1.15
		rects.append([WorldData.zone_point(mark[0], mark[1], mark[2]),
			Vector3(r, 0.0, r)])
	return rects


## 中心 pos・半径 half の矩形が、キープアウト矩形のどれかと pad 以内に近づくか
static func _hits_keepout(pos: Vector3, half: Vector2, rects: Array, pad: float) -> bool:
	for r in rects:
		var c: Vector3 = r[0]
		var rh: Vector3 = r[1]
		if absf(pos.x - c.x) < half.x + rh.x + pad \
				and absf(pos.z - c.z) < half.y + rh.z + pad:
			return true
	return false


static func _build_walls(root: Node3D, mat: Material) -> void:
	var h := WorldData.WALL_HEIGHT
	var half := WorldData.WORLD_HALF
	var cy: float = WorldData.SLAB_BOTTOM + h * 0.5
	var span := half * 2.0 + 2.0
	_box(root, "WallN", Vector3(0, cy, -half - 0.5), Vector3(span, h, 1.0), mat)
	_box(root, "WallS", Vector3(0, cy, half + 0.5), Vector3(span, h, 1.0), mat)
	_box(root, "WallW", Vector3(-half - 0.5, cy, 0), Vector3(1.0, h, span), mat)
	_box(root, "WallE", Vector3(half + 0.5, cy, 0), Vector3(1.0, h, span), mat)


## 外周4隅の直角を対角に切り落とす。壁が直角のままだと move_and_slide() が
## 2枚の壁の法線を相殺してその場に詰まる（部屋の角にハマる典型例）。
## 対角の壁1枚に置き換えて、90°の凹んだ角を2つの135°の角へ変える
static func _build_wall_corners(root: Node3D, mat: Material) -> void:
	var h := WorldData.WALL_HEIGHT
	var half := WorldData.WORLD_HALF
	var cy: float = WorldData.SLAB_BOTTOM + h * 0.5
	var chamfer := WALL_CORNER_CHAMFER
	var corners: Array[Vector2] = [
		Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	for i in corners.size():
		var s: Vector2 = corners[i]
		var mid := Vector2(s.x * (half - chamfer * 0.5), s.y * (half - chamfer * 0.5))
		var yaw := atan2(s.y, s.x)
		_box(root, "WallCorner%d" % i, Vector3(mid.x, cy, mid.y),
			Vector3(chamfer * sqrt(2.0), h, 1.0), mat, Vector3(0, yaw, 0))


## 遮蔽ブロック。配置は固定シードの乱数なので全ピアで同一になる。
## 実際に置けた位置を返し、壁がその上に重ならないようにする
static func _build_cover(root: Node3D, mats: Array[StandardMaterial3D], occupied: Array[Vector3],
		keepout: Array) -> Array[Vector3]:
	var placed: Array[Vector3] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldData.BUILD_SEED
	for idx in WorldData.ZONE_COUNT:
		var center := WorldData.zone_center(idx)
		var ext := WorldData.zone_extent(idx)
		var mat: Material = mats[idx] if idx < mats.size() else null
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
			if _hits_keepout(pos, Vector2(w, d) * 0.5, keepout, WALL_CLEARANCE):
				continue
			_no_shadow(_box(root, "Cover%d_%d" % [idx, n], pos, Vector3(w, bh, d), mat))
			placed.append(pos)
	return placed


## 弾き返すバンパー。置けた位置の矩形を keepout へ足すので、
## 後から建つプロップは必ずこれを避ける。
##
## 十字通路の中には置かない。「中心 <-> 4方向のスロープ口」の連結を
## 「通路は常に完全に空いている」だけで押し切れる状態を保つため
static func _build_bumpers(root: Node3D, mats: Array[StandardMaterial3D],
		occupied: Array[Vector3], keepout: Array) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldData.BUILD_SEED + 3
	var half := Vector2(BUMPER_D, BUMPER_D) * 0.5
	for idx in WorldData.ZONE_COUNT:
		var center := WorldData.zone_center(idx)
		var ext := WorldData.zone_extent(idx)
		var mx := ext.x * 0.5 - WALL_OUTER_MARGIN - half.x
		var mz := ext.y * 0.5 - WALL_OUTER_MARGIN - half.y
		var placed: Array[Vector3] = []
		# 十字通路の外側だけを直接サンプルする。「一様に引いてから通路判定で捨てる」
		# より当たりが多く、象限を1つずつ使うので散らばりも均等になる。
		# 開始象限をずらすのは、全ゾーンで同じ隅から埋まって見えるのを避けるため
		var start := rng.randi() % QUADRANTS.size()
		for q in QUADRANTS.size():
			if placed.size() >= BUMPER_PER_ZONE:
				break
			var s: Vector2 = QUADRANTS[(start + q) % QUADRANTS.size()]
			for k in BUMPER_TRIES:
				var lx := rng.randf_range(CORRIDOR_HALF + half.x, mx) * s.x
				var lz := rng.randf_range(CORRIDOR_HALF + half.y, mz) * s.y
				var pos := Vector3(center.x + lx, center.y, center.z + lz)
				if _rect_too_close(pos, half, occupied, GIMMICK_CLEARANCE):
					continue
				# バンパー同士。相手の半径も足すので half を2倍して渡す
				if _rect_too_close(pos, half * 2.0, placed, WALL_GAP):
					continue
				if _hits_keepout(pos, half, keepout, WALL_CLEARANCE):
					continue
				_bumper(root, "Bumper%d_%d" % [idx, placed.size()], pos, mats[idx])
				placed.append(pos)
				keepout.append([pos, Vector3(half.x, 0.0, half.y)])
				break


## 選択中の案を複合メッシュで組み立てる。
## 見た目だけを替え、従来の潰した球コリジョンと
## それを一回り覆う反発 Area はそのまま残す。
## 天面を塞ぐ Area（_top_guard）は付けない。上に乗ってもこの Area の中なので、
## 弾き返しがそのまま「上に立てない」を兼ねる
static func _bumper(root: Node3D, node_name: String, pos: Vector3, mat: Material) -> void:
	# バンパーは MultiMesh へ集約しない。触れた時の潰し演出で
	# メッシュを個別に縮める必要があるため（数は最大18個なので影響は小さい）
	var body := _solid(root, node_name, pos + Vector3(0, BUMPER_H * 0.5, 0),
		Vector3(BUMPER_D, BUMPER_H, BUMPER_D), mat, Shape.SPHERE, Vector3.ZERO, 8,
		false, false)
	body.add_to_group("cpu_bumpers")
	# _solid が作るメッシュはコリジョン生成の基準として残し、表示だけ隠す。
	# これにより外観を替えても物理形状は以前と完全に同じになる。
	var collision_guide := body.get_node_or_null("Mesh") as MeshInstance3D
	if collision_guide:
		collision_guide.visible = false
		collision_guide.name = "CollisionGuide"
	_add_bumper_visual(body)
	var area := Area3D.new()
	area.name = "Hit"
	area.collision_layer = 0
	area.collision_mask = 2  # Character
	area.set_script(BUMPER_SCRIPT)
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = BUMPER_D * 0.5 + BUMPER_PAD
	shape.height = BUMPER_H + BUMPER_PAD * 2.0
	col.shape = shape
	area.add_child(col)
	body.add_child(area)


static func _add_bumper_visual(body: StaticBody3D) -> void:
	if BUMPER_VISUAL_STYLE == 7:
		_add_bumper_visual_7(body)
	else:
		_add_bumper_visual_9(body)


static func _add_bumper_visual_7(body: StaticBody3D) -> void:
	var visual := Node3D.new()
	visual.name = "Visual"
	body.add_child(visual)

	var lavender := soft_material(Color(0.72, 0.52, 0.82))
	var lavender_dark := soft_material(Color(0.54, 0.39, 0.66))
	var butter := soft_material(Color(0.95, 0.80, 0.40))
	var mint := soft_material(Color(0.40, 0.72, 0.65))
	var dark := soft_material(Color(0.31, 0.28, 0.38))

	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = 2.2
	base_mesh.bottom_radius = 2.2
	base_mesh.height = 0.28
	base_mesh.radial_segments = 16
	_add_bumper_mesh(visual, "Base", base_mesh, Vector3(0, -0.94, 0), mint)

	# 接触時に潰れる部分。ベースと支柱を動かさず、クッション・バンド・バネをまとめる。
	var bounce_visual := Node3D.new()
	bounce_visual.name = "BounceVisual"
	visual.add_child(bounce_visual)

	# ベースとクッションの間に、低いバネと支柱を見せる。
	for i in 4:
		var angle := i * TAU / 4.0
		var spring_pos := Vector3(cos(angle) * 1.55, 0, sin(angle) * 1.55)
		for ring_i in 3:
			var spring := TorusMesh.new()
			spring.inner_radius = 0.12
			spring.outer_radius = 0.28
			spring.rings = 8
			spring.ring_segments = 5
			_add_bumper_mesh(bounce_visual, "Spring%d_%d" % [i, ring_i], spring,
				spring_pos + Vector3(0, -0.75 + ring_i * 0.13, 0), dark)
		var support_angle := angle + TAU / 8.0
		var support := CylinderMesh.new()
		support.top_radius = 0.13
		support.bottom_radius = 0.13
		support.height = 0.48
		support.radial_segments = 8
		_add_bumper_mesh(visual, "Support%d" % i, support,
			Vector3(cos(support_angle) * 1.72, -0.60, sin(support_angle) * 1.72), dark)

	var cushion := TorusMesh.new()
	cushion.inner_radius = 0.70
	cushion.outer_radius = 2.10
	cushion.rings = 16
	cushion.ring_segments = 8
	_add_bumper_mesh(bounce_visual, "Cushion", cushion, Vector3(0, 0.30, 0), lavender)

	# 中央は貫通穴にせず、少し低い柔らかなパッドで塞ぐ。
	var center := CylinderMesh.new()
	center.top_radius = 0.76
	center.bottom_radius = 0.76
	center.height = 0.22
	center.radial_segments = 16
	_add_bumper_mesh(bounce_visual, "CenterPad", center, Vector3(0, 0.34, 0), lavender_dark)

	# 4方向の縦長カプセルをリングへ沿わせ、7番案の補強バンドを表現する。
	var band_positions := [
		[Vector3(1.63, 0.20, 0), Vector3(0, 0, deg_to_rad(25.0))],
		[Vector3(-1.63, 0.20, 0), Vector3(0, 0, deg_to_rad(-25.0))],
		[Vector3(0, 0.20, 1.63), Vector3(deg_to_rad(-25.0), 0, 0)],
		[Vector3(0, 0.20, -1.63), Vector3(deg_to_rad(25.0), 0, 0)],
	]
	for i in band_positions.size():
		var band := CapsuleMesh.new()
		band.radius = 0.16
		band.height = 1.25
		band.radial_segments = 8
		band.rings = 4
		_add_bumper_mesh(bounce_visual, "Band%d" % i, band,
			band_positions[i][0], butter, band_positions[i][1])


## 9番案の、柔らかな透明ドームをバネで支えるバンパー。
## 半透明部分の内側にもパッドを置き、どの角度から見ても反発装置だと分かるようにする。
static func _add_bumper_visual_9(body: StaticBody3D) -> void:
	var visual := Node3D.new()
	visual.name = "Visual"
	body.add_child(visual)

	var lavender_glass := _bumper_frosted_material(Color(0.76, 0.61, 0.88, 0.48))
	var coral := soft_material(Color(0.90, 0.46, 0.50))
	var coral_dark := soft_material(Color(0.73, 0.34, 0.43))
	var butter := soft_material(Color(0.96, 0.82, 0.48))
	var mint := soft_material(Color(0.45, 0.76, 0.66))
	var dark := soft_material(Color(0.31, 0.28, 0.38))

	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = 2.2
	base_mesh.bottom_radius = 2.2
	base_mesh.height = 0.28
	base_mesh.radial_segments = 16
	_add_bumper_mesh(visual, "Base", base_mesh, Vector3(0, -0.94, 0), coral)

	var base_trim := TorusMesh.new()
	base_trim.inner_radius = 1.72
	base_trim.outer_radius = 2.16
	base_trim.rings = 16
	base_trim.ring_segments = 6
	_add_bumper_mesh(visual, "BaseTrim", base_trim, Vector3(0, -0.79, 0), coral_dark)

	# ドーム・内側のパッド・バネをまとめて潰し、固定ベースは動かさない。
	var bounce_visual := Node3D.new()
	bounce_visual.name = "BounceVisual"
	visual.add_child(bounce_visual)

	for i in 4:
		var angle := i * TAU / 4.0
		var spring_pos := Vector3(cos(angle) * 1.48, 0, sin(angle) * 1.48)
		for ring_i in 3:
			var spring := TorusMesh.new()
			spring.inner_radius = 0.12
			spring.outer_radius = 0.28
			spring.rings = 8
			spring.ring_segments = 5
			_add_bumper_mesh(bounce_visual, "Spring%d_%d" % [i, ring_i], spring,
				spring_pos + Vector3(0, -0.75 + ring_i * 0.13, 0), dark)

		var support_angle := angle + TAU / 8.0
		var support := CylinderMesh.new()
		support.top_radius = 0.13
		support.bottom_radius = 0.13
		support.height = 0.48
		support.radial_segments = 8
		_add_bumper_mesh(visual, "Support%d" % i, support,
			Vector3(cos(support_angle) * 1.70, -0.60, sin(support_angle) * 1.70), dark)

	var inner_pad := CylinderMesh.new()
	inner_pad.top_radius = 1.42
	inner_pad.bottom_radius = 1.55
	inner_pad.height = 0.28
	inner_pad.radial_segments = 16
	_add_bumper_mesh(bounce_visual, "InnerPad", inner_pad, Vector3(0, -0.48, 0), mint)

	var dome := SphereMesh.new()
	dome.radius = 1.96
	dome.height = 3.92
	dome.radial_segments = 20
	dome.rings = 10
	_add_bumper_mesh(bounce_visual, "Dome", dome, Vector3(0, 0.14, 0), lavender_glass,
		Vector3.ZERO, Vector3(1.0, 0.43, 1.0))

	var rim := TorusMesh.new()
	rim.inner_radius = 1.66
	rim.outer_radius = 2.08
	rim.rings = 16
	rim.ring_segments = 6
	_add_bumper_mesh(bounce_visual, "Rim", rim, Vector3(0, -0.47, 0), coral)

	# クリーム色の留め具を四方に置き、透明ドームと土台の接続を見せる。
	for i in 4:
		var angle := i * TAU / 4.0
		var clip := CapsuleMesh.new()
		clip.radius = 0.18
		clip.height = 0.62
		clip.radial_segments = 8
		clip.rings = 4
		var clip_pos := Vector3(cos(angle) * 1.83, -0.37, sin(angle) * 1.83)
		var clip_rot := Vector3(0, 0, deg_to_rad(90.0))
		if i % 2 == 1:
			clip_rot = Vector3(deg_to_rad(90.0), 0, 0)
		_add_bumper_mesh(bounce_visual, "Clip%d" % i, clip, clip_pos, butter, clip_rot)


static func _bumper_frosted_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.roughness = 0.90
	material.metallic = 0.0
	material.metallic_specular = 0.12
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


static func _add_bumper_mesh(parent: Node3D, node_name: String, mesh: PrimitiveMesh,
		pos: Vector3, material: Material, rot := Vector3.ZERO,
		scale := Vector3.ONE) -> void:
	mesh.material = material
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.position = pos
	instance.rotation = rot
	instance.scale = scale
	parent.add_child(instance)


## 視線を切る構造物。ゾーンごとに4象限へ配り、種類はそのゾーンのテーマから引く。
##
## 袋小路を作らない保証: プロップは外から見て凸な塊だけで、内部に入れる空間を持たない。
## 内部が無い以上、単体では袋小路にならない。閉じたリングを構成しないことは、
## 隣り合うプロップの隙間が常に WALL_GAP(2.5m ＝ agent_radius 0.45 の 2.7倍)
## 以上あることから従う。加えて CORRIDOR_HALF の十字通路と
## WALL_OUTER_MARGIN の外周帯は常に完全に開いている。
static func _build_props(root: Node3D, mats: Array[StandardMaterial3D],
		occupied: Array[Vector3], keepout: Array, batch: Batch) -> void:
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
		_prop(root, "Landmark%d" % idx, mark[3], mark_pos, mark_span, true, mats[idx], batch)
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
					# 滑り台の走路とバンパー。面で判定しないと走路の中ほどを貫通する
					if _hits_keepout(pos, half, keepout, WALL_CLEARANCE):
						continue
					var clash := false
					for e in placed:
						if _rect_too_close(pos, half + e[1], [e[0]] as Array[Vector3], WALL_GAP):
							clash = true
							break
					if clash:
						continue
					_prop(root, "Prop%d_%d" % [idx, n], kind, pos, prop_len, along_x, mats[idx],
						batch)
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
		mat: Material, batch: Batch) -> void:
	var body_h := SIGHT_WALL_HEIGHT * 0.62
	var cap_h := d * 0.5 * 1.85  # 半径に対して 1.85倍 = 61.6°
	_solid(root, node_name, base + Vector3(0, body_h * 0.5, 0),
		Vector3(d, body_h, d), mat, Shape.CYLINDER, Vector3.ZERO, 1, false, true, batch)
	_solid(root, node_name + "Cap", base + Vector3(0, body_h + cap_h * 0.5, 0),
		Vector3(d * 1.12, cap_h, d * 1.12), mat, Shape.CONE, Vector3.ZERO, 1, true,
		false, batch)


## 立ち上がり配管。塔より細く高い
static func _prop_pipe(root: Node3D, node_name: String, base: Vector3, d: float,
		mat: Material, batch: Batch) -> void:
	var body_h := SIGHT_WALL_HEIGHT * 0.85
	var cap_h := d * 0.5 * 1.9
	_solid(root, node_name, base + Vector3(0, body_h * 0.5, 0),
		Vector3(d, body_h, d), mat, Shape.CYLINDER, Vector3.ZERO, 1, false, true, batch)
	_solid(root, node_name + "Cap", base + Vector3(0, body_h + cap_h * 0.5, 0),
		Vector3(d * 1.25, cap_h, d * 1.25), mat, Shape.CONE, Vector3.ZERO, 1, true,
		false, batch)


## 貨物コンテナ／積み木。壁より厚みがあり、屋根型の笠木で締める
static func _prop_crate(root: Node3D, node_name: String, base: Vector3, span: float,
		along_x: bool, mat: Material, batch: Batch) -> void:
	var box_h := SIGHT_WALL_HEIGHT - WALL_CAP_HEIGHT
	var depth := CRATE_DEPTH
	var size := (Vector3(span, box_h, depth) if along_x else Vector3(depth, box_h, span))
	var body := _solid(root, node_name, base + Vector3(0, box_h * 0.5, 0), size, mat,
		Shape.BOX, Vector3.ZERO, 1, false, true, batch)
	_wall_cap(body, span, along_x, box_h, mat, depth, batch)


## 従来の視線壁。テーマの中では「城壁 / 生垣」として使う
static func _prop_wall(root: Node3D, node_name: String, base: Vector3, span: float,
		along_x: bool, mat: Material, batch: Batch) -> void:
	var box_h := SIGHT_WALL_HEIGHT - WALL_CAP_HEIGHT
	var size := (Vector3(span, box_h, SIGHT_WALL_THICK) if along_x
		else Vector3(SIGHT_WALL_THICK, box_h, span))
	var body := _solid(root, node_name, base + Vector3(0, box_h * 0.5, 0), size, mat,
		Shape.BOX, Vector3.ZERO, 1, false, true, batch)
	_wall_cap(body, span, along_x, box_h, mat, SIGHT_WALL_THICK, batch)


## プロップ1個を建てる。base は地面の高さ
static func _prop(root: Node3D, node_name: String, kind: int, base: Vector3,
		span: float, along_x: bool, mat: Material, batch: Batch) -> void:
	match kind:
		WorldData.Prop.TOWER:
			_prop_tower(root, node_name, base, span, mat, batch)
		WorldData.Prop.PIPE:
			_prop_pipe(root, node_name, base, span, mat, batch)
		WorldData.Prop.CRATE:
			_prop_crate(root, node_name, base, span, along_x, mat, batch)
		_:
			_prop_wall(root, node_name, base, span, along_x, mat, batch)


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
		box_h: float, mat: Material, thick := SIGHT_WALL_THICK,
		batch: Batch = null) -> void:
	var size := Vector3(thick, WALL_CAP_HEIGHT, wall_len)
	var prism := PrismMesh.new()
	prism.size = size
	_set_subdiv(prism, _subdiv(size.x), _subdiv(size.y), _subdiv(size.z))
	prism.material = mat
	var col := CollisionShape3D.new()
	# メッシュから凸形状を起こすので、見た目と当たり判定が必ず一致する
	col.shape = prism.create_convex_shape()
	var cap_y := box_h * 0.5 + WALL_CAP_HEIGHT * 0.5
	var yaw := PI * 0.5 if along_x else 0.0
	col.position = Vector3(0, cap_y, 0)
	col.rotation.y = yaw
	body.add_child(col)

	# 笠木の真下には必ず本体の壁があるので、影パスから外しても影の形は変わらない
	if batch != null:
		batch.add(Shape.PRISM, body.position + Vector3(0, cap_y, 0), size,
			Vector3(0.0, yaw, 0.0), mat, false)
		return
	var mesh := MeshInstance3D.new()
	mesh.mesh = prism
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.position = col.position
	mesh.rotation.y = yaw
	body.add_child(mesh)

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


## 影パスから外す。ドローコールは「本体 + 影を落とす物」で数えられるので、
## 形の読み取りに寄与しない物を外すと影パスぶんがそのまま減る。
##
## 外してよいのは、真下に必ず影を落とす本体がある物（塔の笠木・壁の笠木）と、
## 背が低くて影がほぼ足元にしか出ない物（バンパー・遮蔽ブロック・柵）。
## 視線を切る 6m のプロップ本体は外さない（長い影が距離感の手がかりになる）
static func _no_shadow(body: StaticBody3D) -> void:
	for c in body.get_children():
		if c is GeometryInstance3D:
			c.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


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

	# 雲: 3個の潰した球を寄せて1つの雲にする。遠景なので距離カリングはしない。
	# 3つの球には同じ位相を入れる。バラバラに揺らすと1つの雲に見えなくなる
	var clouds: Array[Transform3D] = []
	var cloud_phase: Array = []
	for i in 24:
		var c := Vector3(rng.randf_range(-78.0, 78.0), rng.randf_range(40.0, 62.0),
			rng.randf_range(-78.0, 78.0))
		var phase := rng.randf()
		for k in 3:
			var s := rng.randf_range(2.5, 5.0)
			clouds.append(Transform3D(
				Basis.from_scale(Vector3(s, s * 0.55, s)),
				c + Vector3(rng.randf_range(-4.0, 4.0), rng.randf_range(-0.8, 0.8),
					rng.randf_range(-3.0, 3.0))))
			cloud_phase.append(phase)
	var cloud_mesh := _sphere(Color(1, 1, 1), 0.3)
	cloud_mesh.material = float_material(Color(1, 1, 1), 0.3, 2.2, 1.1, 0.0, 0.28)
	_multimesh(root, "Clouds", cloud_mesh, clouds, 0.0, cloud_phase, 3.5)

	# 茂みはここにあったが、当たり判定の無い緑のドームが地面に置いてあるだけで
	# 走ると素通りしてしまい意味が無かった。実体のあるバンパー（_build_bumpers）に
	# 置き換えてある

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


## 揺れる装飾のマテリアル（decor_float.gdshader）。
## 当たり判定が無いので全ピアで揃える必要がなく、シェーダの TIME で動かせる。
## 当たり判定のある物（動く床・回転床）は GameManager.world_time を使うこと
static func float_material(c: Color, emission: float, sway: float, bob: float,
		spin := 0.0, speed := 1.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = FLOAT_SHADER
	m.set_shader_parameter("albedo", c)
	m.set_shader_parameter("emission_energy", emission)
	m.set_shader_parameter("sway", sway)
	m.set_shader_parameter("bob", bob)
	m.set_shader_parameter("spin", spin)
	m.set_shader_parameter("speed", speed)
	return m


static func _sphere(c: Color, emission := 0.6) -> Mesh:
	var m := SphereMesh.new()
	m.radius = 1.0
	m.height = 2.0
	m.radial_segments = 16
	m.rings = 8
	var mat := pop_material(c)
	mat.emission_energy_multiplier = emission
	m.material = mat
	return m


static func _flag() -> Mesh:
	var m := BoxMesh.new()
	m.size = Vector3(0.25, 4.0, 0.25)
	m.material = pop_material(Color(0.9, 0.9, 0.95))
	return m


## phases を渡すとインスタンスごとの位相が custom data に載り、
## decor_float.gdshader が揺れをずらせる（全部が同じ動きだと不自然になる）。
## wobble は揺れの最大幅。フラスタムカリングは元の AABB で判定するので、
## 広げておかないと揺れて外へ出た分が画面端で急に消える
static func _multimesh(root: Node3D, node_name: String, mesh: Mesh,
		transforms: Array[Transform3D], range_end := 90.0,
		phases: Array = [], wobble := 0.0) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = not phases.is_empty()
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
		if mm.use_custom_data:
			mm.set_instance_custom_data(i, Color(phases[i], 0.0, 0.0, 0.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = range_end
	mmi.visibility_range_end_margin = 15.0 if range_end > 0.0 else 0.0
	if wobble > 0.0:
		mmi.custom_aabb = mm.get_aabb().grow(wobble)
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
## batch を渡すと、描画は MeshInstance3D ではなく MultiMesh 側へ回す。
## その場合でもコリジョンはここで同じ size / rot から作るので、
## 見た目と当たり判定は必ず一致したままになる。
## shadow=false は影パスから外す（笠木のように真下に本体がある物）
static func _solid(root: Node3D, node_name: String, pos: Vector3, size: Vector3,
		mat: Material, kind := Shape.BOX, rot := Vector3.ZERO,
		layer := 1, no_stand := false, shadow := true,
		batch: Batch = null) -> StaticBody3D:
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
			_set_subdiv(b, _subdiv(size.x), _subdiv(size.y), _subdiv(size.z))
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
	if batch != null and Batch.can_batch(kind):
		batch.add(kind, pos, size, rot, mat, shadow)
	else:
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"  # バンパーの潰し演出がこの名前で引く
		mi.mesh = mesh
		if not shadow:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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


## 一辺の長さから分割数を決める。BoxMesh / PrismMesh の subdivide_* は
## 「追加の切れ目の数」なので、n を返すと1辺あたり n+1 枚のクアッドになる。
##
## 分割が効くのはメッシュだけで、当たり判定とナビメッシュは動かない。
## コリジョンは _solid() / _box() が同じ size から BoxShape3D を直接作るし、
## ナビメッシュは静的コライダだけを見る（world.tscn の
## geometry_parsed_geometry_type = 1）。だから通行・視線・CPU の経路は変わらない
static func _subdiv(length: float) -> int:
	return clampi(int(absf(length) / MESH_SEGMENT_M), 0, MESH_SEGMENT_MAX)


## BoxMesh と PrismMesh は同じ3つのプロパティを持つが、共通の基底クラスが
## PrimitiveMesh までしか無いので名前で代入する
static func _set_subdiv(mesh: PrimitiveMesh, w: int, h: int, d: int) -> void:
	mesh.set("subdivide_width", w)
	mesh.set("subdivide_height", h)
	mesh.set("subdivide_depth", d)


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
	_set_subdiv(box, _subdiv(size.x), _subdiv(size.y), _subdiv(size.z))
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
