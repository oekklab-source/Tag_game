extends Node

## UI の見た目を PNG に落とす。--headless では描画されないのでウィンドウ有りで実行する。
##
##   godot --path . res://tests/uishot.tscn -- --shots <出力先フォルダ>

func _ready() -> void:
	var out := "."
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--shots" and i + 1 < args.size():
			out = args[i + 1]
	DirAccess.make_dir_recursive_absolute(out)
	await get_tree().process_frame

	# 1) タイトル画面
	var title: Node = load("res://scenes/title.tscn").instantiate()
	get_tree().root.add_child(title)
	get_tree().current_scene = title
	await _shot(out, "title")
	title.queue_free()
	await get_tree().process_frame

	# 2) 待機中のロビー（3人いる状態を作る）
	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world
	for i in 40:
		await get_tree().physics_frame
	for id in [4242, 7,]:
		var p: CharacterBody3D = load("res://scenes/player.tscn").instantiate()
		p.name = str(id)
		world.get_node("Players").add_child(p)
	# ②⑥ロビー名簿のレート帯バッジ・生数値・見た目プレビューが実データ入りで
	# どう見えるかも確認する(peer_profilesが空だとこれらの欄は表示されない)
	GameManager.peer_profiles[4242] = {"rating": 1720, "tier": "platinum",
		"costume": "neon", "colors": [], "hat": "party"}
	GameManager.peer_profiles[7] = {"rating": 980, "tier": "bronze",
		"costume": "default", "colors": [], "hat": "none"}
	await get_tree().physics_frame
	await _shot(out, "lobby")

	GameManager.set_wanted_runner_to(7)
	await _shot(out, "lobby_picked")

	# 3) ラウンド中
	GameManager.request_start_round()
	for i in 20:
		await get_tree().physics_frame
	await _shot(out, "playing")

	# 3b) エモート（自分＝鬼が「カモン！」を出した瞬間）。
	# 頭上の吹き出しと、ミニマップで自分のドットが光ることを見る
	var me: Node = world.get_node("Players/1")
	me._start_emote()
	for i in 20:
		await get_tree().physics_frame
	await _shot(out, "emote")

	# 4) リザルト
	GameManager._end_round(false, GameManager.EndReason.TAGGED)
	for i in 5:
		await get_tree().physics_frame
	await _shot(out, "result")

	# M-15: world.tscn配下の単体画面(ranking_dialog/room_match_dialog/migration_overlay)は
	# title.tscnの子として埋め込まれた状態でなくても単体instantiateで開けるため、
	# world.tscnを片付けてから撮る(worldとダイアログを同時に映すと見た目の判断がしづらいため)
	world.queue_free()
	await get_tree().process_frame

	# 5) ランキングダイアログ
	var ranking: Control = load("res://scenes/ranking_dialog.tscn").instantiate()
	get_tree().root.add_child(ranking)
	ranking.open()
	await get_tree().process_frame
	await _shot(out, "ranking_dialog")
	ranking.queue_free()
	await get_tree().process_frame

	# 6) ルームマッチダイアログ
	var room_match: Control = load("res://scenes/room_match_dialog.tscn").instantiate()
	get_tree().root.add_child(room_match)
	room_match.open()
	await get_tree().process_frame
	await _shot(out, "room_match_dialog")
	room_match.queue_free()
	await get_tree().process_frame

	# 7) ホストマイグレーション中のオーバーレイ
	var migration: CanvasLayer = load("res://scenes/migration_overlay.tscn").instantiate()
	get_tree().root.add_child(migration)
	migration.set_text("新しいホストへ引き継ぎ中…")
	await get_tree().process_frame
	await _shot(out, "migration_overlay")
	migration.queue_free()
	await get_tree().process_frame

	get_tree().quit()


func _shot(out: String, name: String) -> void:
	for i in 4:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [out, name])
	print("saved %s.png" % name)
