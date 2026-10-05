extends Node3D

## 実際の Player / Area / 斜面コリジョンを通して、出口への接近と逆走を検証する。
var failures := 0
var player: CharacterBody3D
var network_block: StaticBody3D


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
	if net_client or net_host:
		network_block = load("res://scenes/gimmicks/placed_block.tscn").instantiate()
		network_block.name = "NetworkExpiryBlock"
		network_block.position = Vector3(7.0, 0.0, 5.0)
		add_child(network_block)
	if net_client:
		await observe_network()
		return
	if net_host:
		# クライアント側にも同じノードパスが生成されてから短縮RPCを送る。
		await frames(10)
		network_block.report_slide_collision()
	await check_reverse_retreat()
	await check_dive_facing_direction()
	await check_dive_from_walkable_approach()
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
		if player.position.z > -1.8 and player.position.z < -0.4 and not entered:
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
	check(free_approach, "下端から確定線までは通常移動で登れる")
	check(entered and smallest_z < -1.9 and smallest_z > -2.4,
		"下端から2mの確定線で転倒する")
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
	ride.contact(1, Vector3.BACK, 0.35, 6, 18, 0.0, 8.0, Vector3.FORWARD * 7)
	ride.contact(1, Vector3.BACK, 0.35, 6, 18, 2.0, 6.0, Vector3.FORWARD * 7)
	ride.release(1)
	ride.tick(0.05)
	ride.contact(1, Vector3.BACK, 0.35, 6, 18, 0.0, 8.0, Vector3.FORWARD * 7)
	check(ride.phase == SlideRide.Phase.RECOVER, "回復中の接触で転倒を再開しない")
	ride.release(1)
	ride.tick(SlideRide.RECOVER_TIME)
	ride.contact(1, Vector3.BACK, 0.35, 6, 18, 0.0, 8.0, Vector3.FORWARD * 7)
	ride.contact(1, Vector3.BACK, 0.35, 6, 18, 2.0, 6.0, Vector3.FORWARD * 7)
	check(ride.phase == SlideRide.Phase.REVERSE_FALL, "回復後は入力を離さず再試行できる")
	var anim: AnimationPlayer = player.get_node("Humanoid/Model").find_child("AnimationPlayer", true, false)
	for clip in ["Run", "Slip", "Nice", "Come", "SlideEnter", "SlideSit", "SlideReverseFall", "SlideProne", "SlideRecover"]:
		check(anim.has_animation(clip), "アニメの保持/追加: " + clip)
	check(is_equal_approx(anim.get_animation("SlideRecover").length, SlideRide.RECOVER_TIME),
		"起き上がりは約0.27秒")
	player.teleport(Vector3(0, 0.1, 3))
	check(player.sync_slide == Vector4.ZERO and not player.slide_ride.active(), "ワープ時は滑走状態を解除")
	await check_reverse_dive(false)
	await check_reverse_dive(true)
	check_downhill_dive_speed()
	await check_dive_at_height(0.5, true)
	await check_dive_at_height(4.0, true)
	await check_dive_at_height(7.0, true)
	await check_dive_at_height(4.0, false)
	if not net_host:
		check_cpu()
		check_cpu("cpu_runner")
		await check_held_uphill()
		await check_placed_block_escape()
	print("SLIDE GAMEPLAY: ", "ALL OK" if failures == 0 else str(failures) + " FAILED")
	if net_host:
		await frames(300)
	get_tree().quit(0 if failures == 0 else 1)


func check_reverse_retreat() -> void:
	player.teleport(Vector3(0, 0.05, 2.3))
	await frames(12)
	Input.action_press("move_forward")
	var approached := false
	var forced := false
	for i in 90:
		await frames(1)
		forced = forced or player.slide_ride.active()
		if player.position.z < -1.2:
			approached = player.slide_ride.approaching_reverse()
			break
	Input.action_release("move_forward")
	Input.action_press("move_back")
	var returned := false
	for i in 90:
		await frames(1)
		forced = forced or player.slide_ride.active()
		if player.position.z > 0.25:
			returned = true
			break
	Input.action_release("move_back")
	check(approached and returned and not forced,
		"確定線の手前なら滑らずに引き返せる")
	check(not player.slide_ride.approaching_reverse() and not player.slide_ride.active(),
		"斜面から戻ると未確定状態を解除する")


func check_dive_facing_direction() -> void:
	player.teleport(Vector3(0, 0.05, 3.0))
	await frames(3)
	player.rotation.y = 0.0
	player.humanoid.rotation.y = PI * 0.5
	player.sync_facing_yaw = player.humanoid.rotation.y
	var expected: Vector3 = -player.humanoid.global_transform.basis.z
	expected.y = 0.0
	expected = expected.normalized()
	player._start_dive()
	var actual := Vector3(player.velocity.x, 0.0, player.velocity.z).normalized()
	check(actual.dot(expected) > 0.999 and absf(actual.x) > 0.9,
		"ダイブはカメラ奥ではなくキャラクターが見ている方向へ進む")
	player.rotation.y += PI * 0.5
	await frames(2)
	var after_camera_turn: Vector3 = -player.humanoid.global_transform.basis.z
	after_camera_turn.y = 0.0
	after_camera_turn = after_camera_turn.normalized()
	check(after_camera_turn.dot(expected) > 0.999,
		"ダイブ中にカメラを90度回しても世界座標上の姿勢を維持する")
	check(Vector3(player.velocity.x, 0.0, player.velocity.z).normalized().dot(expected) > 0.999,
		"カメラ回転でダイブの進行方向も変化しない")
	player.teleport(Vector3(0, 0.1, 3))
	player.rotation.y = 0.0
	player.humanoid.rotation.y = 0.0
	player.sync_facing_yaw = 0.0


func check_reverse_dive(hold_uphill: bool) -> void:
	player.teleport(Vector3(0, 0.05, 2.3))
	await frames(12)
	# 向き依存のダイブになったため、このケースでは坂上を明示する。
	player.rotation.y = 0.0
	player.humanoid.rotation.y = 0.0
	player.sync_facing_yaw = 0.0
	if hold_uphill:
		Input.action_press("move_forward")
	player._start_dive()
	var entered_slide := false
	var saw_approach := false
	var smallest_z := player.position.z
	var returned := false
	var slide_frames := 0
	var saw_uphill_momentum := false
	var eventually_downhill := false
	var lost_dive := false
	var entry_yaw: float = player.sync_facing_yaw
	for i in 240:
		await frames(1)
		smallest_z = minf(smallest_z, player.position.z)
		saw_approach = saw_approach or player.slide_ride.approaching_reverse()
		if player.slide_ride.sliding_dive():
			entered_slide = true
			slide_frames += 1
			lost_dive = lost_dive or not player.diving
			var along := player.velocity.dot(Vector3.BACK)
			saw_uphill_momentum = saw_uphill_momentum or along < -0.1
			eventually_downhill = eventually_downhill or along >= Player.SLIDE_MIN_SPEED - 0.1
		if entered_slide and not player.slide_ride.active():
			returned = true
			Input.action_release("move_forward")
			break
	Input.action_release("move_forward")
	var label := "上入力保持" if hold_uphill else "無入力"
	check(entered_slide and not lost_dive and player.slide_ride.phase == SlideRide.Phase.NONE,
		"下側ダイブ（%s）はダイブ状態のまま滑る" % label)
	check(not saw_approach and smallest_z > -2.0,
		"下側ダイブ（%s）は徒歩モードや確定線へ進まない" % label)
	check(saw_uphill_momentum and eventually_downhill,
		"下側ダイブ（%s）は上り勢いを残して減速し、下りへ転じる" % label)
	check(absf(angle_difference(player.sync_facing_yaw, entry_yaw)) < 0.01,
		"下側ダイブ（%s）は頭を坂上へ向けたまま滑る" % label)
	var saw_recover := false
	var recovery_frames := 0
	if returned:
		for i in 40:
			await frames(1)
			recovery_frames += 1
			if player.dive_recover > 0.0:
				saw_recover = true
			if saw_recover and not player.diving:
				break
	var recovery_seconds := recovery_frames / 60.0
	check(returned and saw_recover and not player.diving,
		"下側ダイブ（%s）は出口まで状態を保ち、出た後に起き上がる" % label)
	check(returned and saw_recover and not player.diving
			and recovery_seconds <= Player.DIVE_SLIDE_RECOVER + 0.08,
		"下側ダイブ（%s）の起き上がりは通常ダイブの約1/2" % label)
	print("reverse dive ", label, ": deepest=", -smallest_z, "m kept_dive=", not lost_dive)
	player.teleport(Vector3(0, 0.1, 3))


func check_dive_at_height(distance_from_bottom: float, uphill: bool) -> void:
	# テスト滑り台は z=0..-8 / y=0..3 の一定斜面。
	var z := -distance_from_bottom
	var y := distance_from_bottom * 3.0 / 8.0 + 0.05
	player.teleport(Vector3(0, y, z))
	await frames(2)
	var entry_yaw := 0.0 if uphill else PI
	player.rotation.y = entry_yaw
	player.diving = true
	player.dive_recover = 0.0
	player.velocity = (Vector3.FORWARD if uphill else Vector3.BACK) * Player.DIVE_SPEED
	var saw_uphill_momentum := false
	var reached_downhill := false
	var kept_dive := true
	for i in 60:
		await frames(1)
		if player.slide_ride.sliding_dive():
			kept_dive = kept_dive and player.diving
			var along := player.velocity.dot(Vector3.BACK)
			saw_uphill_momentum = saw_uphill_momentum or along < -0.1
			if along >= Player.SLIDE_MIN_SPEED - 0.1:
				reached_downhill = true
				break
	var label := "上向き進入" if uphill else "下向き進入"
	check(kept_dive and player.diving and player.slide_ride.sliding_dive()
			and player.slide_ride.phase == SlideRide.Phase.NONE,
		"ダイブ（下端から%.1fm・%s）はダイブ状態のまま滑る" % [distance_from_bottom, label])
	check(not player.slide_ride.approaching_reverse() and reached_downhill,
		"ダイブ（下端から%.1fm・%s）は高さに関係なく下へ滑る" % [distance_from_bottom, label])
	check(not uphill or saw_uphill_momentum,
		"ダイブ（下端から%.1fm・%s）は進入時の上り勢いを残す" % [distance_from_bottom, label])
	check(absf(angle_difference(player.rotation.y, entry_yaw)) < 0.01,
		"ダイブ（下端から%.1fm・%s）は進入時の向きを保つ" % [distance_from_bottom, label])
	player.teleport(Vector3(0, 0.1, 3))
	player.rotation.y = 0.0


func check_downhill_dive_speed() -> void:
	var ride := SlideRide.new()
	var velocity := Vector3.BACK * Player.DIVE_SPEED
	ride.contact(501, Vector3.BACK, 0.35, 6.0, 18.0, 4.0, 4.0,
		velocity, true)
	var initial := velocity.dot(Vector3.BACK)
	for i in 30:
		velocity = ride.move(velocity, 1.0 / 60.0, Vector3.ZERO,
			Player.SLIDE_STEER, Player.SLIDE_MIN_SPEED)
	var accelerated := velocity.dot(Vector3.BACK)
	check(accelerated > initial + 2.5 and accelerated <= 18.0,
		"上側からのダイブ速度は固定せず通常の滑走上限へ近づく")


func check_dive_from_walkable_approach() -> void:
	player.teleport(Vector3(0, 0.05, 2.3))
	await frames(12)
	Input.action_press("move_forward")
	var reached_approach := false
	for i in 90:
		await frames(1)
		if player.slide_ride.approaching_reverse() and player.position.z < -0.7:
			reached_approach = true
			break
	Input.action_release("dive")
	await frames(1)
	Input.action_press("dive")
	var started_dive := false
	var entered_dive_slide := false
	for i in 30:
		await frames(1)
		started_dive = started_dive or player.diving
		if player.slide_ride.sliding_dive():
			entered_dive_slide = true
			break
	Input.action_release("dive")
	Input.action_release("move_forward")
	check(reached_approach and started_dive and entered_dive_slide and player.diving,
		"徒歩可能な斜面下端でもダイブを開始できる")
	player.teleport(Vector3(0, 0.1, 3))


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

	var cases := [["move_right", 1.0, "右側"], ["move_left", -1.0, "左側"]]
	for data in cases:
		var block: StaticBody3D = load("res://scenes/gimmicks/placed_block.tscn").instantiate()
		block.name = "SlideTestBlock" + data[2]
		block.position = Vector3(0.0, 1.5, -4.0)
		add_child(block)
		await frames(2)
		await check_block_side(block, data[0], data[1], data[2])
		check(is_instance_valid(block) and block.mesh.visible and not block.get_node("Shape").disabled,
			data[2] + "の回避中はブロック本体と当たり判定を維持")
		block.queue_free()
		await frames(2)
	await check_slide_block_expiry()


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
	await frames(1)
	check(block._slide_hit_reported, label + "の滑走接触で5秒消滅を開始")
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


func check_slide_block_expiry() -> void:
	var block: StaticBody3D = load("res://scenes/gimmicks/placed_block.tscn").instantiate()
	block.name = "SlideExpiryBlock"
	block.position = Vector3(7.0, 0.0, 5.0)
	add_child(block)
	await frames(2)
	block.report_slide_collision()
	check(block._left <= block.SLIDE_COLLISION_LIFETIME,
		"滑走接触でブロックの残り時間を5秒以内へ短縮")
	await frames(225)
	check(is_instance_valid(block) and block._material.albedo_color.a > 0.98,
		"接触から約4秒までは通常表示を維持")
	await frames(40)
	var faded: bool = is_instance_valid(block) and block._material.albedo_color.a < 0.9
	check(faded, "消滅前の1秒は通常の時間切れと同じフェードを使う")
	for i in 60:
		await frames(1)
		if not is_instance_valid(block):
			break
	check(not is_instance_valid(block), "滑走接触から5秒後にブロックが消える")


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
	cpu.apply_slide(Vector3.BACK, 6.0, 18.0, 0.35, 0.0, 8.0, 101)
	check(cpu.slide_ride.approaching_reverse(), kind + ": 下端では逆走をまだ確定しない")
	cpu.apply_slide(Vector3.BACK, 6.0, 18.0, 0.35, 2.0, 6.0, 101)
	check(cpu.slide_ride.phase == SlideRide.Phase.REVERSE_FALL, kind + ": 同じ逆走処理を使う")
	cpu.release_slide(101)
	check(not cpu.slide_ride.active() and cpu.slide_ride.phase == SlideRide.Phase.RECOVER,
		kind + ": 出口で操作拘束を解除")
	cpu.queue_free()


func observe_network() -> void:
	var seen := {}
	var matched := {}
	var matched_dive_slide := false
	var matched_block_expiry := false
	var matched_block_fade := false
	var anim: AnimationPlayer = player.get_node("Humanoid/Model").find_child("AnimationPlayer", true, false)
	var clips := ["", "SlideEnter", "SlideSit", "SlideReverseFall", "SlideProne", "SlideRecover"]
	for i in 500:
		await frames(1)
		var phase := int(player.sync_slide.x)
		seen[phase] = true
		if phase > 0 and anim.current_animation == clips[phase]:
			matched[phase] = true
		if player.diving and phase == SlideRide.Phase.NONE and anim.current_animation == "Dive":
			matched_dive_slide = true
		if is_instance_valid(network_block):
			matched_block_expiry = matched_block_expiry or network_block._left <= network_block.SLIDE_COLLISION_LIFETIME
			matched_block_fade = matched_block_fade or network_block._material.albedo_color.a < 0.9
	for phase in [1, 2, 3, 4, 5]:
		check(seen.has(phase) and matched.has(phase), "別ピアでも状態とアニメが一致: " + clips[phase])
	check(matched_dive_slide, "別ピアでもダイブ状態と向きを滑走中に維持")
	check(matched_block_expiry and matched_block_fade,
		"別ピアでも滑走接触ブロックの5秒消滅とフェードを同期")
	print("SLIDE NETWORK: ", "ALL OK" if failures == 0 else str(failures) + " FAILED")
	get_tree().quit(0 if failures == 0 else 1)

# --- 実セーブ(user://profile.json / settings.json)とクラウドセーブの保護 ---
# ラウンドを回さないテストでも、EOS にログインできる環境では起動時のクラウドセーブ同期が
# 実セーブを書き換える(2026-09-25 に boost_panel の実行中に実測)。どのテストが
# 踏むかを個別に見極めるより、全テストで一律に挟む。詳細は tests/save_guard.gd のヘッダ。
const _SaveGuard := preload("res://tests/save_guard.gd")
var _save_backup := {}


func _enter_tree() -> void:
	_save_backup = _SaveGuard.backup()


func _exit_tree() -> void:
	_SaveGuard.restore(_save_backup)
