extends SceneTree

## Godot に取り込んだリスポーンアニメと小鳥を描画する。
func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	root.size = Vector2i(640, 480)
	var source: Node = load("res://scenes/world.tscn").instantiate()
	var world_env := WorldEnvironment.new()
	world_env.environment = source.find_child("WorldEnvironment", true, false).environment
	root.add_child(world_env)
	source.free()
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, -30, 0)
	sun.light_energy = 1.4
	root.add_child(sun)
	var map := Node3D.new()
	root.add_child(map)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.24, 0.18, 0.38)
	WorldBuilder._build_walls(map, mat)
	WorldBuilder._build_wall_corners(map, mat)
	preload("res://scenes/perimeter_rim.gd").install(map, map, mat)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.look_at_from_position(Vector3(3.2, 2.8, -4.7), Vector3(0, 0.65, 0), Vector3.UP)
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 3.6
	cam.current = true
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	cam.fov = 75
	cam.far = 4000
	for shot in [["rim", Vector3(-78, 16, 78), Vector3(-580, 16, 580)], ["inside", Vector3(-70, 6, 70), Vector3(-580, 6, 580)]]:
		cam.look_at_from_position(shot[1], shot[2], Vector3.UP)
		await process_frame
		await RenderingServer.frame_post_draw
		var file := "res://tools/blender/preview/giant_%s.png" % shot[0]
		print("SHOT ", file, " ", root.get_texture().get_image().save_png(file))
	quit()

