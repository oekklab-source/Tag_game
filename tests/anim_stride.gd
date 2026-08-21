extends Node3D

## Run アニメ1周期でキャラが「実際に歩く距離」を実測する。
##
##   godot --headless --path . res://tests/anim_stride.tscn --quit-after 600
##
## 足のすべりを消すには、アニメの再生速度を
##   speed_scale = 移動速度 / (1周期の歩行距離 / 1周期の秒数)
## にする必要がある。その分母（humanoid.gd の RUN_SPEED）をここで求める。
##
## ボーンのローカル軸は Blender と glTF で向きが変わるので、
## ポーズの角度から手計算すると間違える。実際にポーズを適用して
## 接地している足の動きを測る。

const SAMPLES := 96
const HUMANOID := preload("res://scenes/humanoid.gd")


func _ready() -> void:
	var rig: Node3D = load("res://scenes/humanoid.tscn").instantiate()
	add_child(rig)
	var anim: AnimationPlayer = rig.find_child("AnimationPlayer", true, false)
	var skel: Skeleton3D = rig.find_child("Skeleton3D", true, false)
	if anim == null or skel == null:
		print("FAIL: AnimationPlayer / Skeleton3D が見つからない")
		get_tree().quit()
		return

	for clip in ["Run", "Idle", "Jump", "Dive"]:
		var a := anim.get_animation(clip)
		print("%-5s length %.3fs  tracks %d" % [clip, a.length if a else -1.0,
			a.get_track_count() if a else 0])

	var feet := [skel.find_bone("Foot.L"), skel.find_bone("Foot.R")]
	if feet[0] < 0 or feet[1] < 0:
		print("FAIL: Foot ボーンが見つからない（%s）" % [feet])
		get_tree().quit()
		return

	var run := anim.get_animation("Run")
	var dur := run.length
	anim.play("Run")
	anim.speed_scale = 0.0

	# 接地している方の足（低い方）が地面に対して止まっている＝
	# その足が胴体に対して後ろへ動いた分だけ、胴体は前へ進むべき
	var travel := 0.0
	# 足ごとに前回の z を持つ。接地足が入れ替わる瞬間も、
	# 新しい接地足の「その足自身の前回位置」との差なので途切れずに数えられる
	var prev_z := [0.0, 0.0]
	var lowest := INF
	var highest := -INF
	for i in SAMPLES + 1:
		anim.seek(dur * float(i) / float(SAMPLES), true)
		skel.force_update_all_bone_transforms()
		var pos := [skel.get_bone_global_pose(feet[0]).origin,
			skel.get_bone_global_pose(feet[1]).origin]
		var planted: int = 0 if pos[0].y < pos[1].y else 1
		lowest = minf(lowest, minf(pos[0].y, pos[1].y))
		highest = maxf(highest, maxf(pos[0].y, pos[1].y))
		if i > 0:
			# 接地足が前(-Z)から後ろ(+Z)へ流れた分だけ胴体は前進する
			travel += maxf(pos[planted].z - prev_z[planted], 0.0)
		prev_z[0] = pos[0].z
		prev_z[1] = pos[1].z

	var natural: float = travel / dur if dur > 0.0 else 0.0
	print("\n--- Run 1周期 ---")
	print("  周期 %.3fs  接地足の後退量 %.3fm  足の高さ %.3f〜%.3fm"
		% [dur, travel, lowest, highest])
	print("  歩行が等倍で成立する速度 = %.2f m/s" % natural)
	print("  現在の humanoid.NATURAL_SPEED = %.2f m/s%s"
		% [HUMANOID.NATURAL_SPEED,
			"" if absf(HUMANOID.NATURAL_SPEED - natural) < 0.08
			else "   <-- 実測とずれている（足がすべる）"])
	for label in ["歩き", "ダッシュ"]:
		var v: float = Player.BASE_SPEED * (Player.DASH_MULT if label == "ダッシュ" else 1.0)
		var want: float = v / natural if natural > 0.0 else -1.0
		var got := clampf(want, HUMANOID.SCALE_MIN, HUMANOID.SCALE_MAX)
		print("  %-6s %.1f m/s: 必要な倍率 %.2f / 実際 %.2f -> 歩数 %.1f歩/秒  足すべり %.0f%%"
			% [label, v, want, got, got / dur * 2.0,
				(want / got - 1.0) * 100.0 if got > 0.0 else 0.0])
	get_tree().quit()
