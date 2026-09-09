extends Control

## HUD の子（$MapPanel）にアタッチ。9ゾーンミニマップの描画と、Runner専用の
## コンパス(方位)・距離表示を持つ。
## 危険ヴィネット（近いほど赤く脈打つ）は scenes/hud.gd(ルート)側に残す
## ("見られている"演出と合わせて管理する in-match HUD の危険表示の一部だから)。
## $Compass 等はこのノードの兄弟(HUDの直下)なので、直接 $ では辿れず、
## root の hud.gd._ready() から setup() で参照を受け取る

# ゾーン名・色は WorldData に一本化してある（レイアウト変更時の同期漏れを防ぐため）
const WORLD_MIN := -WorldData.WORLD_HALF
const WORLD_SIZE := WorldData.WORLD_HALF * 2.0

const ARROW_COLOR := Color(1.0, 0.3, 0.25)
const HUNTER_DOT := Color(1.0, 0.25, 0.2)
const SELF_DOT := Color(0.3, 1.0, 0.5)
const INK := Color(0.05, 0.04, 0.12)

var _compass: Control
var _distance_chip: Control
var _distance_label: Label


func _ready() -> void:
	draw.connect(_on_map_draw)


func setup(compass: Control, distance_chip: Control, distance_label: Label) -> void:
	_compass = compass
	_distance_chip = distance_chip
	_distance_label = distance_label
	_compass.draw.connect(_on_compass_draw)


## Runner専用のコンパス・距離表示を更新する。危険ヴィネットの濃さはrootのhud.gdが
## 同じ距離値を使って別途計算するため、最寄りの鬼(またはnull)を返す
func update_compass(player: Player, is_runner: bool) -> Node3D:
	var target: Node3D = _nearest_hunter(player) if is_runner else null
	_compass.visible = target != null
	_distance_chip.visible = target != null
	if target == null:
		return null
	var forward: Vector3 = -player.camera.global_transform.basis.z
	var to_target: Vector3 = target.global_position - player.global_position
	var f2 := Vector2(forward.x, forward.z)
	var t2 := Vector2(to_target.x, to_target.z)
	if f2.length_squared() > 0.0001 and t2.length_squared() > 0.0001:
		_compass.rotation = f2.angle_to(t2)
	_distance_label.text = "%.1f m" % to_target.length()
	return target


func _nearest_hunter(player: Node3D) -> Node3D:
	var best: Node3D = null
	var best_dist := INF
	var runner_name := str(GameManager.runner_id)
	for p in get_tree().get_nodes_in_group("players"):
		if p.name == runner_name:
			continue
		var d: float = p.global_position.distance_to(player.global_position)
		if d < best_dist:
			best_dist = d
			best = p
	for cpu in get_tree().get_nodes_in_group("cpu_hunters"):
		var d: float = cpu.global_position.distance_to(player.global_position)
		if d < best_dist:
			best_dist = d
			best = cpu
	return best


func _on_compass_draw() -> void:
	var c := _compass.size * 0.5
	var points := PackedVector2Array([
		c + Vector2(0, -40), c + Vector2(25, 22), c + Vector2(0, 9), c + Vector2(-25, 22),
	])
	_compass.draw_colored_polygon(points, ARROW_COLOR)
	_compass.draw_polyline(points + PackedVector2Array([points[0]]), INK, 3.0, true)


func _on_map_draw() -> void:
	var s := size
	draw_rect(Rect2(Vector2.ZERO, s), Color(0.06, 0.05, 0.12, 0.92))
	for idx in WorldData.ZONE_COUNT:
		var c := WorldData.zone_color(idx).darkened(0.35)
		c.a = 0.92
		draw_rect(_zone_rect(idx), c)
		draw_rect(_zone_rect(idx), Color(0, 0, 0, 0.25), false, 1.0)
	# マップ全体の外枠を真四角・細く淡い色で描画する（角丸や太枠にせずスッキリ馴染ませる）
	draw_rect(Rect2(Vector2.ZERO, s), Color(0.12, 0.10, 0.22, 0.5), false, 2.0)

	# 逃走者のドットは**誰の画面にも**描かない。
	# 逃走者が見るとこれは「鬼全員」、鬼が見ると「味方の鬼」になる。
	# デバッグの CPU 逃走者は cpu_runners グループなのでどちらのループにも入らない
	var runner_name := str(GameManager.runner_id)
	# ここに来るのは必ず鬼なので、エモートを見せてよいのは**鬼から見た時だけ**。
	# 逃走者にも見せると、鬼の合図（＝これから挟みに来る）まで読めてしまう
	var viewer_is_hunter := multiplayer.get_unique_id() != GameManager.runner_id
	for p in get_tree().get_nodes_in_group("players"):
		if p.name != runner_name:
			_draw_marker(_map_point(p.global_position), HUNTER_DOT,
				_emote_of(p) if viewer_is_hunter else Player.Emote.NONE)
	for cpu in get_tree().get_nodes_in_group("cpu_hunters"):
		_draw_marker(_map_point(cpu.global_position), HUNTER_DOT, Player.Emote.NONE)

	var player := _get_local_player()
	if player:
		var center := _map_point(player.global_position)
		_draw_marker(center, SELF_DOT, player.sync_emote)
		var forward: Vector3 = -player.global_transform.basis.z
		var dir2 := Vector2(forward.x, forward.z).normalized()
		draw_line(center, center + dir2 * 13.0, SELF_DOT, 2.5, true)


func _get_local_player() -> Player:
	var my_name := str(multiplayer.get_unique_id())
	for p in get_tree().get_nodes_in_group("players"):
		if p.name == my_name:
			return p
	return null


## CPU 鬼は sync_emote を持たないので、存在を確かめてから読む
## （GameManager.nickname_for() が sync_nickname に対してやっているのと同じ）
func _emote_of(node: Node) -> int:
	if "sync_emote" in node:
		return node.sync_emote
	return Player.Emote.NONE


func _draw_marker(p: Vector2, c: Color, emote: int) -> void:
	if emote != Player.Emote.NONE:
		# 「呼んでいる」ことを目立たせるための脈打つリング。
		# 誰のエモートかは色ではなく位置で読むので、リングの色は文言ごとに変える
		var ring: Color = Player.EMOTE_COLOR.get(emote, Color.WHITE)
		var t := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.010)
		draw_circle(p, lerpf(13.0, 21.0, t), Color(ring, lerpf(0.45, 0.05, t)))
		draw_arc(p, lerpf(13.0, 21.0, t), 0.0, TAU, 24,
			Color(ring, lerpf(0.95, 0.15, t)), 2.5, true)
	draw_circle(p, 11.0, Color(c.r, c.g, c.b, 0.22))
	draw_circle(p, 5.5, c)
	draw_circle(p, 2.2, Color(1, 1, 1, 0.9))


## ゾーンの床範囲をミニマップ上の矩形に変換する
func _zone_rect(idx: int) -> Rect2:
	var col: int = WorldData.ZONE_COL[idx]
	var row: int = WorldData.ZONE_ROW[idx]
	var x0: float = WorldData.AXIS_CENTER[col] - WorldData.AXIS_SIZE[col] * 0.5
	var z0: float = WorldData.AXIS_CENTER[row] - WorldData.AXIS_SIZE[row] * 0.5
	var s := size
	return Rect2(
		(x0 - WORLD_MIN) / WORLD_SIZE * s.x,
		(z0 - WORLD_MIN) / WORLD_SIZE * s.y,
		WorldData.AXIS_SIZE[col] / WORLD_SIZE * s.x,
		WorldData.AXIS_SIZE[row] / WORLD_SIZE * s.y)


func _map_point(world: Vector3) -> Vector2:
	var u := clampf((world.x - WORLD_MIN) / WORLD_SIZE, 0.0, 1.0)
	var v := clampf((world.z - WORLD_MIN) / WORLD_SIZE, 0.0, 1.0)
	return Vector2(u * size.x, v * size.y)
