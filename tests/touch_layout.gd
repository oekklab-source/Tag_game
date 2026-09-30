extends Node

## スマホのタッチ操作: 実寸(dp)での配置・複数の指での同時操作・ダッシュの切り替えの回帰テスト。
## (2026-09-30、Android Chrome の実機で「ボタンが小さい」「ダッシュしながら視点を回せない」
##  「ボタンを同時に押せない」と指摘を受けて作り直した部分)
##
## 実行方法:
##   pwsh tools/run_headless_test.ps1 res://tests/touch_layout.tscn
##
## 見た目(色・文字の収まり)は headless では見られないので、tests/uishot.tscn(windowed)で見る。
## ここでは数値で押さえられること——ボタンが画面に収まる・当たり判定が重ならない・
## 左手のスティック範囲と右手のボタンが干渉しない・複数の指がそれぞれ別の操作になる——だけを見る。

var passed_count := 0
var failed_count := 0


class FakePlayer extends Node:
	var exhausted := false


func _assert(condition: bool, msg: String) -> void:
	if condition:
		print("  [OK] %s" % msg)
		passed_count += 1
	else:
		printerr("  [FAIL] %s" % msg)
		failed_count += 1


func _ready() -> void:
	print("==================================================")
	print("【TEST】スマホのタッチ操作: 実寸配置・複数の指・ダッシュ切り替え")
	print("==================================================")
	await get_tree().process_frame

	_test_units_per_dp()
	_test_inset_offsets()

	var prev_mode: String = SettingsManager.touch_controls_mode
	var prev_state: int = GameManager.state
	SettingsManager.touch_controls_mode = "on"
	GameManager.state = GameManager.State.PLAYING
	var touch: CanvasLayer = load("res://scenes/hud/touch_controls.tscn").instantiate()
	get_tree().root.add_child(touch)
	await get_tree().process_frame

	_test_layouts(touch)
	await _test_multi_touch(touch)
	await _test_dash_toggle(touch)

	touch.queue_free()
	SettingsManager.touch_controls_mode = prev_mode
	GameManager.state = prev_state
	await get_tree().process_frame

	print("==================================================")
	print("touch_layout 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> touch_layout: ALL PASSED")
	else:
		printerr("=> touch_layout: SOME TESTS FAILED")
	get_tree().quit(1 if failed_count > 0 else 0)


func _test_units_per_dp() -> void:
	# iPhone 横持ち: 844x390dp、devicePixelRatio 3 → 物理 2532x1170。canvas は高さ 1080 基準で横に伸びる
	var vis := Vector2(1080.0 * 844.0 / 390.0, 1080.0)
	var u := WebScreen.units_per_dp(3.0, vis, Vector2i(2532, 1170))
	_assert(absf(u - 1080.0 / 390.0) < 0.01, "iPhone 横持ち: 1dp = %.3f 単位(期待 %.3f)" % [u, 1080.0 / 390.0])
	# PC(タッチを「オン」にした場合): 1600x900、倍率1 → 1dp = 1920/1600 単位
	u = WebScreen.units_per_dp(1.0, Vector2(1920, 1080), Vector2i(1600, 900))
	_assert(absf(u - 1.2) < 0.001, "PC 1600x900: 1dp = 1.2 単位")
	# 背の低い画面(高さ 280dp)は、高さ 340dp に収まるよう縮める
	u = WebScreen.units_per_dp(1.0, Vector2(1080.0 * 600.0 / 280.0, 1080.0), Vector2i(600, 280))
	_assert(absf(u - 1080.0 / 340.0) < 0.001, "高さ 280dp の画面は 340dp 相当まで縮める")
	# 文字サイズ設定(L-10)の content_scale_factor=1.5 で visible が 1/1.5 になっても、実寸は変わらない
	var u1 := WebScreen.units_per_dp(1.0, Vector2(1920, 1080), Vector2i(1920, 1080))
	var u15 := WebScreen.units_per_dp(1.0, Vector2(1280, 720), Vector2i(1920, 1080))
	_assert(absf(u1 * 1.0 - 1.0) < 0.001 and absf(u15 * 1.5 - 1.0) < 0.001,
		"文字サイズを大きくしてもボタンの物理ピクセルは同じ")
	_assert(WebScreen.units_per_dp(1.0, Vector2(1920, 1080), Vector2i(0, 0)) == 1.0,
		"ウィンドウ寸法が 0 でも落ちない")


func _test_inset_offsets() -> void:
	var ins := {"left": 50.0, "top": 0.0, "right": 30.0, "bottom": 20.0}
	# 左上に付いた要素は左の余白だけ右へ
	var o := WebScreen.inset_offsets(Rect2(0, 0, 0, 0), Rect2(16, 16, 80, 80), ins)
	_assert(o == Rect2(66, 16, 130, 80), "左上アンカー: 左の余白の分だけ右へ")
	# 右下に付いた要素は右と下の余白の分だけ内側へ
	o = WebScreen.inset_offsets(Rect2(1, 1, 1, 1), Rect2(-100, -50, -10, -5), ins)
	_assert(o == Rect2(-130, -70, -40, -25), "右下アンカー: 右と下の余白の分だけ内側へ")
	# 全面の要素は両側から縮む
	o = WebScreen.inset_offsets(Rect2(0, 0, 1, 1), Rect2(0, 0, 0, 0), ins)
	_assert(o == Rect2(50, 0, -30, -20), "全面アンカー: 四辺とも余白の分だけ縮む")
	# 横中央は左右の余白の平均だけずれる
	o = WebScreen.inset_offsets(Rect2(0.5, 1, 0.5, 1), Rect2(-90, -50, 90, -10), ins)
	_assert(o == Rect2(-80, -70, 100, -30), "中央アンカー: 左右の余白の差の半分だけずれる")
	_assert(WebScreen.safe_area_insets_dp()["left"] == 0.0, "Web 以外では safe area は 0")
	_assert(not WebScreen.is_standalone() and not WebScreen.fullscreen_enabled(),
		"Web 以外ではホーム画面起動・全画面とも false")


## 実在する画面(dp)で並べ、はみ出し・重なり・左右の干渉が無いことを見る
func _test_layouts(touch: CanvasLayer) -> void:
	var screens := [
		["iPhone 横持ち(ノッチあり)", Vector2(844, 390), 3.0, {"left": 47.0, "top": 0.0, "right": 47.0, "bottom": 21.0}],
		["Android 横持ち", Vector2(915, 412), 2.625, {}],
		["小さめの Android", Vector2(640, 360), 2.0, {}],
		["背の低い画面", Vector2(600, 280), 2.0, {}],
		["iPad 横持ち", Vector2(1180, 820), 2.0, {}],
		["PC 1600x900", Vector2(1600, 900), 1.0, {}],
	]
	for sc in screens:
		var label: String = sc[0]
		var dp: Vector2 = sc[1]
		var dpr: float = sc[2]
		var insets: Dictionary = sc[3]
		var vis := Vector2(1080.0 * dp.x / dp.y, 1080.0)
		var win := Vector2i(int(dp.x * dpr), int(dp.y * dpr))
		var u := WebScreen.units_per_dp(dpr, vis, win)
		var ins := insets if not insets.is_empty() else {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
		touch._apply_layout(vis, u, ins)
		# 背の低い画面では units_per_dp() が全体を縮めるので、実寸の判定は縮める前の値で行う
		var real_u := dpr * vis.x / float(win.x)
		_check_layout(touch, label, vis, u, real_u, ins)


func _check_layout(touch: CanvasLayer, label: String, vis: Vector2, u: float, real_u: float,
		ins: Dictionary) -> void:
	var screen := Rect2(Vector2.ZERO, vis)
	var safe := Rect2(ins["left"] * u, ins["top"] * u,
		vis.x - (ins["left"] + ins["right"]) * u, vis.y - (ins["top"] + ins["bottom"]) * u)
	var buttons: Array = [touch.dive_button, touch.dash_button, touch.item_button, touch.emote_button]
	var ok_inside := true
	var ok_size := true
	for b in buttons:
		# 見た目がノッチを避けた範囲に収まる
		if not safe.encloses(b.get_global_rect()):
			ok_inside = false
		# 実寸で 44dp 以上(iOS の最小推奨。背の低い画面で縮めた場合も含めて)
		if b.size.x / real_u < 44.0 - 0.01:
			ok_size = false
	_assert(ok_inside, "%s: 4つのボタンがノッチを避けた範囲に収まる" % label)
	_assert(ok_size, "%s: 4つのボタンがすべて実寸 44dp 以上" % label)
	if is_equal_approx(u, real_u):
		_assert(absf(touch.dive_button.size.x / real_u - touch.LAYOUT_BTN_MAIN) < 0.01,
			"%s: ダイブは実寸 %d dp" % [label, int(touch.LAYOUT_BTN_MAIN)])

	# 当たり判定(円)同士が重ならない = 2本の指で別々のボタンを押しても隣を誤爆しない
	var no_overlap := true
	for i in buttons.size():
		for j in range(i + 1, buttons.size()):
			var a: Panel = buttons[i]
			var b: Panel = buttons[j]
			if a.hit_center().distance_to(b.hit_center()) <= a.hit_radius() + b.hit_radius():
				no_overlap = false
				printerr("    重なり: %s と %s" % [a.name, b.name])
	_assert(no_overlap, "%s: ボタンの当たり判定同士が重ならない" % label)

	# 左手のスティック範囲と右手のボタンが干渉しない
	var zone: Rect2 = touch.joystick.capture_rect
	var apart := true
	for b in buttons:
		var c: Vector2 = b.hit_center()
		var nearest := Vector2(clampf(c.x, zone.position.x, zone.end.x), clampf(c.y, zone.position.y, zone.end.y))
		if nearest.distance_to(c) <= b.hit_radius():
			apart = false
	_assert(apart, "%s: スティックの範囲にボタンの当たり判定が入り込まない" % label)
	_assert(screen.encloses(touch.joystick.get_global_rect()), "%s: スティックが画面に収まる" % label)

	# カモン長押しの挑発3種が画面に収まる
	var submenu: Control = touch.emote_button.get_node("TauntSubmenu")
	var sub_rect := Rect2(touch.emote_button.position + submenu.position, submenu.size)
	_assert(screen.encloses(sub_rect), "%s: 挑発メニューが画面に収まる" % label)
	var ic: Vector2 = touch.item_button.hit_center()
	var nearest_sub := Vector2(clampf(ic.x, sub_rect.position.x, sub_rect.end.x),
		clampf(ic.y, sub_rect.position.y, sub_rect.end.y))
	_assert(nearest_sub.distance_to(ic) > touch.item_button.size.x * 0.5,
		"%s: 挑発メニューがアイテムボタンに重ならない" % label)

	# 上端のボタンがノッチを避ける
	_assert(safe.encloses(touch.pause_button.get_global_rect()), "%s: ≡ がノッチを避けた範囲に収まる" % label)


func _touch(index: int, pos: Vector2, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.position = pos
	ev.pressed = pressed
	get_viewport().push_input(ev, true)


func _drag(index: int, pos: Vector2, rel: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = pos
	ev.relative = rel
	get_viewport().push_input(ev, true)


## 4本の指を同時に置いて、それぞれが別の操作になることを見る
## (以前の「右親指1本でダッシュを押しっぱなし」だと、視点とダッシュが両立しなかった)
func _test_multi_touch(touch: CanvasLayer) -> void:
	var vis := get_viewport().get_visible_rect().size
	touch._apply_layout(vis, vis.y / 390.0, {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0})
	await get_tree().process_frame
	var look: Control = touch.get_node("TouchLookZone")

	# 指0: 左手。スティックの見た目の円から外れた位置でも、範囲内なら掴んでそこが中心になる
	var stick_p := Vector2(vis.x * 0.3, vis.y * 0.5)
	_touch(0, stick_p, true)
	_assert(touch.joystick.is_held(), "左手: スティックの円の外(範囲内)に置いても掴む")
	_assert(touch.joystick.get_global_rect().get_center().distance_to(stick_p) < 1.0,
		"左手: 置いた位置がスティックの中心になる")
	_drag(0, stick_p + Vector2(0, -200), Vector2(0, -200))
	await get_tree().process_frame
	_assert(Input.is_action_pressed("move_forward"), "左手: 上へ倒すと前進")

	# 指1: 右手でダッシュを1回タップ → ON のまま離せる
	_touch(1, touch.dash_button.hit_center(), true)
	_touch(1, touch.dash_button.hit_center(), false)
	_assert(touch.dash_button.is_toggled() and Input.is_action_pressed("dash"),
		"ダッシュは1回タップで ON のまま(指を離しても続く)")

	# 指2: 右手の別の指でダイブを押している間、指3で視点を回せる
	_touch(2, touch.dive_button.hit_center(), true)
	_assert(Input.is_action_pressed("dive"), "ダイブを押せる(ダッシュ ON・移動中でも)")
	var look_p := Vector2(vis.x * 0.7, vis.y * 0.3)
	_touch(3, look_p, true)
	_assert(look._active_finger == 3, "もう1本の指は視点ドラッグになる(ボタンにもスティックにも取られない)")
	_assert(touch.joystick.is_held() and touch.dash_button.is_toggled(),
		"4本目を置いてもスティックとダッシュはそのまま")

	# ボタンの当たり判定の隙間(ダイブとダッシュの間)は視点ドラッグ側へ行き、ボタンを誤爆しない
	_touch(3, look_p, false)
	_touch(2, touch.dive_button.hit_center(), false)
	_assert(not Input.is_action_pressed("dive"), "ダイブの指を離すと解除")

	# 指0 を離す → スティックは元の位置へ戻り、ダッシュも自動で OFF
	_touch(0, stick_p, false)
	await get_tree().process_frame
	_assert(not touch.joystick.is_held() and not Input.is_action_pressed("move_forward"),
		"左手を離すと移動が止まる")
	_assert(touch.joystick.position.distance_to(touch.joystick.rest_position) < 0.5,
		"スティックは元の位置へ戻る")
	_assert(not touch.dash_button.is_toggled() and not Input.is_action_pressed("dash"),
		"スティックから指を離すとダッシュも OFF")


func _test_dash_toggle(touch: CanvasLayer) -> void:
	var fake := FakePlayer.new()
	add_child(fake)
	touch._local_player = fake
	var c: Vector2 = touch.dash_button.hit_center()

	_touch(5, c, true)
	_touch(5, c, false)
	_assert(touch.dash_button.is_toggled(), "ダッシュ: 1回目のタップで ON")
	_touch(5, c, true)
	_touch(5, c, false)
	_assert(not touch.dash_button.is_toggled() and not Input.is_action_pressed("dash"),
		"ダッシュ: 2回目のタップで OFF")

	_touch(5, c, true)
	_touch(5, c, false)
	fake.exhausted = true
	await get_tree().process_frame
	await get_tree().process_frame
	_assert(not touch.dash_button.is_toggled() and not Input.is_action_pressed("dash"),
		"ダッシュ: スタミナが切れたら自動で OFF")
	fake.exhausted = false

	_touch(5, c, true)
	_touch(5, c, false)
	QuitMenu.open()
	await get_tree().process_frame
	await get_tree().process_frame
	_assert(not touch.dash_button.is_toggled() and not Input.is_action_pressed("dash"),
		"ダッシュ: ポーズを開いたら OFF(裏で走り続けない)")
	QuitMenu.close()
	await get_tree().process_frame

	touch._local_player = null
	fake.queue_free()

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
