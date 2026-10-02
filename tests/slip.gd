extends Node3D

## バナナで転ぶ Slip アニメ（顔面ダイブ）の検証。
##
##   # 数値検証（ヘッドレス可）
##   godot --headless --path . res://tests/slip.tscn
##   # 見た目の確認（--headless 不可）
##   godot --path . res://tests/slip.tscn -- --shots tests/shots/slip
##
## 見ているのは4つ:
##   1. クリップ長が banana.gd の STUN と一致するか（ずれるとスタン明けに固まる）
##   2. 床にめり込んでいないか（Root を倒す支点は足元なので、up() の持ち上げが
##      足りないと体が床に沈む。目分量では見えない数センチが影で必ず分かる）。
##      ここで見られるのはボーンの原点までで、**皮膚の最下点は Blender 側で測る**
##      （キーごとにポーズを付けたメッシュの min Z を出す。顔面着地の1〜2フレームだけ
##      -0.013m ＝ 潰れて床に触っている状態が正しい）
##   3. 最終フレームが Idle の 0 フレーム目と一致するか（スタン明けのブレンド）
##   4. 頭の位置（humanoid.gd の星の輪がここに乗る）

const HUMANOID := preload("res://scenes/humanoid.gd")
const STUN := preload("res://scenes/gimmicks/banana.gd").STUN
const FRAMES := 45.0  # Blender 側のキー数（30fps）
## うつ伏せの間、体の中心線がこの高さより下がると腹が床に沈む（体半径 0.40）
const PRONE_MIN_Y := 0.26
const SHOT_FRAMES := [0, 3, 6, 9, 12, 15, 22, 28, 33, 38, 45]

var _rig: Node3D
var _skel: Skeleton3D
var _anim: AnimationPlayer
var _chest := -1


func _ready() -> void:
	_rig = load("res://scenes/humanoid.tscn").instantiate()
	add_child(_rig)
	_anim = _rig.find_child("AnimationPlayer", true, false)
	_skel = _rig.find_child("Skeleton3D", true, false)
	if _anim == null or _skel == null:
		print("FAIL: AnimationPlayer / Skeleton3D が見つからない")
		get_tree().quit()
		return
	_chest = _skel.find_bone("Chest")

	var slip := _anim.get_animation("Slip")
	if slip == null:
		print("FAIL: Slip クリップが無い")
		get_tree().quit()
		return
	var want := FRAMES / 30.0
	print("Slip 長さ %.3fs（Blender %d フレーム）  banana.gd STUN %.2fs  %s"
		% [slip.length, int(FRAMES), STUN,
			"OK" if absf(slip.length - want) < 0.02 and absf(STUN - want) < 0.02
			else "<-- ずれている"])
	print("Slip ループ %s（ワンショットであること）" % [slip.loop_mode])

	_anim.play("Slip")
	_anim.speed_scale = 0.0
	_measure(slip.length)
	_check_tail(slip.length)

	var out := ""
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--shots" and i + 1 < args.size():
			out = args[i + 1]
	if out != "":
		await _shots(slip.length, out)
	get_tree().quit()


## 1フレームずつ送って、床へのめり込みと頭の軌跡を実測する
func _measure(dur: float) -> void:
	print("\n--- コマ送り（f / 最下点 / 腰 / 頭）---")
	var lowest := INF
	var lowest_at := -1
	var prone_min := INF
	for f in int(FRAMES) + 1:
		_seek(dur * float(f) / FRAMES)
		var low := INF
		for b in _skel.get_bone_count():
			low = minf(low, _skel.get_bone_global_pose(b).origin.y)
		if low < lowest:
			lowest = low
			lowest_at = f
		var hips := _skel.get_bone_global_pose(_skel.find_bone("Hips")).origin
		var head := _head()
		# うつ伏せている間（着地〜起き上がりにかかるまで）だけ腹の高さを見る
		if f >= 12 and f <= 33:
			prone_min = minf(prone_min, minf(hips.y, head.y))
		if f % 3 == 0:
			print("  f%-3d 最下 %+.3f   腰 (%+.2f, %+.2f)   頭 (%+.2f, %+.2f)"
				% [f, low, hips.z, hips.y, head.z, head.y])
	print("  最下点 %+.3fm（f%d）  %s"
		% [lowest, lowest_at, "OK" if lowest > -0.02 else "<-- ボーンが床下に出ている"])
	print("  うつ伏せ中の体の高さ 最小 %+.3fm  %s"
		% [prone_min, "OK" if prone_min >= PRONE_MIN_Y else "<-- 腹が床に沈んでいる"])


## 最終フレームが Idle の 0 フレーム目と同じポーズか。
## ここがずれると、スタンが明けた瞬間に姿勢がガクッと飛ぶ
func _check_tail(dur: float) -> void:
	_seek(dur)
	var slip_pose: Array[Vector3] = []
	for b in _skel.get_bone_count():
		slip_pose.append(_skel.get_bone_global_pose(b).origin)
	_anim.play("Idle")
	_anim.speed_scale = 0.0
	_seek(0.0)
	var diff := 0.0
	for b in _skel.get_bone_count():
		diff = maxf(diff, slip_pose[b].distance_to(_skel.get_bone_global_pose(b).origin))
	print("\nSlip 最終 vs Idle 0f のボーン差 最大 %.4fm  %s"
		% [diff, "OK" if diff < 0.01 else "<-- スタン明けに姿勢が飛ぶ"])
	_anim.play("Slip")
	_anim.speed_scale = 0.0


## 星の輪を置く頭の位置。humanoid.gd と同じ求め方にしておくこと
func _head() -> Vector3:
	var pose := _skel.get_bone_global_pose(_chest)
	return _skel.global_transform * (pose * (Vector3.UP * HUMANOID.HEAD_FROM_CHEST))


func _seek(time: float) -> void:
	_anim.seek(time, true)
	_skel.force_update_all_bone_transforms()


## 見た目の確認用。横アングルで数フレームを PNG に落とす
func _shots(dur: float, out: String) -> void:
	DirAccess.make_dir_recursive_absolute(out)
	# 頭上の星も一緒に写す（stunned でしか出ない）
	_rig.set_stunned(true)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20.0, 20.0)
	floor_mesh.mesh = plane
	add_child(floor_mesh)
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.9, -0.6, 0.0)
	add_child(light)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.65, 0.78)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.62, 0.68)
	env.environment.ambient_light_energy = 0.6
	add_child(env)
	var cam := Camera3D.new()
	add_child(cam)
	# 顔面ダイブは頭が前方 1.6m まで出るので、その中間を横から狙う
	cam.global_position = Vector3(2.5, 0.85, -0.8)
	cam.look_at(Vector3(0.0, 0.45, -0.85), Vector3.UP)
	cam.current = true

	for f in SHOT_FRAMES:
		_seek(dur * float(f) / FRAMES)
		for i in 3:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var path := "%s/slip_%02d.png" % [out, f]
		get_viewport().get_texture().get_image().save_png(path)
		print("saved ", path)

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
