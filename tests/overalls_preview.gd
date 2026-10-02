extends Node3D
## 独立した衣装試着シーン。左右キーで回転、Spaceで動作切り替え。
const CLIPS := [
	"Idle", "Run", "Jump", "Dive", "Slip", "Nice", "Come", "ComeHip", "ComeCool",
	"SlideEnter", "SlideSit", "SlideReverseFall", "SlideProne", "SlideRecover", "RespawnDizzy",
]
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
	model = preload("res://assets/character/outfits/overalls.glb").instantiate()
	add_child(model)
	animation = model.find_child("AnimationPlayer", true, false)
	for clip in CLIPS:
		assert(animation.has_animation(clip), "既存クリップ欠落: " + clip)
	print("OVERALLS GODOT: all %d clips OK" % CLIPS.size())
	animation.play("Idle")
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.15
	add_child(camera)
	camera.current = true
	var label := Label.new()
	label.text = "オーバーオール  |  ← → : 回転  Space : 動作切り替え"
	label.position = Vector2(16, 16)
	label.visible = not OS.get_cmdline_user_args().has("outfit-shots")
	add_child(label)
	if OS.get_cmdline_user_args().has("outfit-shots"):
		await shots()
	elif DisplayServer.get_name() == "headless":
		get_tree().quit()
func _process(delta: float) -> void:
	angle += Input.get_axis("ui_left", "ui_right") * delta * 1.5
	camera.look_at_from_position(Vector3(sin(angle)*4, 0.87, cos(angle)*4), Vector3(0, 0.87, 0), Vector3.UP)
	if Input.is_action_just_pressed("ui_accept"):
		clip_index = (clip_index + 1) % CLIPS.size()
		animation.play(CLIPS[clip_index])
	if not animation.is_playing(): animation.play(CLIPS[clip_index])
func shots() -> void:
	set_process(false)
	get_viewport().size = Vector2i(640, 680)
	for shot in [["front", 0.0], ["front_three", PI/4], ["side", PI/2], ["back_three", PI*3/4], ["back", PI], ["back_other", PI*5/4], ["side_other", PI*3/2], ["front_other", PI*7/4]]:
		angle = shot[1]
		camera.look_at_from_position(Vector3(sin(angle)*4, 0.87, cos(angle)*4), Vector3(0, 0.87, 0), Vector3.UP)
		animation.play("Idle")
		animation.seek(0.0, true)
		animation.pause()
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://tools/blender/preview/overalls/godot_%s.png" % shot[0])
	set_process(false)
	for shot in [["top", "Idle", 0.0, Vector3(0, 6, 0.001)], ["bottom", "Idle", 0.0, Vector3(0, -6, 0.001)], ["raised", "Nice", 0.45, Vector3(2, 3, 6)], ["run", "Run", 0.23, Vector3(2, 2, -6)], ["prone", "SlideProne", 0.26, Vector3(2, 3, -6)], ["dizzy", "RespawnDizzy", 1.0, Vector3(2, 3, 6)], ["slip", "Slip", 0.53, Vector3(2, 3, -6)], ["slide", "SlideSit", 0.26, Vector3(2, 3, 6)]]:
		animation.play(shot[1])
		animation.seek(shot[2], true)
		animation.pause()
		camera.look_at_from_position(shot[3], Vector3(0, 0.87, 0), Vector3.FORWARD if shot[0] in ["top", "bottom"] else Vector3.UP)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://tools/blender/preview/overalls/godot_%s.png" % shot[0])
	if OS.get_cmdline_user_args().has("pose-audit"):
		get_viewport().size = Vector2i(320, 340)
		var skeleton := model.find_child("Skeleton3D", true, false) as Skeleton3D
		var samples := 0
		for clip in CLIPS:
			for step in range(3):
				animation.play(clip)
				animation.seek(animation.get_animation(clip).length * [0.15, 0.5, 0.85][step], true)
				animation.pause()
				camera.look_at_from_position(Vector3(2, 2.3, -6 if step == 1 else 6), Vector3(0, 0.87, 0), Vector3.UP)
				await get_tree().process_frame
				await RenderingServer.frame_post_draw
				for bone in range(skeleton.get_bone_count()):
					assert(skeleton.get_bone_global_pose(bone).is_finite(), "Invalid skeleton pose: " + clip)
				get_viewport().get_texture().get_image().save_png("res://tools/blender/preview/overalls/pose_%s_%d.png" % [clip, step])
				samples += 1
		print("OVERALLS POSES: %d samples, all skeleton transforms finite" % samples)
	print("OVERALLS GODOT: clips and renders OK")
	get_tree().quit()
