extends Node

## KAN-71: 設定画面の「お問い合わせ・不具合の報告」欄を検証する。
##
##   pwsh tools/run_headless_test.ps1 res://tests/test_support_info.tscn
##
##   [1] 版数(ストア版数と通信版数)・問い合わせ先・ログの場所・「ログのフォルダを開く」が出ている
##   [2] 言語を切り替えると、スクリプトで組み立てた文言も訳し直される
##   [3] 問い合わせ先が EULA・プライバシーポリシー・ストアページの記載と一致している
##       (片方だけ書き換えて食い違う事故を防ぐ)
##
## ボタンは押さない(押すとエクスプローラーが開く)。

const SETTINGS_SCENE := preload("res://scenes/settings_screen.tscn")
const SettingsScript := preload("res://scenes/settings_screen.gd")
## SUPPORT_EMAIL と同じ値が書かれているはずの文書
const DOCS_WITH_EMAIL := [
	"res://docs/EULA_DRAFT.md",
	"res://docs/PRIVACY_POLICY_DRAFT.md",
	"res://docs/concept/store/itchio_page_ja.md",
	"res://docs/concept/store/itchio_page_en.md",
]

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
	TranslationServer.set_locale("ja")
	print("==================================================")
	print("【TEST】KAN-71: 設定画面の問い合わせ欄")
	print("==================================================")

	var screen: Control = SETTINGS_SCENE.instantiate()
	add_child(screen)
	await get_tree().process_frame

	_test_contents_ja(screen)
	await _test_language_switch(screen)
	_test_docs_match()

	TranslationServer.set_locale("ja")
	screen.queue_free()

	print("==================================================")
	print("test_support_info 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> test_support_info: ALL PASSED")
	else:
		printerr("=> test_support_info: SOME TESTS FAILED")
	get_tree().quit()


func _section(screen: Control) -> Node:
	return screen.get_node("ContentMargin/Scroll/MainVBox/SupportSection")


func _test_contents_ja(screen: Control) -> void:
	print("\n--- [1] 表示内容（日本語） ---")
	var sec := _section(screen)
	var version := str(ProjectSettings.get_setting("application/config/version", ""))
	var version_text: String = (sec.get_node("VersionLabel") as Label).text
	_assert(not version.is_empty() and version_text.contains("Ver " + version),
		"ストア版数が出ている: %s" % version_text)
	_assert(version_text.contains("v%d" % GameManager.PROTOCOL_VERSION),
		"通信版数が出ている")
	_assert((sec.get_node("ContactLabel") as Label).text == "お問い合わせ: " + SettingsScript.SUPPORT_EMAIL,
		"問い合わせ先が出ている")
	var log_label := sec.get_node("LogPathLabel") as Label
	var log_path := SettingsScript.log_file_path()
	_assert(log_path.is_absolute_path() and log_path.ends_with("godot.log"),
		"ログのパスが OS の絶対パスになっている: %s" % log_path)
	_assert(log_label.visible and log_label.text == "ログの場所: " + SettingsScript.log_file_path_for_display(),
		"ログの場所が出ている（デスクトップ版）: %s" % log_label.text)
	if OS.has_feature("windows"):
		_assert(not log_label.text.contains("/"), "Windows では区切りが「\\」になっている")
	var btn := sec.get_node("OpenLogsButton") as Button
	_assert(btn.visible and btn.is_connected("pressed", Callable(screen, "_on_open_logs_pressed")),
		"「ログのフォルダを開く」が出ていて、押したときの処理につながっている")
	_assert((sec.get_node("HintLabel") as Label).text.contains("godot.log"),
		"報告時に添えるもの（ログのファイル）を案内している")


func _test_language_switch(screen: Control) -> void:
	print("\n--- [2] 言語の切り替え ---")
	TranslationServer.set_locale("en")
	await get_tree().process_frame
	await get_tree().process_frame
	var sec := _section(screen)
	_assert((sec.get_node("ContactLabel") as Label).text == "Contact: " + SettingsScript.SUPPORT_EMAIL,
		"英語に切り替えると問い合わせ先の文言も英語になる")
	_assert((sec.get_node("LogPathLabel") as Label).text.begins_with("Log file: "),
		"英語に切り替えるとログの場所の文言も英語になる")
	_assert((sec.get_node("VersionLabel") as Label).text.contains("(Protocol v"),
		"英語に切り替えると版数の文言も英語になる")


func _test_docs_match() -> void:
	print("\n--- [3] 文書との一致 ---")
	for path in DOCS_WITH_EMAIL:
		var text := FileAccess.get_file_as_string(path)
		_assert(not text.is_empty() and text.contains(SettingsScript.SUPPORT_EMAIL),
			"%s に問い合わせ先 %s がある" % [path.get_file(), SettingsScript.SUPPORT_EMAIL])

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
