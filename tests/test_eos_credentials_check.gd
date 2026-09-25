extends Node

## autoload/eos_credentials_check.gd（eos_credentials.cfg の検証ロジック）のテスト。
## 実行時の EosManager と書き出しガード（addons/tag_game_export_guard/）が共有する判定なので、
## 「どこまで埋まっていれば起動してよいか / 出荷してよいか」の境界をここで固定する（Phase 3 L-08）。
##
## 実ファイル res://eos_credentials.cfg には一切触れない。検査対象は user:// に書く
## 使い捨ての cfg で、テストの最後に必ず消す（実セーブ profile.json / settings.json とも無関係）。
##
## 実行: pwsh tools/run_headless_test.ps1 res://tests/test_eos_credentials_check.tscn

const _Check := preload("res://autoload/eos_credentials_check.gd")
const TMP_PATH := "user://_tmp_creds_check.cfg"
const VALID_KEY := "0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789abcdef"

var passed_count := 0
var failed_count := 0


func _assert(condition: bool, msg: String) -> void:
	if condition:
		print("  [OK] %s" % msg)
		passed_count += 1
	else:
		printerr("  [FAIL] %s" % msg)
		failed_count += 1


func _ready() -> void:
	await get_tree().process_frame
	print("==================================================")
	print("【TEST】eos_credentials.cfg 検証ロジック")
	print("==================================================")

	_test_missing_file()
	_test_all_valid()
	_test_each_required_key_empty()
	_test_encryption_key_variants()
	_test_runtime_ignores_encryption_key()

	_remove_tmp()
	print("\n結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("ALL PASSED" if failed_count == 0 else "SOME TESTS FAILED")
	get_tree().quit()


func _valid_values() -> Dictionary:
	return {
		"product_id": "p", "sandbox_id": "s", "deployment_id": "d",
		"client_id": "c", "client_secret": "x", "encryption_key": VALID_KEY,
	}


## values を [eos] セクションに書いた cfg を TMP_PATH へ保存し、読み直した ConfigFile を返す
func _write_tmp(values: Dictionary) -> ConfigFile:
	var cfg := ConfigFile.new()
	for key in values:
		cfg.set_value("eos", key, values[key])
	cfg.save(TMP_PATH)
	var loaded := ConfigFile.new()
	loaded.load(TMP_PATH)
	return loaded


func _remove_tmp() -> void:
	if FileAccess.file_exists(TMP_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PATH))


func _test_missing_file() -> void:
	print("\n[1] ファイルが無い")
	_remove_tmp()
	var problems := _Check.find_problems(TMP_PATH)
	_assert(problems.size() == 1 and "存在しない" in problems[0], "存在しない旨の1件だけを返す: %s" % [problems])


func _test_all_valid() -> void:
	print("\n[2] 全項目が正しい")
	var cfg := _write_tmp(_valid_values())
	_assert(_Check.find_problems(TMP_PATH).is_empty(), "find_problems は空")
	_assert(_Check.is_runtime_usable(cfg), "is_runtime_usable は true")


func _test_each_required_key_empty() -> void:
	print("\n[3] 必須5項目を1つずつ空にする")
	for key in _Check.REQUIRED_KEYS:
		var values := _valid_values()
		values[key] = ""
		var cfg := _write_tmp(values)
		var problems := _Check.find_problems(TMP_PATH)
		_assert(problems.size() == 1 and key in problems[0], "%s が空 → その1件だけを返す: %s" % [key, problems])
		_assert(not _Check.is_runtime_usable(cfg), "%s が空 → 実行時も未設定扱い" % key)
	# 項目そのものが無い（空文字ではなくキー自体が欠落）場合も同じ扱い
	var missing := _valid_values()
	missing.erase("client_secret")
	var cfg2 := _write_tmp(missing)
	_assert(not _Check.is_runtime_usable(cfg2), "client_secret のキー自体が無い → 未設定扱い")


func _test_encryption_key_variants() -> void:
	print("\n[4] encryption_key の空・長さ違い・非16進")
	var cases := {
		"": "空",
		VALID_KEY.substr(0, 63): "63文字",
		VALID_KEY + "0": "65文字",
		"g" + VALID_KEY.substr(1): "16進以外の文字を含む",
		"-" + VALID_KEY.substr(1): "先頭が符号（is_valid_hex_number が通してしまう形）",
	}
	for key_value in cases:
		var values := _valid_values()
		values["encryption_key"] = key_value
		_write_tmp(values)
		var problems := _Check.find_problems(TMP_PATH)
		_assert(problems.size() == 1 and "encryption_key" in problems[0],
				"%s → encryption_key の1件だけを返す: %s" % [cases[key_value], problems])


func _test_runtime_ignores_encryption_key() -> void:
	print("\n[5] 実行時判定は encryption_key を見ない（従来の起動可否を変えない）")
	var values := _valid_values()
	values["encryption_key"] = ""
	var cfg := _write_tmp(values)
	_assert(_Check.is_runtime_usable(cfg), "encryption_key が空でも is_runtime_usable は true")
	_assert(not _Check.find_problems(TMP_PATH).is_empty(), "同じ cfg でも find_problems は問題ありと返す")

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
