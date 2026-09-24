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

	# 8) C-07 T-8: タッチUIを16:9以外のウィンドウサイズで撮る。
	# project.godot は stretch/mode="canvas_items" + aspect="expand" なので、
	# 論理ビューポートの寸法は実ウィンドウの縦横比で変わる(1920x1080固定ではない)。
	# アンカー未設定のまま絶対座標で置いたノードは、ここで初めて破綻が目に見える。
	# **T-6まではこのケースを一度も撮っていなかったため、「狭い/縦長で崩れないこと」
	# という受け入れ基準が実際には検証されていなかった**(RV-05はそれで見逃された)。
	# サイズは「実機の縦横比」を再現できればよく、実解像度である必要は無い。
	# 実際 1080x2340 をそのまま指定すると**ウィンドウが画面の高さを超え**、
	# 画面外になった領域が合成されず、撮れた画像の上部に別レイアウトの残像が
	# 写り込む(T-8で実際に踏んだ。フレーム待ちを増やしても消えなかった)。
	# 1/3 にして縦横比だけ合わせる: 2340x1080 -> 780x360、1080x2340 -> 360x780
	await _shot_touch_controls(out, "touch_landscape", Vector2i(780, 360))
	await _shot_touch_controls(out, "touch_portrait", Vector2i(360, 780))

	get_tree().quit()


## TouchControls を指定のウィンドウサイズ(実機の縦横比を再現する比率)で1枚撮る。
## touch_controls.gd は SettingsManager と GameManager.state を見て自分の visible を
## 決めるので、撮影の間だけ「タッチON」「PLAYING」を作ってから元へ戻す。
## world.tscn は使わない——NetworkManager(Autoload)が同じホストポートへ再バインドしに
## 行き、複数回インスタンス化すると画面がタイトル/ロビー/ネットワークエラーの
## 混ざったものになるため(T-6セッションで実際に踏んだ罠)。
func _shot_touch_controls(out: String, name: String, size: Vector2i) -> void:
	var prev_size := DisplayServer.window_get_size()
	var prev_mode: String = SettingsManager.touch_controls_mode
	var prev_state: int = GameManager.state

	DisplayServer.window_set_size(size)
	SettingsManager.touch_controls_mode = "on"
	GameManager.state = GameManager.State.PLAYING

	var touch: CanvasLayer = load("res://scenes/hud/touch_controls.tscn").instantiate()
	get_tree().root.add_child(touch)
	# ウィンドウのリサイズが論理ビューポートへ反映されるまで数フレーム要る
	for i in 20:
		await get_tree().process_frame
	await _shot(out, name)
	touch.queue_free()

	SettingsManager.touch_controls_mode = prev_mode
	GameManager.state = prev_state
	DisplayServer.window_set_size(prev_size)
	await get_tree().process_frame


func _shot(out: String, name: String) -> void:
	for i in 4:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [out, name])
	print("saved %s.png" % name)
