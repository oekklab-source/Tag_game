extends SceneTree

## Godot に取り込んだ滑り台アニメを、斜面に沿う姿勢で描画する。
func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	root.size = Vector2i(640, 480)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.15, 0.20)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.7
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	root.add_child(world_env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, -30, 0)
	sun.light_energy = 1.4
	root.add_child(sun)
	var pitch := atan(0.375)
	var deck := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(4, 8)
	deck.mesh = plane
	deck.rotation.x = pitch
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.48, 0.60)
	deck.material_override = mat
	root.add_child(deck)
	var humanoid: Node3D = load("res://scenes/humanoid.tscn").instantiate()
	root.add_child(humanoid)
	humanoid.set_color(Color(0.35, 0.78, 0.45))
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.look_at_from_position(Vector3(3.2, 2.8, 4.7), Vector3(0, 0.65, 0), Vector3.UP)
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 3.6
	cam.current = true
	var anim: AnimationPlayer = humanoid.get_node("Model").find_child("AnimationPlayer", true, false)
	for shot in [["sit", 2, 0.5, PI, -pitch], ["prone", 4, 0.3, 0.0, pitch],
			["recover", 5, 0.10, 0.0, pitch * 0.625],
			["prone_front", 4, 0.0, 0.0, pitch],
			["prone_front_rock", 4, 0.33, 0.0, pitch],
			["fall_front", 3, 0.95, 0.0, pitch]]:
		if "front" in shot[0]:
			cam.look_at_from_position(Vector3(0, 2.0, -3.5), Vector3(0, 0.35, 0), Vector3.UP)
			cam.size = 2.5
		humanoid.set_slide(Vector4(shot[1], shot[2], shot[3], shot[4]), 0, 1)
		humanoid.update_motion(5.0, true, 1)
		anim.play(humanoid.SLIDE_ANIMS[shot[1]], 0)
		anim.seek(shot[2], true)
		anim.pause()
		await process_frame
		await RenderingServer.frame_post_draw
		var file := "res://tools/blender/preview/slide/godot_%s.png" % shot[0]
		print("SHOT ", file, " ", root.get_texture().get_image().save_png(file))
	quit()
