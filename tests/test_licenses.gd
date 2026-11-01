extends Node
## KAN-45: クレジット・ライセンス表記の検証。
##
##   pwsh tools/run_headless_test.ps1 res://tests/test_licenses.tscn
##
##   [1] licenses/GODOT_LICENSES.txt が、今の Godot の Engine.get_copyright_info() /
##       get_license_info() から作った文面(CreditsScreen.godot_notice_text())と一致する。
##       Godot を上げたら食い違うので、次で作り直してコミットする:
##         godot --headless --path . res://tests/test_licenses.tscn -- --write
##   [2] licenses/THIRD_PARTY_LICENSES.txt が res:// から読め、配布物に入っている
##       サードパーティ(docs/THIRD_PARTY_LICENSES.md §1)がすべて載っている
##   [3] export_presets.cfg の Web / Windows の両方で、THIRD_PARTY_LICENSES.txt を pck に
##       入れている(クレジット画面が読むため。漏れると画面が空になる)
##   [4] tools/export_windows.ps1 が2つのライセンス文書を配布フォルダへコピーする
##   [5] クレジット画面を開くと、ゲーム名・第三者ライセンス・Godot の全件が表示される

const CreditsScreen := preload("res://scenes/credits_screen.gd")
const GODOT_FILE := "res://licenses/GODOT_LICENSES.txt"
const THIRD_PARTY_FILE := "res://licenses/THIRD_PARTY_LICENSES.txt"
const PRESETS_FILE := "res://export_presets.cfg"
const EXPORT_SCRIPT := "res://tools/export_windows.ps1"

## 配布物に入るサードパーティ。docs/THIRD_PARTY_LICENSES.md §1 に行を足したらここにも足す
const REQUIRED_ENTRIES := [
	"Godot Engine",
	"FreeType",
	"cloudflared",
	"Epic Online Services Godot",
	"godot-cpp",
	"Epic Online Services SDK",
	"XAudio 2.9",
	"Visual C++",
	"M PLUS Rounded 1c",
	"SIL OPEN FONT LICENSE",
]

var _fail := 0
var _pass := 0


func _ready() -> void:
	print("=== KAN-45 クレジット・ライセンス表記の検証 ===")
	if "--write" in OS.get_cmdline_user_args():
		_write_godot_file()
		get_tree().quit()
		return
	_check_godot_file()
	_check_third_party_file()
	_check_presets()
	_check_export_script()
	await _check_screen()
	print("test_licenses 結果: PASS=%d, FAIL=%d" % [_pass, _fail])
	if _fail == 0:
		print("=> test_licenses: ALL PASSED")
	get_tree().quit(0 if _fail == 0 else 1)


func _assert(cond: bool, label: String, detail := "") -> void:
	if cond:
		_pass += 1
		print("  [OK] %s" % label)
	else:
		_fail += 1
		print("  FAIL %s %s" % [label, detail])


func _normalize(s: String) -> String:
	return s.replace("\r\n", "\n").strip_edges()


func _write_godot_file() -> void:
	var f := FileAccess.open(GODOT_FILE, FileAccess.WRITE)
	if f == null:
		print("  FAIL %s に書けない (%s)" % [GODOT_FILE, error_string(FileAccess.get_open_error())])
		return
	f.store_string(CreditsScreen.godot_notice_text() + "\n")
	f.close()
	print("  wrote %s" % GODOT_FILE)


func _check_godot_file() -> void:
	var expected := _normalize(CreditsScreen.godot_notice_text())
	var actual := _normalize(FileAccess.get_file_as_string(GODOT_FILE))
	_assert(not actual.is_empty(), "[1] %s がある" % GODOT_FILE)
	_assert(actual == expected, "[1] %s が今の Godot の出力と一致する" % GODOT_FILE,
		"(Godot を上げたなら -- --write で作り直してコミットする)")
	_assert(expected.contains("License: Expat") and expected.contains("FreeType"),
		"[1] Godot の出力に同梱ライブラリとライセンス本文が入っている")


func _check_third_party_file() -> void:
	var text := FileAccess.get_file_as_string(THIRD_PARTY_FILE)
	_assert(not text.is_empty(), "[2] %s が res:// から読める" % THIRD_PARTY_FILE)
	var missing: Array[String] = []
	for e in REQUIRED_ENTRIES:
		if not text.contains(e):
			missing.append(e)
	_assert(missing.is_empty(), "[2] 配布物のサードパーティ %d 件がすべて載っている" % REQUIRED_ENTRIES.size(),
		"(無い: %s)" % ", ".join(missing))
	_assert(text.contains("GODOT_LICENSES.txt"), "[2] Godot の全件の置き場所(GODOT_LICENSES.txt)を案内している")


func _check_presets() -> void:
	var cfg := ConfigFile.new()
	_assert(cfg.load(PRESETS_FILE) == OK, "[3] export_presets.cfg を読める")
	var found := 0
	for section in cfg.get_sections():
		if not section.begins_with("preset.") or section.ends_with(".options"):
			continue
		var preset_name := str(cfg.get_value(section, "name", section))
		var filters := str(cfg.get_value(section, "include_filter", "")).split(",")
		_assert("licenses/THIRD_PARTY_LICENSES.txt" in filters,
			"[3] %s の include_filter に licenses/THIRD_PARTY_LICENSES.txt がある" % preset_name)
		found += 1
	_assert(found >= 2, "[3] Web と Windows の2つのプリセットを確かめた", "(%d 件)" % found)


func _check_export_script() -> void:
	var text := FileAccess.get_file_as_string(EXPORT_SCRIPT)
	_assert(text.contains("'licenses/THIRD_PARTY_LICENSES.txt'"), "[4] export_windows.ps1 が THIRD_PARTY_LICENSES.txt を同梱する")
	_assert(text.contains("'licenses/GODOT_LICENSES.txt'"), "[4] export_windows.ps1 が GODOT_LICENSES.txt を同梱する")


func _check_screen() -> void:
	var screen: Control = load("res://scenes/credits_screen.tscn").instantiate()
	add_child(screen)
	await get_tree().process_frame
	var body: RichTextLabel = screen.get_node("ContentMargin/Body")
	var text := body.get_parsed_text()
	_assert(text.contains(tr("逆転鬼ごっこ")), "[5] ゲーム名が出る")
	_assert(text.contains("Ver %s" % ProjectSettings.get_setting("application/config/version")), "[5] ストア版数が出る")
	_assert(text.contains("cloudflared") and text.contains("M PLUS Rounded 1c"), "[5] 第三者ライセンスの文書が出る")
	_assert(text.contains("Engine.get_copyright_info()") and text.contains("License: Apache-2.0"),
		"[5] Godot の全件とライセンス本文が出る")
	screen.queue_free()


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
