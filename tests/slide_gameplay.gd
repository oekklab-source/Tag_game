extends Node3D

## 実際の Player / Area / 斜面コリジョンを通して、出口への接近と逆走を検証する。
var failures := 0
var player: CharacterBody3D


func check(ok: bool, message: String) -> void:
	print("PASS: " if ok else "FAIL: ", message)
	if not ok:
		failures += 1


func frames(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _ready() -> void:
	await get_tree().process_frame
	var args := OS.get_cmdline_user_args()
	var net_client := args.has("slide-client")
	var net_host := args.has("slide-host")
	if net_client or net_host:
		var peer := ENetMultiplayerPeer.new()
		var err := peer.create_client("127.0.0.1", 19989) if net_client else peer.create_server(19989, 1)
		check(err == OK, "テスト用ピアを作成")
		if err != OK:
			get_tree().quit(1)
			return
		multiplayer.multiplayer_peer = peer
		for i in 300:
			if not multiplayer.get_peers().is_empty():
				break
			await frames(1)
		check(not multiplayer.get_peers().is_empty(), "テスト用ピアが接続")
		if multiplayer.get_peers().is_empty():
			get_tree().quit(1)
			return
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 0.2, 30)
	shape.shape = box
	floor_body.position.y = -0.1
	floor_body.add_child(shape)
	add_child(floor_body)
	var pts: Array[Vector3] = [Vector3(0, 3, -8), Vector3.ZERO, Vector3(0, 0, 1.5)]
	var mat := StandardMaterial3D.new()
	WorldBuilder._slide_body(self, 0, pts, mat, mat)
	WorldBuilder._slide_area(self, 0, pts)
	player = load("res://scenes/player.tscn").instantiate()
	player.name = "1"
	add_child(player)
	if net_client:
		await observe_network()
		return
	player.teleport(Vector3(0, 0.05, 2.3))
	await frames(12)
	Input.action_press("move_forward")
	var smallest_z := 100.0
	var phase_seen := {}
	var free_approach := false
	var entered := false
	var recovered := false
	var immediate_control := false
	for i in 150:
		await frames(1)
		var phase: int = player.slide_ride.phase
		phase_seen[phase] = true
		smallest_z = minf(smallest_z, player.position.z)
		if player.position.z > 0.05 and player.position.z < 0.8 and not entered:
			free_approach = not player.slide_ride.active() and player.velocity.z < -1.0
		if phase == SlideRide.Phase.REVERSE_FALL:
			entered = true
		if phase == SlideRide.Phase.RECOVER:
			recovered = true
			# 横方向へ操作し、回復完了を待たずに速度が変わることを確認。
			Input.action_release("move_forward")
			Input.action_press("move_right")
			if absf(player.velocity.x) > 0.1 and not player.slide_ride.active():
				immediate_control = true
	Input.action_release("move_forward")
	Input.action_release("move_right")
	print("reverse phases=", phase_seen.keys(), " climbed=", -smallest_z)
	check(free_approach, "出口平地では押し戻されず斜面まで接近できる")
	check(entered and smallest_z < -1.0 and smallest_z > -1.8, "逆走時は1歩追加した距離まで登れる")
	check(phase_seen.has(SlideRide.Phase.PRONE), "前方転倒からうつ伏せ滑走へ進む")
	check(recovered and immediate_control, "出口で起き上がり中から横移動できる")
	player.teleport(Vector3(0, 2.95, -7.6))
	phase_seen.clear()
	for i in 130:
		await frames(1)
		phase_seen[player.slide_ride.phase] = true
	check(phase_seen.has(SlideRide.Phase.ENTER) and phase_seen.has(SlideRide.Phase.SIT),
		"順方向は座って滑るアニメになる")
	check(player.position.z > 0 and not player.slide_ride.active(), "順方向で出口を通過し移動制御が戻る")
	var ride := SlideRide.new()
	ride.contact(1, Vector3.BACK, 0.35, 6, 18, true, Vector3.FORWARD * 7)
	ride.release(1)
	ride.tick(0.05)
	ride.contact(1, Vector3.BACK, 0.35, 6, 18, true, Vector3.FORWARD * 7)
	check(ride.phase == SlideRide.Phase.RECOVER, "回復中の接触で転倒を再開しない")
	ride.release(1)
	ride.tick(SlideRide.RECOVER_TIME)
	ride.contact(1, Vector3.BACK, 0.35, 6, 18, true, Vector3.FORWARD * 7)
	check(ride.phase == SlideRide.Phase.REVERSE_FALL, "回復後は入力を離さず再試行できる")
	var anim: AnimationPlayer = player.get_node("Humanoid/Model").find_child("AnimationPlayer", true, false)
	for clip in ["Run", "Slip", "Nice", "Come", "SlideEnter", "SlideSit", "SlideReverseFall", "SlideProne", "SlideRecover"]:
		check(anim.has_animation(clip), "アニメの保持/追加: " + clip)
	check(is_equal_approx(anim.get_animation("SlideRecover").length, SlideRide.RECOVER_TIME),
		"起き上がりは約0.27秒")
	player.teleport(Vector3(0, 0.1, 3))
	check(player.sync_slide == Vector4.ZERO and not player.slide_ride.active(), "ワープ時は滑走状態を解除")
	player.diving = true
	player.apply_slide(Vector3.BACK, 6.0, 18.0, 0.35, true, 100)
	check(not player.diving and player.slide_ride.active(), "ダイブで斜面へ入っても滑走へ切り替える")
	player.teleport(Vector3(0, 0.1, 3))
	if not net_host:
		check_cpu()
		check_cpu("cpu_runner")
		await check_held_uphill()
		await check_placed_block_escape()
		await check_placed_block_shatter(0.0, "正面ブロック")
		await check_placed_block_shatter(PI * 0.25, "斜め45度ブロック")
		await check_collapsing_block_side_escape()
		await check_block_stays_outside_slide()
	print("SLIDE GAMEPLAY: ", "ALL OK" if failures == 0 else str(failures) + " FAILED")
	if net_host:
		await frames(120)
	get_tree().quit(0 if failures == 0 else 1)


func check_held_uphill() -> void:
	player.teleport(Vector3(0, 0.05, 2.3))
	await frames(12)
	Input.action_press("move_forward")
	var restarts := 0
	var previous := 0
	var last_change := 0
	var chatter := 0
	var complete_cycles := 0
	var saw_prone := false
	for i in 360:
		await frames(1)
		var phase: int = player.slide_ride.phase
		if phase == SlideRide.Phase.REVERSE_FALL and previous != phase:
			restarts += 1
		if phase == SlideRide.Phase.PRONE:
			saw_prone = true
		if phase == SlideRide.Phase.RECOVER and previous != phase:
			if saw_prone:
				complete_cycles += 1
			saw_prone = false
		if phase != previous:
			# NONE -> 再入場の1フレームは正常。転倒/滑走/回復の即時中断を検出する。
			if previous != SlideRide.Phase.NONE and i - last_change < 3:
				chatter += 1
			last_change = i
		previous = phase
	check(restarts >= 3 and complete_cycles >= 2, "上を6秒押し続けると自然に登りと転倒を繰り返す")
	check(chatter == 0, "転倒・滑走・回復の高速な切り替えがない")
	print("held-input cycles=", complete_cycles, " retries=", restarts, " chatter=", chatter)
	Input.action_release("move_forward")
	await frames(2)
	Input.action_press("move_forward")
	var retried := false
	for i in 120:
		await frames(1)
		retried = retried or player.slide_ride.phase == SlideRide.Phase.REVERSE_FALL
	Input.action_release("move_forward")
	check(retried, "上入力を離した後は再挑戦できる")
	player.teleport(Vector3(0, 0.1, 3))


## 幅5mの設置ブロックを走路中央へ置き、接触して停止してから左右入力する。
## 最初から横入力するとブロックへ着く前に避けてしまい、接触時補助の検証にならない。
func check_placed_block_escape() -> void:
	check(is_equal_approx(WorldBuilder.SLIDE_WIDTH, 10.0), "滑り台のデッキ幅は10m")
	var clear_width := WorldBuilder.SLIDE_WIDTH - WorldBuilder.SLIDE_RAIL_W * 2.0
	var side_gap := (clear_width - 5.0) * 0.5
	check(is_equal_approx(clear_width, 9.0) and is_equal_approx(side_gap, 2.0),
		"中央ブロックの左右に各2mの隙間を確保")
	check(is_equal_approx(Player.SLIDE_STEER, 9.0), "通常滑走の左右操作量を維持")

	var block: StaticBody3D = load("res://scenes/gimmicks/placed_block.tscn").instantiate()
	block.name = "SlideTestBlock"
	block.position = Vector3(0.0, 1.5, -4.0)
	add_child(block)
	# このテストは接触中2m/s補助だけを単独確認する。破砕は次のテストで扱う。
	block.hit_area.monitoring = false
	await frames(2)

	await check_block_side(block, "move_right", 1.0, "右側")
	await check_block_side(block, "move_left", -1.0, "左側")
	block.queue_free()
	await frames(2)


func check_placed_block_shatter(yaw: float, label: String) -> void:
	var block: StaticBody3D = load("res://scenes/gimmicks/placed_block.tscn").instantiate()
	block.name = "CollapseTestBlock"
	block.position = Vector3(0.0, 1.5, -4.0)
	block.rotation.y = yaw
	add_child(block)
	await frames(2)
	player.teleport(Vector3(0, 2.95, -7.6))
	await frames(8)

	var started := false
	for i in 180:
		await frames(1)
		if is_instance_valid(block) and block._break_started:
			started = true
			break
	check(started, label + "は滑走接触で破砕予告を始める")
	if not is_instance_valid(block):
		return
	check(is_equal_approx(block.SLIDE_HIT_SPEED, 4.0),
		label + "への接触直後の下り速度上限は4m/s")
	await frames(30)
	check(not block._shattered and not block.solid_shape.disabled,
		label + "は予告中も有限の当たり判定を維持")
	check(block.mesh.visible and block._fragments.is_empty(),
		label + "は1秒経過前には砕けない")
	var passed_before_shatter := player.position.z > -3.0
	for i in 60:
		await frames(1)
		if block._shattered:
			break
		if player.position.z > -3.0:
			passed_before_shatter = true
	if is_zero_approx(yaw):
		check(not passed_before_shatter, label + "は砕ける前に正面から貫通できない")
	check(block._shattered and block._break_elapsed >= block.SHATTER_DELAY,
		label + "は接触から約1秒後に砕ける")
	check(block.solid_shape.disabled and not block.mesh.visible,
		label + "は砕けた瞬間に本体の当たり判定と表示を解除")
	check(block._fragments.size() == block.FRAGMENT_COLS * block.FRAGMENT_ROWS,
		label + "は8個の破片へ分かれる")
	var targets_on_slope := true
	var rotations_on_slope := true
	for i in block._fragment_targets.size():
		var height: float = block._fragment_targets[i].dot(block._slide_normal_local)
		targets_on_slope = targets_on_slope and absf(height - block.FRAGMENT_SIZE.y * 0.5) < 0.02
		var piece_up: Vector3 = block._fragment_rotations[i] * Vector3.UP
		rotations_on_slope = rotations_on_slope and piece_up.dot(block._slide_normal_local) > 0.98
	check(targets_on_slope and rotations_on_slope,
		label + "の破片は斜面へ沿う終点と姿勢を持つ")
	await frames(30)
	var slid_downhill := true
	for i in block._fragments.size():
		var delta: Vector3 = block._fragments[i].position - block._fragment_starts[i]
		slid_downhill = slid_downhill and delta.dot(block._slide_tangent_local) > 0.2
	check(slid_downhill, label + "の破片は斜面の下方向へ滑る")
	check(block._material.albedo_color.a < 0.9, label + "の破片は滑りながら薄くなる")
	for i in 45:
		await frames(1)
		if not is_instance_valid(block):
			break
	check(not is_instance_valid(block), label + "の破片は約1秒後に消える")
	await frames(60)
	check(player.position.z > -3.0, label + "は破砕後に滑走を再開する")


func check_collapsing_block_side_escape() -> void:
	var block: StaticBody3D = load("res://scenes/gimmicks/placed_block.tscn").instantiate()
	block.name = "SideEscapeCollapseBlock"
	block.position = Vector3(0.0, 1.5, -4.0)
	add_child(block)
	await frames(2)
	player.teleport(Vector3(2.2, 2.95, -7.6))
	await frames(8)
	for i in 180:
		await frames(1)
		if block._break_started:
			break
	Input.action_press("move_right")
	var escaped_before_shatter := false
	for i in 60:
		await frames(1)
		if (not block._shattered and not touching(player, block)
				and player.position.x > 2.8 and player.velocity.dot(Vector3.BACK) > 0.5):
			escaped_before_shatter = true
			break
	Input.action_release("move_right")
	check(escaped_before_shatter,
		"破砕前でも左右からブロック範囲外へ出れば滑走を再開できる")
	block.queue_free()
	await frames(2)


func check_block_stays_outside_slide() -> void:
	var block: StaticBody3D = load("res://scenes/gimmicks/placed_block.tscn").instantiate()
	block.name = "NormalBlock"
	block.position = Vector3(7.0, 0.0, 5.0)
	add_child(block)
	await frames(2)
	player.teleport(Vector3(7.0, 0.05, 3.5))
	await frames(5)
	block._on_slide_hit(player)
	await frames(2)
	check(not block._break_started and not block.solid_shape.disabled,
		"滑走状態でなければ通常ブロックのまま")
	block.queue_free()
	await frames(2)


func check_block_side(block: StaticBody3D, action: String, side_sign: float, label: String) -> void:
	for key in ["move_left", "move_right", "move_forward", "move_back"]:
		Input.action_release(key)
	player.teleport(Vector3(0, 2.95, -7.6))
	await frames(8)
	var touched := false
	for i in 180:
		await frames(1)
		if touching(player, block):
			touched = true
			break
	check(touched, label + "回避前に中央ブロックへ接触")
	Input.action_press(action)
	var assisted := false
	var passed := false
	for i in 180:
		await frames(1)
		var side_speed := player.velocity.x * side_sign
		if touching(player, block) and side_speed >= Player.SLIDE_BLOCK_SIDE_SPEED - 0.1:
			assisted = true
		if player.position.z > -2.8:
			passed = true
			break
	Input.action_release(action)
	check(assisted, label + "入力で接触中の横速度2m/sを確保")
	check(passed and player.position.x * side_sign > 2.8,
		label + "の隙間からブロックを通過")


func touching(body: CharacterBody3D, target: CollisionObject3D) -> bool:
	for i in body.get_slide_collision_count():
		if body.get_slide_collision(i).get_collider() == target:
			return true
	return false


func check_cpu(kind := "cpu_hunter") -> void:
	var cpu: CharacterBody3D = load("res://scenes/%s.tscn" % kind).instantiate()
	cpu.name = kind
	add_child(cpu)
	cpu.set_physics_process(false)
	cpu.velocity = Vector3.FORWARD * 7
	cpu.apply_slide(Vector3.BACK, 6.0, 18.0, 0.35, true, 101)
	check(cpu.slide_ride.phase == SlideRide.Phase.REVERSE_FALL, kind + ": 同じ逆走処理を使う")
	cpu.release_slide(101)
	check(not cpu.slide_ride.active() and cpu.slide_ride.phase == SlideRide.Phase.RECOVER,
		kind + ": 出口で操作拘束を解除")
	cpu.queue_free()


func observe_network() -> void:
	var seen := {}
	var matched := {}
	var anim: AnimationPlayer = player.get_node("Humanoid/Model").find_child("AnimationPlayer", true, false)
	var clips := ["", "SlideEnter", "SlideSit", "SlideReverseFall", "SlideProne", "SlideRecover"]
	for i in 350:
		await frames(1)
		var phase := int(player.sync_slide.x)
		seen[phase] = true
		if phase > 0 and anim.current_animation == clips[phase]:
			matched[phase] = true
	for phase in [1, 2, 3, 4, 5]:
		check(seen.has(phase) and matched.has(phase), "別ピアでも状態とアニメが一致: " + clips[phase])
	print("SLIDE NETWORK: ", "ALL OK" if failures == 0 else str(failures) + " FAILED")
	get_tree().quit(0 if failures == 0 else 1)
