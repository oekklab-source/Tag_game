extends Node
## tests/save_guard.gd の退避・復元の検証（実セーブではなく一時ファイルで見る）。
##
##   pwsh tools/run_headless_test.ps1 res://tests/test_save_guard.tscn
##
## 2026-10-27 に net_live が実セーブへ +1 を残した不具合の回帰テスト。
## net_live などは同じスクリプトの「進行役」をルート直下へ逃がすので、1つのプロセスで
## backup() が2回呼ばれ、元のノードがテスト開始直後に restore() する。
## その後の書き込みが、最後の restore() で必ず元に戻ることを確かめる。

const _SaveGuard := preload("res://tests/save_guard.gd")
const FILE_A := "user://save_guard_test_a.json"
const FILE_NEW := "user://save_guard_test_new.json"

var _fail := 0
var _pass := 0


func _ready() -> void:
	print("=== save_guard の退避・復元の検証 ===")
	_cleanup()
	_test_shared_backup()
	_test_double_restore()
	_test_missing_file()
	_test_single_holder()
	_cleanup()
	print("test_save_guard 結果: PASS=%d, FAIL=%d" % [_pass, _fail])
	if _fail == 0:
		print("=> test_save_guard: ALL PASSED")
	get_tree().quit(0 if _fail == 0 else 1)


func _assert(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("  [OK] %s" % label)
	else:
		_fail += 1
		print("  FAIL %s" % label)


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else "<none>"


func _cleanup() -> void:
	for p in [FILE_A, FILE_NEW]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		var bak := "%s%s.%d" % [p, _SaveGuard.BACKUP_SUFFIX, OS.get_process_id()]
		if FileAccess.file_exists(bak):
			DirAccess.remove_absolute(bak)


## [1] net_live の流れ: 元のノード(A)と進行役(B)が退避 → A が先に復元 → 書き込み → B が復元
func _test_shared_backup() -> void:
	print("\n--- [1] 同じプロセスで2人が退避し、先の1人が早く復元する ---")
	_write(FILE_A, "original")
	var a := _SaveGuard._backup_paths([FILE_A])
	var b := _SaveGuard._backup_paths([FILE_A])
	var bak: String = a[FILE_A]
	_assert(a[FILE_A] == b[FILE_A], "2人目は1人目と同じ退避先を共有する")
	_SaveGuard._restore_paths(a)
	_assert(FileAccess.file_exists(bak), "先の1人が復元しても、退避先はまだ残っている")
	_write(FILE_A, "changed by round end")
	_SaveGuard._restore_paths(b)
	_assert(_read(FILE_A) == "original", "最後の1人の復元で元の内容に戻る (実際: %s)" % _read(FILE_A))
	_assert(not FileAccess.file_exists(bak), "最後の1人の復元で退避先が消える")


## [2] 同じ辞書で2回 restore() しても、他の人の分まで数を減らさない
func _test_double_restore() -> void:
	print("\n--- [2] 同じ辞書での二重の復元 ---")
	_write(FILE_A, "original")
	var a := _SaveGuard._backup_paths([FILE_A])
	var b := _SaveGuard._backup_paths([FILE_A])
	_SaveGuard._restore_paths(a)
	_SaveGuard._restore_paths(a)
	_write(FILE_A, "changed")
	_assert(a.is_empty(), "1回目の復元で辞書が空になる")
	_SaveGuard._restore_paths(b)
	_assert(_read(FILE_A) == "original", "二重に呼んでも、最後の1人の復元で戻る (実際: %s)" % _read(FILE_A))


## [3] 退避時にファイルが無ければ、最後の復元で消える（テストが作ったファイルを残さない）
func _test_missing_file() -> void:
	print("\n--- [3] 元々ファイルが無かった場合 ---")
	var a := _SaveGuard._backup_paths([FILE_NEW])
	var b := _SaveGuard._backup_paths([FILE_NEW])
	_SaveGuard._restore_paths(a)
	_write(FILE_NEW, "created by test")
	_assert(FileAccess.file_exists(FILE_NEW), "先の1人の復元では消さない")
	_SaveGuard._restore_paths(b)
	_assert(not FileAccess.file_exists(FILE_NEW), "最後の1人の復元で消える")


## [4] 1人だけのとき（今までの使い方）は今までどおり
func _test_single_holder() -> void:
	print("\n--- [4] 1人だけで退避・復元 ---")
	_write(FILE_A, "original")
	var a := _SaveGuard._backup_paths([FILE_A])
	var bak: String = a[FILE_A]
	_write(FILE_A, "changed")
	_SaveGuard._restore_paths(a)
	_assert(_read(FILE_A) == "original", "書き戻る (実際: %s)" % _read(FILE_A))
	_assert(not FileAccess.file_exists(bak), "退避先が消える")


# --- 実セーブ(user://profile.json / settings.json)とクラウドセーブの保護 ---
# ラウンドを回さないテストでも、EOS にログインできる環境では起動時のクラウドセーブ同期が
# 実セーブを書き換える(2026-09-25 に boost_panel の実行中に実測)。どのテストが
# 踏むかを個別に見極めるより、全テストで一律に挟む。詳細は tests/save_guard.gd のヘッダ。
var _save_backup := {}


func _enter_tree() -> void:
	_save_backup = _SaveGuard.backup()


func _exit_tree() -> void:
	_SaveGuard.restore(_save_backup)
