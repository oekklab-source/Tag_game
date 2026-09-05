extends Node

## スタミナゲージの残量別（100%〜0%）の描画確認用スクリプト。
## 実行: godot --path . res://tests/shot_stamina.tscn

func _ready() -> void:
	await get_tree().process_frame
	
	var hud: CanvasLayer = load("res://scenes/hud.tscn").instantiate()
	add_child(hud)
	
	var p: Player = load("res://scenes/player.tscn").instantiate()
	p.name = str(multiplayer.get_unique_id())
	add_child(p)
	p.add_to_group("players")
	
	GameManager.state = GameManager.State.PLAYING
	
	for f in 15:
		await get_tree().process_frame
	
	# プレイヤーの物理処理（自動スタミナ回復）を止めて正確なスタミナ値で描画
	p.set_physics_process(false)
	p.set_process(false)
	
	var bar: Control = hud.get_node("StaminaBar")
	var out_dir := "C:/Users/hamaogeoge/.gemini/antigravity-ide/brain/e2697ba6-2d9d-4c7c-acd1-1f7eda1437c6"
	var levels: Array[float] = [1.0, 0.50, 0.20, 0.10, 0.05, 0.02, 0.005, 0.0]
	var names: Array[String] = ["stamina_100", "stamina_50", "stamina_20", "stamina_10", "stamina_05", "stamina_02", "stamina_005", "stamina_00"]
	
	for i in levels.size():
		p.stamina = p.stamina_max() * levels[i]
		bar.queue_redraw()
		for f in 4:
			await RenderingServer.frame_post_draw
		_shot(out_dir, names[i], bar)
	
	get_tree().quit()


func _shot(out: String, name: String, bar: Control) -> void:
	var img: Image = get_viewport().get_texture().get_image()
	var rect := bar.get_global_rect()
	var crop_rect := Rect2i(
		int(rect.position.x - 20),
		int(rect.position.y - 40),
		int(rect.size.x + 40),
		int(rect.size.y + 60)
	)
	var cropped: Image = img.get_region(crop_rect)
	cropped.save_png("%s/%s.png" % [out, name])
	print("saved %s.png" % name)
