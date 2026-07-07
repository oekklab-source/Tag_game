extends CanvasLayer

## ローカルプレイヤー向け HUD。
## Hunter: Runner がいる「色エリア名」だけ分かる（方向・距離・マーカーは無し）。
## Runner: 全体の2Dマップ（鬼の位置つき）と、最寄りの鬼への矢印＋距離を表示。

const ARROW_COLOR_TO_HUNTER := Color(1.0, 0.3, 0.25)
const ZONE_NAMES: Array[String] = ["CENTER", "EAST (RED)", "WEST (BLUE)", "SOUTH (GREEN)", "NORTH (YELLOW)"]
const ZONE_COLORS: Array[Color] = [
	Color(0.85, 0.85, 0.9),
	Color(1.0, 0.45, 0.4),
	Color(0.5, 0.65, 1.0),
	Color(0.45, 1.0, 0.55),
	Color(1.0, 0.9, 0.35),
]
const MAP_ZONE_COLORS: Array[Color] = [
	Color(0.32, 0.32, 0.36, 0.9),
	Color(0.55, 0.22, 0.18, 0.9),
	Color(0.2, 0.28, 0.55, 0.9),
	Color(0.2, 0.42, 0.24, 0.9),
	Color(0.55, 0.5, 0.18, 0.9),
]
const HUNTER_DOT := Color(1.0, 0.25, 0.2)
const SELF_DOT := Color(0.3, 1.0, 0.5)
const WORLD_MIN := -30.0
const WORLD_SIZE := 60.0

var _local_player: CharacterBody3D

@onready var role_label: Label = $RoleLabel
@onready var timer_label: Label = $TimerLabel
@onready var zone_label: Label = $ZoneLabel
@onready var compass: Control = $Compass
@onready var distance_label: Label = $DistanceLabel
@onready var stamina_bar: ProgressBar = $StaminaBar
@onready var result_label: Label = $ResultLabel
@onready var info_label: Label = $InfoLabel
@onready var map_panel: Control = $MapPanel


func _ready() -> void:
	compass.draw.connect(_on_compass_draw)
	map_panel.draw.connect(_on_map_draw)


func _process(_delta: float) -> void:
	var player := _get_local_player()
	_update_stamina(player)
	_update_labels()
	_update_tracking(player)


func _update_stamina(player: CharacterBody3D) -> void:
	if player == null:
		return
	stamina_bar.value = player.stamina
	stamina_bar.modulate = Color(1, 0.4, 0.4) if player.exhausted else Color.WHITE


func _update_labels() -> void:
	var my_id := multiplayer.get_unique_id()
	match GameManager.state:
		GameManager.State.WAITING:
			role_label.text = "Waiting..."
			role_label.modulate = Color.WHITE
			timer_label.text = ""
			zone_label.visible = false
			result_label.visible = false
		GameManager.State.PLAYING, GameManager.State.RESULT:
			var is_runner := my_id == GameManager.runner_id
			if is_runner:
				role_label.text = "RUN AWAY!"
				role_label.modulate = Color(0.4, 1.0, 0.55)
			else:
				role_label.text = "You are a HUNTER - catch the runner!"
				role_label.modulate = Color(1.0, 0.45, 0.4)
			if GameManager.head_start_left > 0.0:
				var h := ceili(GameManager.head_start_left)
				timer_label.text = ("HEAD START - RUN!  %ds" % h) if is_runner \
					else ("HEAD START - WAIT  %ds" % h)
			else:
				var t := maxi(ceili(GameManager.time_left), 0)
				timer_label.text = "TIME  %d:%02d" % [t / 60, t % 60]
			_update_zone_label(is_runner)
			result_label.visible = GameManager.state == GameManager.State.RESULT
			result_label.text = GameManager.result_text

	var lines := PackedStringArray()
	lines.append("Click: capture mouse / Esc: release")
	if GameManager.state == GameManager.State.WAITING:
		if multiplayer.is_server():
			var count := get_tree().get_nodes_in_group("players").size()
			lines.append("Players: %d   Press Enter to start round (alone = vs CPU)" % count)
		else:
			lines.append("Waiting for the host to start the round...")
	info_label.text = "\n".join(lines)


## 鬼にだけ、Runner がいる色エリア名を表示する
func _update_zone_label(is_runner: bool) -> void:
	var runner: Node3D = GameManager.get_runner()
	if is_runner or runner == null or GameManager.state != GameManager.State.PLAYING:
		zone_label.visible = false
		return
	var zone: int = GameManager.zone_at(runner.global_position)
	zone_label.text = "RUNNER ZONE:  %s" % ZONE_NAMES[zone]
	zone_label.modulate = ZONE_COLORS[zone]
	zone_label.visible = true


## Runner にだけ、2Dマップと最寄りの鬼への矢印を表示する
func _update_tracking(player: CharacterBody3D) -> void:
	var is_runner := (
		GameManager.state == GameManager.State.PLAYING
		and player != null
		and multiplayer.get_unique_id() == GameManager.runner_id
	)
	map_panel.visible = is_runner
	if is_runner:
		map_panel.queue_redraw()

	var target: Node3D = _nearest_hunter(player) if is_runner else null
	compass.visible = target != null
	distance_label.visible = target != null
	if target == null:
		return
	var forward: Vector3 = -player.camera.global_transform.basis.z
	var to_target: Vector3 = target.global_position - player.global_position
	var f2 := Vector2(forward.x, forward.z)
	var t2 := Vector2(to_target.x, to_target.z)
	if f2.length_squared() > 0.0001 and t2.length_squared() > 0.0001:
		compass.rotation = f2.angle_to(t2)
	distance_label.text = "%.1f m" % to_target.length()


func _nearest_hunter(player: CharacterBody3D) -> Node3D:
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
	var c := compass.size * 0.5
	var points := PackedVector2Array([
		c + Vector2(0, -28),
		c + Vector2(17, 15),
		c + Vector2(0, 6),
		c + Vector2(-17, 15),
	])
	compass.draw_colored_polygon(points, ARROW_COLOR_TO_HUNTER)


func _on_map_draw() -> void:
	var s := map_panel.size
	var third_x := s.x / 3.0
	var third_y := s.y / 3.0
	# ゾーン色分け（北=上）
	map_panel.draw_rect(Rect2(Vector2.ZERO, s), Color(0.08, 0.08, 0.1, 0.95))
	map_panel.draw_rect(Rect2(0, 0, s.x, third_y), MAP_ZONE_COLORS[GameManager.Zone.NORTH])
	map_panel.draw_rect(Rect2(0, s.y - third_y, s.x, third_y), MAP_ZONE_COLORS[GameManager.Zone.SOUTH])
	map_panel.draw_rect(Rect2(0, third_y, third_x, third_y), MAP_ZONE_COLORS[GameManager.Zone.WEST])
	map_panel.draw_rect(Rect2(s.x - third_x, third_y, third_x, third_y), MAP_ZONE_COLORS[GameManager.Zone.EAST])
	map_panel.draw_rect(Rect2(third_x, third_y, third_x, third_y), MAP_ZONE_COLORS[GameManager.Zone.CENTER])
	map_panel.draw_rect(Rect2(Vector2.ZERO, s), Color(1, 1, 1, 0.5), false, 2.0)
	# 鬼（人間 + CPU）
	var runner_name := str(GameManager.runner_id)
	for p in get_tree().get_nodes_in_group("players"):
		if p.name == runner_name:
			continue
		map_panel.draw_circle(_map_point(p.global_position), 5.0, HUNTER_DOT)
	for cpu in get_tree().get_nodes_in_group("cpu_hunters"):
		map_panel.draw_circle(_map_point(cpu.global_position), 5.0, HUNTER_DOT)
	# 自分（向き付き）
	var player := _get_local_player()
	if player:
		var center := _map_point(player.global_position)
		map_panel.draw_circle(center, 6.0, SELF_DOT)
		var forward: Vector3 = -player.global_transform.basis.z
		var dir2 := Vector2(forward.x, forward.z).normalized()
		map_panel.draw_line(center, center + dir2 * 11.0, SELF_DOT, 2.0)


func _map_point(world: Vector3) -> Vector2:
	var u := clampf((world.x - WORLD_MIN) / WORLD_SIZE, 0.0, 1.0)
	var v := clampf((world.z - WORLD_MIN) / WORLD_SIZE, 0.0, 1.0)
	return Vector2(u * map_panel.size.x, v * map_panel.size.y)


func _get_local_player() -> CharacterBody3D:
	if is_instance_valid(_local_player):
		return _local_player
	var my_name := str(multiplayer.get_unique_id())
	for p in get_tree().get_nodes_in_group("players"):
		if p.name == my_name:
			_local_player = p
			return p
	return null
