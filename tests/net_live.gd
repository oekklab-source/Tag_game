extends Node

## 実際の起動経路（main.tscn -> NetworkManager -> world.tscn）と
## 本物のキー入力で、通信対戦がちゃんと始まるかを確かめる。
##
##   ホスト:     godot --headless --path . res://tests/net_live.tscn -- host
##   クライアント: godot --headless --path . res://tests/net_live.tscn -- client 127.0.0.1
##
## net_roles.tscn は world.tscn を直接読んで GameManager の API を直接叩いていたので、
## シーン遷移と InputMap 経由の入力が検証できていなかった。


func _ready() -> void:
	if has_meta("driver"):
		_run()
		return
	# NetworkManager は change_scene_to_file で current_scene を解放する。
	# 自分がそれだと道連れになるので、進行役を root 直下へ立てて逃がす
	var driver := Node.new()
	driver.name = "Driver"
	driver.set_script(get_script())
	driver.set_meta("driver", true)
	get_tree().root.add_child.call_deferred(driver)


func _run() -> void:
	var is_host := NetworkManager.mode != NetworkManager.Mode.CLIENT
	await get_tree().process_frame
	# 実際のボタンと同じ入口を通す
	if is_host:
		NetworkManager.start_host()
	else:
		NetworkManager.start_client(NetworkManager.join_address)
	await get_tree().process_frame
	await get_tree().process_frame
	print("[%s] scene=%s mode=%d" % ["HOST" if is_host else "CLIENT",
		get_tree().current_scene.name if get_tree().current_scene else "<null>",
		NetworkManager.mode])

	# 版数が違う場合、参加側は接続直後に切断されるので peers を待っていると
	# いつまでも進まない。理由が表示されてタイトルへ戻ることだけを見る
	if not is_host and OS.get_cmdline_user_args().has("badver"):
		await _sleep(6.0)
		# last_error は main.gd がラベルへ移した時点で消えるので、画面から読む
		var scene := get_tree().current_scene
		var label := scene.find_child("StatusLabel", true, false) as Label if scene else null
		print("[CLIENT] 戻り先=%s" % (scene.name if scene else "<null>"))
		print("[CLIENT] 画面に出た理由=%s" % (label.text.replace("
", " / ")
			if label else "<ラベルが無い>"))
		get_tree().quit()
		return

	var waited := 0.0
	while multiplayer.get_peers().is_empty() and waited < 25.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	if multiplayer.get_peers().is_empty():
		print("FAIL: 接続できなかった  last_error=%s" % NetworkManager.last_error)
		get_tree().quit()
		return
	print("[%s] 接続 unique=%d peers=%s" % ["HOST" if is_host else "CLIENT",
		multiplayer.get_unique_id(), multiplayer.get_peers()])

	# `-- ... badver`: 版数が食い違う相手が来た場合の振る舞いを確かめる。
	# ホストがわざと違う版数を送ると、参加側は理由を出して抜け、
	# ホスト側も相手の版数の違いに気づいて警告を出すはず
	if not is_host and OS.get_cmdline_user_args().has("badack"):
		# 古いビルドの参加者を演じる（違う版数を返す）
		GameManager.ack_version.rpc_id(1, 99)
		await _sleep(5.0)
		print("[CLIENT] 戻り先=%s" % (get_tree().current_scene.name
			if get_tree().current_scene else "<null>"))
		get_tree().quit()
		return
	if is_host and OS.get_cmdline_user_args().has("badack"):
		await _sleep(5.0)
		print("[HOST] 警告=%s / 残りピア=%s" % [
			GameManager.peer_notice.replace("
", " / "), multiplayer.get_peers()])
		get_tree().quit()
		return
	if is_host and OS.get_cmdline_user_args().has("badver"):
		GameManager.check_version.rpc_id(multiplayer.get_peers()[0], 99)
		await _sleep(3.0)
		print("[HOST] 警告=%s / 残りピア=%s" % [
			GameManager.peer_notice.replace("
", " "), multiplayer.get_peers()])
		get_tree().quit()
		return
	await _sleep(2.0)
	_dump("接続直後", is_host)

	# ラウンド中の途中参加を再現する: ホストは先に1人で始めてしまう
	if is_host and OS.get_cmdline_user_args().has("mid"):
		_press("start_round")
		await _sleep(2.0)
		_dump("先にラウンド開始", is_host)

	# クライアントが R を押す（本物のキーイベント）
	if not is_host:
		_press("toggle_role")
	await _sleep(2.0)
	_dump("R を押した後", is_host)

	# ホストが Enter を押す（本物のキーイベント）
	if is_host:
		_press("start_round")
	await _sleep(2.5)
	_dump("Enter を押した後", is_host)

	# `-- ... stay`: ブラウザから参加して目で見たいときに、ホストを落とさず
	# 一定間隔で状態を吐き続ける
	if OS.get_cmdline_user_args().has("stay"):
		for i in 40:
			await _sleep(3.0)
			_dump("経過%d秒" % ((i + 1) * 3), is_host)
	if is_host:
		await _sleep(3.0)
	get_tree().quit()


## InputMap のイベントをそのまま流し込む。_unhandled_input まで届く経路を通す
func _press(action: StringName) -> void:
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			var e: InputEventKey = ev.duplicate()
			e.pressed = true
			Input.parse_input_event(e)
			print("  -> %s を押した (%s)" % [action, OS.get_keycode_string(e.physical_keycode)])
			return
	print("  -> FAIL: %s にキーが割り当たっていない" % action)


func _dump(title: String, is_host: bool) -> void:
	var names := PackedStringArray()
	for p in get_tree().get_nodes_in_group("players"):
		names.append("%s@%.1f,%.1f" % [p.name, p.global_position.x, p.global_position.z])
	print("[%s] %s: state=%d wanted=%d runner=%d players=[%s]" % [
		"HOST" if is_host else "CLIENT", title,
		GameManager.state, GameManager.wanted_runner, GameManager.runner_id,
		", ".join(names)])


func _sleep(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
