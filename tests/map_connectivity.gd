extends Node3D

## マップの連結性の検証。実際にナビメッシュへ経路探索させて確かめる。
##
##   godot --headless --path . res://tests/map_connectivity.tscn --quit-after 1800
##
## 見るところは2つ:
##   1. unreachable pairs が 0 か（全ゾーンが CPU の足で行き来できる）
##   2. マンホールのリンクを切った時、高いゾーンへ「登れる経路 0 / 降りられる経路 7」か
##      （滑り台の一方通行が効いている証拠。双方向になっていたら対称になる）
##
## 注意: ベイク完了の後もナビサーバの同期には数十フレームかかる。
## 待たずに問い合わせるとマップが空に見え、全ペアが到達不能と誤判定する

const ARRIVE := 4.0  # 経路の終点が目標からこの距離以内なら到達成功とみなす


func _ready() -> void:
	WorldBuilder.build($NavRegion/Map, $NavRegion/Gimmicks, $Decor)
	$NavRegion.bake_finished.connect(_on_baked, CONNECT_ONE_SHOT)
	$NavRegion.bake_navigation_mesh()


func _on_baked() -> void:
	# ナビサーバの同期はベイク完了の後ろで走る。十分な物理フレームを待つ
	for i in 60:
		await get_tree().physics_frame
	_report_build()
	_report_slides()
	_report_overlaps()
	_report_paths()
	await _report_oneway()
	get_tree().quit()


## マンホールのリンクを切ると、残る経路は滑り台のリンクだけになる。
## 一方通行が効いていれば「高いゾーンへは誰も到達できない／高いゾーンからは出られる」
## という非対称が現れる。双方向になっていたらここで対称になって気づける
func _report_oneway() -> void:
	for n in $NavRegion/Gimmicks.get_children():
		if n is NavigationLink3D and String(n.name).begins_with("PipeLink"):
			n.enabled = false
	for i in 30:
		await get_tree().physics_frame
	var map := get_world_3d().navigation_map
	print("\n--- One-way check (pipe links disabled) ---")
	for hi in [0, 8]:
		var up := 0
		var down := 0
		for other in WorldData.ZONE_COUNT:
			if other == hi:
				continue
			if _reachable(map, other, hi):
				up += 1
			if _reachable(map, hi, other):
				down += 1
		print("  zone %d %-12s: 登れる経路 %d / 降りられる経路 %d"
			% [hi, WorldData.ZONE_NAMES[hi], up, down])


func _report_build() -> void:
	var counts := {}
	for n in $NavRegion/Map.get_children():
		var kind := String(n.name).rstrip("0123456789_")
		counts[kind] = counts.get(kind, 0) + 1
	print("--- Map bodies ---")
	for k in counts:
		print("  %-14s %d" % [k, counts[k]])
	var links := 0
	for n in $NavRegion/Gimmicks.get_children():
		if n is NavigationLink3D:
			links += 1
	print("  NavigationLink3D %d" % links)


## 滑り台の入口の段差。傾いた板を上へ伸ばすと角が高い側の床から突き出て、
## そこで足を取られる。上端は床とぴったり揃っていなければならない
func _report_slides() -> void:
	print("\n--- Slide entry lip (must be ~0) ---")
	for i in WorldData.SLIDES.size():
		var deck: StaticBody3D = $NavRegion/Map.get_node("SlideDeck%d" % i)
		# _box() は子に名前を付けないので型で探す
		var size := Vector3.ZERO
		for c in deck.get_children():
			if c is CollisionShape3D:
				size = c.shape.size
		var floor_y: float = WorldData.ZONE_GROUND[WorldData.SLIDES[i][0]]
		# 上面の4隅のうち最も高い点を探す
		var highest := -INF
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				var corner: Vector3 = deck.global_transform * Vector3(
					sx * size.x * 0.5, size.y * 0.5, sz * size.z * 0.5)
				highest = maxf(highest, corner.y)
		print("  Slide%d  width %.1fm  top corner %+.3fm vs floor %.1f%s"
			% [i, size.x, highest - floor_y, floor_y,
				"" if highest - floor_y < 0.02 else "   <-- 段差あり"])


## 滑り台の走路を壁やプロップが貫通していないか。
##
## AABB で近似すると 26.6° 傾いたデッキの外接箱が実物よりかなり大きくなり、
## 貫通していない物まで拾ってしまう。物理エンジンに実際の形で問い合わせて、
## 見た目どおりの判定にする。
##
## 床スラブ（Zone*）は除外する。デッキの下端は SLIDE_END_TUCK の分だけ
## 低い側の床へ意図的に潜り込ませてあり、これは継ぎ目の段差を消すための設計
func _report_overlaps() -> void:
	print("\n--- Slide penetration (must be none) ---")
	var space := get_world_3d().direct_space_state
	var hits := 0
	for body in $NavRegion/Map.get_children():
		if not String(body.name).begins_with("Slide"):
			continue
		for c in body.get_children():
			if not (c is CollisionShape3D):
				continue
			var q := PhysicsShapeQueryParameters3D.new()
			q.shape = c.shape
			q.transform = c.global_transform
			q.collision_mask = 1  # World レイヤーだけ。滑り台同士(8)は当たらない
			for r in space.intersect_shape(q, 32):
				var other: Node = r.collider
				if String(other.name).begins_with("Zone"):
					continue
				hits += 1
				print("  %s <- %s が貫通 %s" % [body.name, other.name, other.global_position])
	print("  penetrations: %d" % hits)


func _report_paths() -> void:
	var map := get_world_3d().navigation_map
	var nm: NavigationMesh = $NavRegion.navigation_mesh
	print("\n--- Navigation ---")
	print("  polygons %d  vertices %d" % [nm.get_polygon_count(), nm.get_vertices().size()])
	print("  regions on map: %d" % NavigationServer3D.map_get_regions(map).size())
	print("  links on map:   %d" % NavigationServer3D.map_get_links(map).size())
	print("  map cell size %.3f / navmesh cell size %.3f"
		% [NavigationServer3D.map_get_cell_size(map), nm.cell_size])
	print("  map active: %s" % NavigationServer3D.map_is_active(map))
	NavigationServer3D.map_force_update(map)
	var c4 := WorldData.zone_center(4) + Vector3(0, 0.5, 0)
	var c3 := WorldData.zone_center(3) + Vector3(0, 0.5, 0)
	for z in [0, 4, 8]:
		var c := WorldData.zone_center(z) + Vector3(0, 0.5, 0)
		print("  closest to zone%d %s -> %s"
			% [z, c, NavigationServer3D.map_get_closest_point(map, c)])
	print("  link connection radius: %.2f" % NavigationServer3D.map_get_link_connection_radius(map))
	for n in $NavRegion/Gimmicks.get_children():
		if not (n is NavigationLink3D):
			continue
		var s: Vector3 = n.start_position
		var t: Vector3 = n.end_position
		print("  %-12s start off-mesh %.2fm  end off-mesh %.2fm  (%s -> %s)"
			% [n.name, s.distance_to(NavigationServer3D.map_get_closest_point(map, s)),
				t.distance_to(NavigationServer3D.map_get_closest_point(map, t)), s, t])
	var probe := NavigationServer3D.map_get_path(map, c4, c3, true)
	print("  probe 4->3 path points: %d  end %s (target %s)"
		% [probe.size(), probe[probe.size() - 1] if probe.size() > 0 else "-", c3])
	var near := NavigationServer3D.map_get_path(map, c4, c4 + Vector3(6, 0, 0), true)
	print("  probe short (same zone) path points: %d" % near.size())
	print("  query_path 4->3 points: %d" % _query(map, c4, c3).size())
	print("\n--- Path reachability (zone center -> zone center) ---")
	var fail := 0
	for a in WorldData.ZONE_COUNT:
		var line := "  from %d %-14s:" % [a, WorldData.ZONE_NAMES[a]]
		for b in WorldData.ZONE_COUNT:
			if a == b:
				continue
			var ok := _reachable(map, a, b)
			if not ok:
				fail += 1
				line += " X%d" % b
		print(line if line.ends_with(":") == false else line + " all ok")
	print("\nunreachable pairs: %d" % fail)


func _query(map: RID, from: Vector3, to: Vector3) -> PackedVector3Array:
	var p := NavigationPathQueryParameters3D.new()
	p.map = map
	p.start_position = from
	p.target_position = to
	p.path_postprocessing = NavigationPathQueryParameters3D.PATH_POSTPROCESSING_CORRIDORFUNNEL
	var r := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(p, r)
	return r.path


func _reachable(map: RID, a: int, b: int) -> bool:
	var from := WorldData.zone_center(a) + Vector3(0, 0.5, 0)
	var to := WorldData.zone_center(b) + Vector3(0, 0.5, 0)
	var path := NavigationServer3D.map_get_path(map, from, to, true)
	if path.is_empty():
		return false
	return path[path.size() - 1].distance_to(to) < ARRIVE
