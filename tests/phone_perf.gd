extends Node

## スマホ(Web版をスマホのブラウザで開いたとき)だけの軽量化(scenes/hud/phone_perf.gd)の検証。
##
##   pwsh tools/run_headless_test.ps1 res://tests/phone_perf.tscn
##
## 見るところは4つ:
##   1. 3D の描画倍率が画面の短い辺から正しく決まること(下限・上限を含む)
##   2. **PC では何も変わらないこと**。フレームレート・グロー・3D の解像度・ダッシュパネル・
##      ロビーのプレビューのどれも、今までと同じ状態のまま残る
##   3. スマホ扱い(force_for_test)では、30fps・グロー無し・解像度の縮小が入り、
##      world.tscn の Environment リソースそのものは書き換わらないこと
##   4. スマホ扱いのダッシュパネルは画面外で虹の波を止め、ロビーのプレビューは
##      1枚描いたあとにアニメを止め、見た目を変えるときに動かし直すこと

const BOOST := preload("res://scenes/gimmicks/boost_panel.tscn")
const PREVIEW := preload("res://scenes/costume_preview.tscn")

var _fail := 0


func _ready() -> void:
	print("=== スマホ向け軽量化(PhonePerf)の検証 ===")
	_check_scale()
	_check_pc_untouched()
	_check_phone_applied()
	_check_boost_panel()
	await _check_preview()
	PhonePerf.force_for_test = false
	print("=== %s ===" % ("すべての検証に合格しました" if _fail == 0
		else "%d 件の検証に失敗しました" % _fail))
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(label: String, cond: bool, extra := "") -> void:
	if not cond:
		_fail += 1
	print("  %s: %s%s" % [label, "OK" if cond else "FAIL",
		"" if extra.is_empty() else "  (%s)" % extra])


## --- 1. 描画倍率 --------------------------------------------------------

func _check_scale() -> void:
	var cases := {1290: 720.0 / 1290.0, 1080: 720.0 / 1080.0, 720: 1.0, 600: 1.0,
		2000: 0.5, 0: 1.0}
	for h: int in cases:
		var got := PhonePerf.scale_3d_for(h)
		_ok("短い辺 %dpx -> 倍率 %.3f" % [h, cases[h]], is_equal_approx(got, cases[h]),
			"%.3f" % got)


## --- 2. PC では何も変わらない --------------------------------------------

func _make_env() -> WorldEnvironment:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.glow_enabled = true
	we.environment = env
	return we


func _check_pc_untouched() -> void:
	PhonePerf.force_for_test = false
	_ok("PC(headless)はスマホ扱いにならない", not PhonePerf.enabled())
	var fps := Engine.max_fps
	PhonePerf.apply_global()
	_ok("PC: フレームレートの上限はそのまま", Engine.max_fps == fps, "%d" % Engine.max_fps)
	var we := _make_env()
	var env := we.environment
	var vp := get_viewport()
	var scale := vp.scaling_3d_scale
	var applied := PhonePerf.apply_world(we, vp)
	_ok("PC: apply_world は何もしない", not applied)
	_ok("PC: Environment は差し替わらない", we.environment == env)
	_ok("PC: グローはそのまま", we.environment.glow_enabled)
	_ok("PC: 3D の解像度はそのまま", is_equal_approx(vp.scaling_3d_scale, scale),
		"%.3f" % vp.scaling_3d_scale)
	we.free()


## --- 3. スマホ扱いでは軽くなる ------------------------------------------

func _check_phone_applied() -> void:
	PhonePerf.force_for_test = true
	var fps := Engine.max_fps
	PhonePerf.apply_global()
	_ok("スマホ: 30fps に抑える", Engine.max_fps == PhonePerf.FPS_CAP, "%d" % Engine.max_fps)
	Engine.max_fps = fps

	var we := _make_env()
	var original := we.environment
	var vp := get_viewport()
	var mode := vp.scaling_3d_mode
	var scale := vp.scaling_3d_scale
	var applied := PhonePerf.apply_world(we, vp)
	_ok("スマホ: apply_world が適用される", applied)
	_ok("スマホ: グローを切る", not we.environment.glow_enabled)
	_ok("スマホ: Environment は複製に差し替わる", we.environment != original)
	_ok("スマホ: 元の Environment リソースは書き換えない", original.glow_enabled)
	var win := vp as Window
	var expect := PhonePerf.scale_3d_for(mini(win.size.x, win.size.y))
	_ok("スマホ: 3D の解像度を画面の短い辺に合わせる",
		is_equal_approx(vp.scaling_3d_scale, expect),
		"%.3f (窓 %s)" % [vp.scaling_3d_scale, win.size])
	_ok("スマホ: 拡大方法は bilinear",
		vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR)
	# 後始末(同じプロセスで後に続く検証へ持ち越さない)
	vp.scaling_3d_mode = mode
	vp.scaling_3d_scale = scale
	RenderingServer.directional_shadow_atlas_set_size(ProjectSettings.get_setting(
		"rendering/lights_and_shadows/directional_shadow/size", 4096), true)
	RenderingServer.directional_soft_shadow_filter_set_quality(ProjectSettings.get_setting(
		"rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality", 2))
	we.free()


## --- 4. ダッシュパネルとロビーのプレビュー --------------------------------

func _first_wave(panel: Node) -> BaseMaterial3D:
	var wave := panel.get_node("Mesh/DashPadModel/DashPad/Wave0") as MeshInstance3D
	return wave.get_surface_override_material(0) as BaseMaterial3D


func _check_boost_panel() -> void:
	# PC: 画面判定の部品は付かず、毎フレーム波を書き換える(今までどおり)
	PhonePerf.force_for_test = false
	var pc: Area3D = BOOST.instantiate()
	add_child(pc)
	_ok("PC: ダッシュパネルに画面判定は付かない", pc._on_screen == null)
	var mat := _first_wave(pc)
	mat.emission_energy_multiplier = -1.0
	pc._process(0.016)
	_ok("PC: ダッシュパネルの波は毎フレーム動く", mat.emission_energy_multiplier >= 0.0,
		"%.2f" % mat.emission_energy_multiplier)
	pc.free()

	# スマホ: headless ではカメラが無く常に画面外なので、波を止めているはず
	PhonePerf.force_for_test = true
	var phone: Area3D = BOOST.instantiate()
	add_child(phone)
	_ok("スマホ: ダッシュパネルに画面判定が付く", phone._on_screen != null)
	mat = _first_wave(phone)
	mat.emission_energy_multiplier = -1.0
	phone._process(0.016)
	_ok("スマホ: 画面外では波を書き換えない", is_equal_approx(mat.emission_energy_multiplier, -1.0),
		"%.2f" % mat.emission_energy_multiplier)
	phone.free()
	PhonePerf.force_for_test = false


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _check_preview() -> void:
	for phone in [false, true]:
		PhonePerf.force_for_test = phone
		var label := "スマホ" if phone else "PC"
		var p: Control = PREVIEW.instantiate()
		add_child(p)
		var humanoid: Node = p.get_node("SubViewportContainer/SubViewport/Turntable/Humanoid")
		p.set_interactive(false)
		p.request_static_render()
		await _frames(4)
		if phone:
			_ok("スマホ: 静止画のあとはプレビューのアニメを止める",
				humanoid.process_mode == Node.PROCESS_MODE_DISABLED)
			p.show_hat(HatCatalog.DEFAULT_ID)
			_ok("スマホ: 見た目を変えるときはアニメを動かし直す",
				humanoid.process_mode == Node.PROCESS_MODE_INHERIT)
		else:
			_ok("PC: プレビューのアニメは止めない",
				humanoid.process_mode == Node.PROCESS_MODE_INHERIT)
		p.queue_free()
		await _frames(1)
	PhonePerf.force_for_test = false

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
