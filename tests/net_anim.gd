extends Node

## 2ピアをつないで「相手の歩きが再現されるか」を実際に確かめる。
##
##   ホスト:     godot --headless --path . res://tests/net_anim.tscn -- host
##   クライアント: godot --headless --path . res://tests/net_anim.tscn -- client 127.0.0.1
##
## Web クライアントから入ると歩きが再現されなかったのを直した時の回帰。
## 原因は「同期位置が前回からどれだけ動いたか」で速度を割り出していたこと。
## それは移動時間ではなくパケットの到着間隔を測っているのと同じで、
## 到着がまとまったり途切れたりするだけで速度が乱高下する。
## 今は権威ピアが実測した sync_speed をそのまま配っている。
##
## ホスト側は接続を待ってから前進入力を押しっぱなしにする。
## クライアント側は相手（ホストのプレイヤー）のアニメを覗いて判定する。

const RUN_SECONDS := 3.0


func _ready() -> void:
	# `-- client <addr>` は NetworkManager._apply_cmdline() が既に拾っている。
	# 指定が無ければ mode は NONE のままで、world.gd がホスト扱いにする
	var is_host := NetworkManager.mode != NetworkManager.Mode.CLIENT
	await get_tree().process_frame
	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world

	if is_host:
		await _run_host(world)
	else:
		await _run_client(world)
	get_tree().quit()


## 相手がつながるのを待ってから、実際の入力経路で前進させる。
## velocity を直接いじると通常の移動制御を通らず、検証にならない
func _run_host(world: Node) -> void:
	var waited := 0.0
	while multiplayer.get_peers().is_empty() and waited < 20.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	if multiplayer.get_peers().is_empty():
		print("HOST: FAIL クライアントが接続してこなかった")
		return
	print("HOST: クライアント接続 %s" % [multiplayer.get_peers()])
	Input.action_press("move_forward")
	var t := 0.0
	while t < RUN_SECONDS + 2.0:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
	Input.action_release("move_forward")
	var me: Node3D = world.get_node_or_null("Players/1")
	print("HOST: 自分の sync_speed=%.2f air=%s" % [me.sync_speed, me.sync_air])


## ホストのプレイヤー（Players/1）は自分にとって非権威。
## そのアニメが Run になり、再生倍率が速度に比例していれば再現できている
func _run_client(world: Node) -> void:
	var players: Node = world.get_node("Players")
	var remote: Node3D = null
	var waited := 0.0
	while remote == null and waited < 20.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		remote = players.get_node_or_null("1")
	if remote == null:
		print("CLIENT: FAIL ホストのプレイヤーが出てこない")
		return
	print("CLIENT: ホストのプレイヤーを検出（権威=%d 自分=%d）"
		% [remote.get_multiplayer_authority(), multiplayer.get_unique_id()])

	var anim: AnimationPlayer = remote.get_node("Humanoid").find_child(
		"AnimationPlayer", true, false)
	# 走り出すまで待ってから、一定時間サンプリングする
	var t := 0.0
	var saw_run := 0
	var saw_idle := 0
	var samples := 0
	var speed_sum := 0.0
	var scale_sum := 0.0
	var moved_from := remote.global_position
	while t < RUN_SECONDS:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		if t < 1.0:
			continue  # 走り始めの助走ぶんは数えない
		samples += 1
		speed_sum += remote.sync_speed
		scale_sum += anim.speed_scale
		if anim.current_animation == "Run":
			saw_run += 1
		elif anim.current_animation == "Idle":
			saw_idle += 1
	var moved := remote.global_position.distance_to(moved_from)
	var run_pct := 100.0 * saw_run / maxi(samples, 1)
	print("CLIENT: 移動量 %.1fm  受信 sync_speed 平均 %.2f m/s  再生倍率 平均 %.2f"
		% [moved, speed_sum / maxi(samples, 1), scale_sum / maxi(samples, 1)])
	print("CLIENT: Run %.0f%% / Idle %.0f%%（%d サンプル）"
		% [run_pct, 100.0 * saw_idle / maxi(samples, 1), samples])
	# 動いているのに Idle が混ざるのが「歩きが再現されない」状態。
	# 少しでも混ざったら落とすため 99% を要求する
	print("CLIENT: %s" % ("OK" if moved > 3.0 and run_pct > 99.0
		else "FAIL 歩きが再現されていない"))
