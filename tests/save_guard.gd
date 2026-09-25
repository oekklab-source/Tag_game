extends RefCounted

## Phase 3 L-12: テストが開発機の実セーブ（`user://profile.json` /
## `user://settings.json`）を書き換えてしまうのを防ぐ共通ヘルパ。
##
## 使い方（既存コードに一切触らず、この2関数を足すだけでよい）:
##
##     const _SaveGuard := preload("res://tests/save_guard.gd")
##     var _save_backup := {}
##
##     func _enter_tree() -> void:
##         _save_backup = _SaveGuard.backup()
##
##     func _exit_tree() -> void:
##         _SaveGuard.restore(_save_backup)
##
## `_enter_tree()` は `_ready()` より前、`_exit_tree()` はツリーから外れるとき
## （`get_tree().quit()` の後も含む）に必ず呼ばれるので、テスト本体がどこで
## 終わっても・途中でランタイムエラーが出ても書き戻される。
##
## **なぜ「テストが直接 save_profile() を呼ぶかどうか」で判断してはいけないか**:
## ラウンドを回すテスト（`test_phase1_rules` / `test_phase7_stability` /
## `cpu_*` / `hunter_squad` / `uishot` 等）は、通常のゲーム終了経路
## （`GameManager._end_round()` → `hud.gd` → `ProfileManager.record_casual_match()`）
## から**間接的に** `save_profile()` を踏む。2026-09-25 に実測したところ
## `test_phase7_stability` は1回の実行で `casual_matches_played` を +9、
## `test_phase1_rules` は +2 していた。grep で `save_profile` を探すだけでは見つからない。
##
## `class_name` ではなく `preload()` で参照させているのは、新規スクリプトの
## `class_name` グローバル登録が headless 単体実行では更新されておらず
## "not declared in the current scope" になるケースがあるため
## （`autoload/game/rating_report.gd` の `_RatingBackendClientScript` と同じ理由）。

## 退避先の拡張子。実ファイルの隣に置く（user:// はテスト実行機のローカルのみ）
const BACKUP_SUFFIX := ".testbak"


## 実セーブを退避する。戻り値は restore() にそのまま渡す。
## 値が空文字のエントリは「退避時にファイルが無かった＝テスト後に消す」の意
static func backup() -> Dictionary:
	var out := {}
	for path in _guarded_paths():
		if not FileAccess.file_exists(path):
			out[path] = ""
			continue
		var bak: String = path + BACKUP_SUFFIX
		if DirAccess.copy_absolute(path, bak) != OK:
			printerr("  [WARN] 実セーブの退避に失敗: %s" % path)
			continue
		out[path] = bak
	return out


## 退避した実セーブを書き戻す。二重呼び出しされても安全（2回目は退避先が無いので何もしない）
static func restore(backups: Dictionary) -> void:
	for path in backups:
		var bak: String = backups[path]
		if bak.is_empty():
			DirAccess.remove_absolute(path)
			continue
		if not FileAccess.file_exists(bak):
			continue
		DirAccess.copy_absolute(bak, path)
		DirAccess.remove_absolute(bak)


## 守る対象。パスはテスト側にハードコードせず各Autoloadの定数をそのまま参照する
static func _guarded_paths() -> Array[String]:
	return [ProfileManager.SAVE_PATH, SettingsManager.SAVE_PATH]
