extends CanvasLayer

## ローカルプレイヤー向け HUD。
## スタミナ・役割・残り時間・結果表示に加え、
## 鬼（Hunter）のときだけ Runner の方向を指すコンパス矢印と距離を表示する。

const ARROW_COLOR := Color(1.0, 0.35, 0.2)

var _local_player: CharacterBody3D

@onready var role_label: Label = $RoleLabel
@onready var timer_label: Label = $TimerLabel
@onready var compass: Control = $Compass
@onready var distance_label: Label = $DistanceLabel
@onready var stamina_bar: ProgressBar = $StaminaBar
@onready var result_label: Label = $ResultLabel
@onready var info_label: Label = $InfoLabel


func _ready() -> void:
	compass.draw.connect(_on_compass_draw)


func _process(_delta: float) -> void:
	var player := _get_local_player()
	_update_stamina(player)
	_update_labels()
	_update_compass(player)


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
			result_label.visible = false
		GameManager.State.PLAYING, GameManager.State.RESULT:
			if my_id == GameManager.runner_id:
				role_label.text = "RUN AWAY!"
				role_label.modulate = Color(0.4, 1.0, 0.55)
			else:
				role_label.text = "You are a HUNTER - catch the runner!"
				role_label.modulate = Color(1.0, 0.45, 0.4)
			var t := maxi(ceili(GameManager.time_left), 0)
			timer_label.text = "TIME  %d:%02d" % [t / 60, t % 60]
			result_label.visible = GameManager.state == GameManager.State.RESULT
			result_label.text = GameManager.result_text

	var lines := PackedStringArray()
	lines.append("Click: capture mouse / Esc: release")
	if GameManager.state == GameManager.State.WAITING:
		if multiplayer.is_server():
			var count := get_tree().get_nodes_in_group("players").size()
			lines.append("Players: %d   Press Enter to start round (2+ players)" % count)
		else:
			lines.append("Waiting for the host to start the round...")
	info_label.text = "\n".join(lines)


func _update_compass(player: CharacterBody3D) -> void:
	var runner: Node3D = GameManager.get_runner()
	var show_compass := (
		GameManager.local_is_hunter()
		and player != null
		and runner != null
		and runner != player
	)
	compass.visible = show_compass
	distance_label.visible = show_compass
	if not show_compass:
		return
	var forward: Vector3 = -player.camera.global_transform.basis.z
	var to_runner: Vector3 = runner.global_position - player.global_position
	var f2 := Vector2(forward.x, forward.z)
	var t2 := Vector2(to_runner.x, to_runner.z)
	if f2.length_squared() > 0.0001 and t2.length_squared() > 0.0001:
		compass.rotation = f2.angle_to(t2)
	distance_label.text = "%.1f m" % to_runner.length()


func _on_compass_draw() -> void:
	var c := compass.size * 0.5
	var points := PackedVector2Array([
		c + Vector2(0, -28),
		c + Vector2(17, 15),
		c + Vector2(0, 6),
		c + Vector2(-17, 15),
	])
	compass.draw_colored_polygon(points, ARROW_COLOR)


func _get_local_player() -> CharacterBody3D:
	if is_instance_valid(_local_player):
		return _local_player
	var my_name := str(multiplayer.get_unique_id())
	for p in get_tree().get_nodes_in_group("players"):
		if p.name == my_name:
			_local_player = p
			return p
	return null
