extends Node3D
## 独立した衣装試着シーン。左右キーで回転、Spaceで動作切り替え。
const CLIPS := ["Idle", "Run", "Dive", "Slip", "SlideSit", "SlideProne", "RespawnDizzy", "Nice", "Come"]
var model: Node3D
var animation: AnimationPlayer
var camera: Camera3D
var clip_index := 0
var angle := 0.35
func _ready() -> void:
	var source: Node = load("res://scenes/world.tscn").instantiate()
	var env := WorldEnvironment.new()
	env.environment = source.find_child("WorldEnvironment", true, false).environment.duplicate(true)
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.12, 0.15, 0.2)
	add_child(env)
	var sun: DirectionalLight3D = source.get_node("Sun").duplicate()
	add_child(sun)
	source.free()
	model = preload("res://assets/character/outfits/basketball_prototype.glb").instantiate()
	add_child(model)
	var body_material := StandardMaterial3D.new()
	body_material.albedo_color = Color(0.3, 0.75, 0.44)
	model.find_child("Body", true, false).material_override = body_material
	animation = model.find_child("AnimationPlayer", true, false)
	for clip in CLIPS:
		assert(animation.has_animation(clip), "既存クリップ欠落: " + clip)
	animation.play("Idle")
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.15
	add_child(camera)
	camera.current = true
	var label := Label.new()
	label.text = "バスケ衣装の試作  |  ← → : 回転  Space : 動作切り替え"
	label.position = Vector2(16, 16)
	add_child(label)
	if OS.get_cmdline_user_args().has("outfit-shots"):
		await shots()
func _process(delta: float) -> void:
	angle += Input.get_axis("ui_left", "ui_right") * delta * 1.5
	camera.look_at_from_position(Vector3(sin(angle)*4, 1.75, cos(angle)*4), Vector3(0, 0.87, 0), Vector3.UP)
	if Input.is_action_just_pressed("ui_accept"):
		clip_index = (clip_index + 1) % CLIPS.size()
		animation.play(CLIPS[clip_index])
	if not animation.is_playing(): animation.play(CLIPS[clip_index])
func shots() -> void:
	get_viewport().size = Vector2i(640, 680)
	for shot in [["front", 0.0], ["front_three", PI/4], ["side", PI/2], ["back_three", PI*3/4], ["back", PI], ["back_other", PI*5/4], ["side_other", PI*3/2], ["front_other", PI*7/4]]:
		angle = shot[1]
		animation.play("Idle")
		animation.seek(0.0, true)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://tools/blender/preview/basketball/godot_%s.png" % shot[0])
	print("BASKETBALL GODOT: clips and renders OK")
	get_tree().quit()
