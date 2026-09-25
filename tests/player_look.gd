extends Node3D

## C-07 T-4: apply_look_delta() の恒久回帰テスト。
## tests/player_facing.gd が「見た目の向き(humanoid)」を検証するのに対し、
## こちらは「本体yaw(rotation.y)+カメラpitch(spring_arm.rotation.x)」を検証する対象が異なる。

var failures := 0


func check(ok: bool, label: String) -> void:
	print("PASS: " if ok else "FAIL: ", label)
	if not ok:
		failures += 1


func frames(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _ready() -> void:
	var player: Player = load("res://scenes/player.tscn").instantiate()
	player.name = str(multiplayer.get_unique_id())
	add_child(player)
	await frames(3)

	# 1. ヨー回転
	player.rotation.y = 0.0
	player.spring_arm.rotation.x = 0.0
	player.apply_look_delta(Vector2(10, 0), 0.003)
	check(is_equal_approx(player.rotation.y, -0.03), "ドラッグでヨー回転する")
	check(is_equal_approx(player.spring_arm.rotation.x, 0.0), "ヨーのみ変更、ピッチは不変")

	# 2. ピッチ回転
	player.rotation.y = 0.0
	player.spring_arm.rotation.x = 0.0
	player.apply_look_delta(Vector2(0, 10), 0.003)
	check(is_equal_approx(player.spring_arm.rotation.x, -0.03), "ドラッグでピッチ回転する")
	check(is_equal_approx(player.rotation.y, 0.0), "ピッチのみ変更、ヨーは不変")

	# 3. ピッチのクランプ(上限/下限)
	player.spring_arm.rotation.x = 0.0
	player.apply_look_delta(Vector2(0, -100000), 1.0)
	check(is_equal_approx(player.spring_arm.rotation.x, deg_to_rad(30.0)), "ピッチ上限(PITCH_MAX)でクランプ")
	player.apply_look_delta(Vector2(0, -100000), 1.0)
	check(is_equal_approx(player.spring_arm.rotation.x, deg_to_rad(30.0)), "上限到達後もさらに超えない")
	player.apply_look_delta(Vector2(0, 100000), 1.0)
	check(is_equal_approx(player.spring_arm.rotation.x, deg_to_rad(-60.0)), "ピッチ下限(PITCH_MIN)でクランプ")
	player.apply_look_delta(Vector2(0, 100000), 1.0)
	check(is_equal_approx(player.spring_arm.rotation.x, deg_to_rad(-60.0)), "下限到達後もさらに超えない")

	# 4. sensitivity省略時はSettingsManager.mouse_sensitivityを使う
	var saved_sensitivity := SettingsManager.mouse_sensitivity
	SettingsManager.mouse_sensitivity = 0.01
	player.rotation.y = 0.0
	player.apply_look_delta(Vector2(10, 0))
	check(is_equal_approx(player.rotation.y, -0.1), "sensitivity省略時はSettingsManager.mouse_sensitivityを使う")
	SettingsManager.mouse_sensitivity = saved_sensitivity

	# 5. is_multiplayer_authority()ガード(権威を持たないプレイヤーでは無反応)
	var other: Player = load("res://scenes/player.tscn").instantiate()
	other.name = str(multiplayer.get_unique_id() + 1)
	add_child(other)
	await frames(3)
	other.rotation.y = 0.0
	other.spring_arm.rotation.x = 0.0
	other.apply_look_delta(Vector2(10, 10), 0.003)
	check(is_equal_approx(other.rotation.y, 0.0) and is_equal_approx(other.spring_arm.rotation.x, 0.0),
		"権威を持たないPlayerではapply_look_delta()が無反応")
	other.queue_free()

	# 注: _unhandled_input()経由(Input.mouse_mode==MOUSE_MODE_CAPTURED時にapply_look_delta()を
	# 呼ぶ分岐)のheadless自動テストは、DisplayServerの実体が無いheadless環境では
	# Input.mouse_mode がMOUSE_MODE_CAPTUREDへ実際には遷移しない(確認済み、既知の制約)ため
	# 断念した。この分岐条件自体はapply_look_delta()抽出前から存在する既存コードで
	# 変更していない(1行を関数呼び出しに置き換えただけ)ため、windowed実機確認でカバーする。

	print("PLAYER LOOK TEST: ", "ALL OK" if failures == 0 else str(failures) + " FAILED")
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
