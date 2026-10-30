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
## **クラウドセーブも守る**: `backup()` は `EosManager.cloud_sync_blocked_for_tests` を立て、
## 起動時のクラウドセーブ同期(EOS PDS)を止める。ローカルの退避・復元だけでは足りない。
## 同期はテスト本体と並行して走る(EOS ログインに数秒かかる)ので、テストがメモリ上で
## 書き換えた値が実アカウントのクラウドへ上がり、`highest_rating` は大きい方を採る(ratchet)
## ため、その後は EOS にログインするたびに開発機へ戻ってくる。2026-09-25 に
## `highest_rating=10004` がこの経路で残っているのを見つけ、クラウド側を手で直した。
## `_enter_tree()` は EOS ログインの完了より必ず前なので、同期が始まる前に止められる。
## 実際のクラウド読み書きを確かめるテスト(`test_eos_live_smoke`)だけは
## `backup(false)` でローカルの保護だけにする。
##
## **退避先の名前にプロセス ID を付ける**: `net_roles` / `net_anim` / `net_live` / `emote` は
## ホストとクライアントの2プロセスが同じ `user://` を使う。同じ退避先だと、先に終わった側が
## 退避先を消し、後の側が書き戻せなくなる。
##
## **同じプロセス内の重複退避は参照カウントで扱う**（2026-10-30）: net_live などは、
## change_scene_to_file で current_scene が解放されるのを避けるため、同じスクリプトの
## 「進行役」をルート直下へ逃がす。すると1つのプロセスで backup() が2回呼ばれ、
## 退避先（PID 付きの同じ名前）を共有する。以前は、テスト開始直後のシーン切り替えで
## 元のノードの _exit_tree() → restore() が退避先を消してしまい、最後に進行役が
## restore() するときには書き戻す元が無かった。その間のラウンド終了の保存が実セーブに残り、
## 2026-10-27 の全件実行で net_live が casual_matches_played を +1 していた。
## 今は、同じパスを退避中の数を数え、**最後の1人の restore() だけが**書き戻して退避先を消す。
## 戻り値の辞書は restore() の最後で clear() するので、同じ辞書で2回呼んでも数を減らしすぎない。
##
## `class_name` ではなく `preload()` で参照させているのは、新規スクリプトの
## `class_name` グローバル登録が headless 単体実行では更新されておらず
## "not declared in the current scope" になるケースがあるため
## （`autoload/game/rating_report.gd` の `_RatingBackendClientScript` と同じ理由）。

## 退避先の拡張子。実ファイルの隣に置く（user:// はテスト実行機のローカルのみ）
const BACKUP_SUFFIX := ".testbak"


## このプロセスで退避中の数（path -> 数）と、その退避先（path -> 退避先。空文字は
## 「退避時にファイルが無かった」）。ヘッダの「同じプロセス内の重複退避」参照
static var _holders := {}
static var _baks := {}


## 実セーブを退避する。戻り値は restore() にそのまま渡す。
## 値が空文字のエントリは「退避時にファイルが無かった＝テスト後に消す」の意。
## block_cloud=true(既定)ならクラウドセーブ同期も止める(ヘッダ参照)
static func backup(block_cloud: bool = true) -> Dictionary:
	if block_cloud:
		EosManager.cloud_sync_blocked_for_tests = true
	return _backup_paths(_guarded_paths())


## 退避した実セーブを書き戻す。二重呼び出しされても安全（1回目の最後に辞書を空にする）
static func restore(backups: Dictionary) -> void:
	_restore_paths(backups)


## backup() の本体。パスを受け取るのは tests/test_save_guard.gd が一時ファイルで検証するため
static func _backup_paths(paths: Array) -> Dictionary:
	var out := {}
	for path in paths:
		if _holders.get(path, 0) > 0:
			# 同じプロセスの2人目以降は、1人目の退避先を共有する（ここでコピーし直すと、
			# 1人目がテスト中に書き換えた内容で退避先を上書きしてしまう）
			_holders[path] += 1
			out[path] = _baks[path]
			continue
		var bak := ""
		if FileAccess.file_exists(path):
			bak = "%s%s.%d" % [path, BACKUP_SUFFIX, OS.get_process_id()]
			if DirAccess.copy_absolute(path, bak) != OK:
				printerr("  [WARN] 実セーブの退避に失敗: %s" % path)
				continue
		_holders[path] = 1
		_baks[path] = bak
		out[path] = bak
	return out


## restore() の本体。退避中の最後の1人のときだけ書き戻す
static func _restore_paths(backups: Dictionary) -> void:
	for path in backups:
		var left: int = _holders.get(path, 0) - 1
		if left > 0:
			_holders[path] = left
			continue
		_holders.erase(path)
		_baks.erase(path)
		var bak: String = backups[path]
		if bak.is_empty():
			DirAccess.remove_absolute(path)
			continue
		if not FileAccess.file_exists(bak):
			continue
		DirAccess.copy_absolute(bak, path)
		DirAccess.remove_absolute(bak)
	backups.clear()


## 守る対象。パスはテスト側にハードコードせず各Autoloadの定数をそのまま参照する
static func _guarded_paths() -> Array[String]:
	return [ProfileManager.SAVE_PATH, SettingsManager.SAVE_PATH]
