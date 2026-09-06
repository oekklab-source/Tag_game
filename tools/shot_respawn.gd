extends SceneTree

## Godot に取り込んだリスポーンアニメと小鳥を描画する。
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
	var pitch := 0.0
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
	cam.look_at_from_position(Vector3(3.2, 2.8, -4.7), Vector3(0, 0.65, 0), Vector3.UP)
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 3.6
	cam.current = true
	var anim: AnimationPlayer = humanoid.get_node("Model").find_child("AnimationPlayer", true, false)
	for time in [0.3, 1.2, 2.85]:
		humanoid.set_respawn(3.0 - time)
		humanoid.update_motion(0.0, true, 0.0)
		anim.play("RespawnDizzy", 0)
		anim.seek(time, true)
		anim.pause()
		humanoid.get_node("RespawnBirds").show_time(time)
		await process_frame
		await RenderingServer.frame_post_draw
		var file := "res://tools/blender/preview/respawn/godot_%s.png" % time
		print("SHOT ", file, " ", root.get_texture().get_image().save_png(file))
	quit()
