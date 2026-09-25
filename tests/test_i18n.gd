extends Node

## L-09: ローカライズ基盤(res://locale/en.po)の整合性を機械的に検証する。
##
##   pwsh tools/run_headless_test.ps1 res://tests/test_i18n.tscn
##
## 検証内容:
##   [1] en.po の msgid に重複が無く、全エントリの msgstr が空でなく、%d / %s / %.1f 等の書式指定が
##       msgid と同じ種類・同じ順番で残っていること(英語版だけ書式エラーになる事故を防ぐ)
##   [2] .gd の tr("…") / TranslationServer.translate("…") のリテラルが en.po にあること
##   [3] .tscn の日本語の text / tooltip_text / placeholder_text / title / dialog_text が
##       en.po にあること(Control の auto_translate で自動的に訳される側)
##   [4] .gd に残っている日本語リテラルが「en.po にある(＝表示時に tr() される定数)」か
##       「開発者向け出力(print/push_warning 等)」か「UNTRANSLATED_OK に理由付きで登録」の
##       どれかであること(＝訳し忘れの検出)
##   [5] SettingsManager の language 設定(ホワイトリスト・ロケール反映)。保存は呼ばない
##
## 抜けていた msgid は一覧で出力するので、そのまま en.po に足せばよい。

const PO_PATH := "res://locale/en.po"
const SCAN_DIRS := ["res://scenes", "res://autoload"]

## まだ tr() 化していないファイル(L-09 のセッション S2/S3 で順に減らし、最後は空にする)。
## ここにあるファイルは [3][4] の対象外
const PENDING_FILES := [
	"res://scenes/costume_screen.gd", "res://scenes/costume_screen.tscn",
	"res://scenes/friend_screen.gd", "res://scenes/friend_screen.tscn",
	"res://scenes/ranking_dialog.gd", "res://scenes/ranking_dialog.tscn",
	"res://scenes/shop_screen.gd", "res://scenes/shop_screen.tscn",
	"res://scenes/room_match_dialog.gd", "res://scenes/room_match_dialog.tscn",
	"res://autoload/ranking_manager.gd", "res://autoload/gift_manager.gd",
	"res://autoload/purchase_manager.gd", "res://autoload/eos_manager.gd",
	"res://autoload/costume_catalog.gd", "res://autoload/hat_catalog.gd",
	"res://autoload/currency_pack_catalog.gd", "res://autoload/profile_manager.gd",
]

## 訳さないことが正しい日本語リテラル。{ファイル: {リテラル: 理由}}。
## 理由を書けないものは登録しないこと(訳し忘れの逃げ道にしない)
const UNTRANSLATED_OK := {
	"res://scenes/settings_screen.gd": {
		"日本語": "言語の選択肢は、読めない言語の画面からでも探せるよう各言語の自称で固定する",
	},
}

## 開発者向けのメッセージしか持たないファイル。[4] の対象外
## (world_builder はマップデータの検証、eos_credentials_check は書き出し時の検査結果)
const DEV_FILES := ["res://scenes/world_builder.gd", "res://autoload/eos_credentials_check.gd"]

## 開発者向け出力。利用者には見えないので訳さない
const DEV_CALLS := ["print(", "printerr(", "print_debug(", "push_warning(", "push_error(", "assert("]

var _fail := 0
var _pass := 0
var _po := {}  # msgid -> msgstr
var _po_dups: Array[String] = []  # 2回以上出てきた msgid
var _jp: RegEx
var _fmt: RegEx


func _ready() -> void:
	print("=== L-09 ローカライズ基盤の検証 ===")
	_jp = RegEx.create_from_string("[\\x{3040}-\\x{30FF}\\x{4E00}-\\x{9FFF}\\x{FF01}-\\x{FF60}]")
	_fmt = RegEx.create_from_string("%[-+ 0#]*\\d*(?:\\.\\d+)?[dsfxXcv%]")
	_po = _parse_po(PO_PATH)
	_ok("en.po を読めた(%d エントリ)" % _po.size(), _po.size() > 0)

	_check_po_entries()
	var gd_files: Array[String] = []
	var tscn_files: Array[String] = []
	for dir in SCAN_DIRS:
		_collect(dir, gd_files, tscn_files)
	_check_gd_tr_literals(gd_files)
	_check_tscn_texts(tscn_files)
	_check_gd_untranslated(gd_files)
	_check_settings_language()

	print("test_i18n 結果: PASS=%d, FAIL=%d" % [_pass, _fail])
	print("=> test_i18n: ALL PASSED" if _fail == 0 else "=> test_i18n: SOME TESTS FAILED")
	get_tree().quit()


func _ok(label: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  [OK] ", label)
	else:
		_fail += 1
		printerr("  [FAIL] ", label)


# ---------------------------------------------------------------- [1]
func _check_po_entries() -> void:
	var bad: Array[String] = []
	for id in _po:
		var s: String = _po[id]
		if s.is_empty():
			bad.append("msgstr が空: " + id)
		elif _formats(id) != _formats(s):
			bad.append("書式指定が不一致 %s -> %s: %s" % [_formats(id), _formats(s), id])
	for b in bad:
		printerr("    ", b)
	_ok("[1] 全 msgstr が空でなく書式指定が一致する", bad.is_empty())
	for d in _po_dups:
		printerr("    重複: ", d)
	_ok("[1] msgid の重複が無い", _po_dups.is_empty())


func _formats(s: String) -> Array[String]:
	var out: Array[String] = []
	for m in _fmt.search_all(s):
		if m.get_string() != "%%":
			out.append(m.get_string())
	return out


# ---------------------------------------------------------------- [2]
func _check_gd_tr_literals(files: Array[String]) -> void:
	var re := RegEx.create_from_string(
		"(?:\\btr|TranslationServer\\.translate)\\(\\s*\"((?:[^\"\\\\\\n]|\\\\.)*)\"")
	var missing: Array[String] = []
	var count := 0
	for path in files:
		for m in re.search_all(_read(path)):
			count += 1
			var key := m.get_string(1).c_unescape()
			if not _po.has(key):
				missing.append("%s: %s" % [path, key])
	_report_missing("[2] .gd の tr() リテラル %d 件がすべて en.po にある" % count, missing)


# ---------------------------------------------------------------- [3]
func _check_tscn_texts(files: Array[String]) -> void:
	var re := RegEx.create_from_string(
		"(?m)^(?:text|tooltip_text|placeholder_text|title|dialog_text) = \"((?:[^\"\\\\]|\\\\.)*)\"")
	var missing: Array[String] = []
	var count := 0
	for path in files:
		if path in PENDING_FILES:
			continue
		for m in re.search_all(_read(path)):
			var key := m.get_string(1).c_unescape()
			if _jp.search(key) == null:
				continue
			count += 1
			if not _po.has(key):
				missing.append("%s: %s" % [path, key])
	_report_missing("[3] .tscn の日本語テキスト %d 件がすべて en.po にある" % count, missing)


# ---------------------------------------------------------------- [4]
func _check_gd_untranslated(files: Array[String]) -> void:
	var lit := RegEx.create_from_string("\"((?:[^\"\\\\]|\\\\.)*)\"")
	var missing: Array[String] = []
	for path in files:
		if path in PENDING_FILES or path in DEV_FILES:
			continue
		var ok_map: Dictionary = UNTRANSLATED_OK.get(path, {})
		var lines := _read(path).split("\n")
		for i in lines.size():
			var code := _strip_comment(lines[i])
			if DEV_CALLS.any(func(c: String) -> bool: return code.contains(c)):
				continue
			for m in lit.search_all(code):
				var s := m.get_string(1).c_unescape()
				if _jp.search(s) == null or _po.has(s) or ok_map.has(s):
					continue
				missing.append("%s:%d: %s" % [path, i + 1, s])
	_report_missing("[4] .gd に訳し忘れの日本語リテラルが無い", missing)


## 文字列の外にある # 以降を落とす(GDScript の行コメント)
func _strip_comment(line: String) -> String:
	var in_str := false
	var i := 0
	while i < line.length():
		var c := line[i]
		if in_str:
			if c == "\\":
				i += 1
			elif c == "\"":
				in_str = false
		elif c == "\"":
			in_str = true
		elif c == "#":
			return line.substr(0, i)
		i += 1
	return line


# ---------------------------------------------------------------- [5]
func _check_settings_language() -> void:
	var saved_language: String = SettingsManager.language
	var saved_locale := TranslationServer.get_locale()

	SettingsManager._apply_data({"language": "en"})
	_ok("[5] language=\"en\" を読み込める", SettingsManager.language == "en")
	SettingsManager._apply_data({"language": "fr"})
	_ok("[5] 未対応の言語は auto に戻る", SettingsManager.language == "auto")
	SettingsManager._apply_data({})
	_ok("[5] キーが無ければ auto", SettingsManager.language == "auto")
	_ok("[5] to_save_dict() に language が入る", SettingsManager.to_save_dict().has("language"))

	SettingsManager.set_language("en")
	_ok("[5] en にすると英訳される(はい -> %s)" % tr("はい"), tr("はい") == "Yes")
	SettingsManager.set_language("ja")
	_ok("[5] ja にすると原文のまま", tr("はい") == "はい")
	_ok("[5] auto: OS が日本語なら ja", SettingsManager.resolve_locale("auto", "ja") == "ja")
	_ok("[5] auto: OS が日本語以外(fr)なら en", SettingsManager.resolve_locale("auto", "fr") == "en")
	_ok("[5] 明示指定は OS より優先", SettingsManager.resolve_locale("ja", "en") == "ja")
	# fallback="ja" の確認: 訳の無いロケールでは原文(日本語)が出る。"en" にすると ja でも英語になる
	TranslationServer.set_locale("fr")
	_ok("[5] 訳の無いロケールは原文を返す(fallback=ja)", tr("はい") == "はい")

	SettingsManager.language = saved_language
	TranslationServer.set_locale(saved_locale)


# ---------------------------------------------------------------- helpers
func _report_missing(label: String, missing: Array[String]) -> void:
	for m in missing:
		printerr("    未登録: ", m)
	_ok(label + ("" if missing.is_empty() else "(未登録 %d 件)" % missing.size()), missing.is_empty())


func _collect(dir: String, gd: Array[String], tscn: Array[String]) -> void:
	for f in DirAccess.get_files_at(dir):
		var p := dir.path_join(f)
		if f.ends_with(".gd"):
			gd.append(p)
		elif f.ends_with(".tscn"):
			tscn.append(p)
	for d in DirAccess.get_directories_at(dir):
		_collect(dir.path_join(d), gd, tscn)


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


## gettext PO の最小パーサ(msgctxt / 複数行の連結 / エスケープに対応)。
## 空 msgid のヘッダエントリは除く
func _parse_po(path: String) -> Dictionary:
	var out := {}
	var cur_id := ""
	var cur_str := ""
	var field := ""
	var in_entry := false
	for raw in (_read(path) + "\n\n").split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			if in_entry and not cur_id.is_empty():
				if out.has(cur_id):
					_po_dups.append(cur_id)
				out[cur_id] = cur_str
			in_entry = false
			cur_id = ""
			cur_str = ""
			field = ""
			continue
		in_entry = true
		if line.begins_with("msgctxt "):
			field = "ctxt"
			continue
		if line.begins_with("msgid "):
			field = "id"
			line = line.substr(6)
		elif line.begins_with("msgstr "):
			field = "str"
			line = line.substr(7)
		var v := line.substr(1, line.length() - 2).c_unescape()
		if field == "id":
			cur_id += v
		elif field == "str":
			cur_str += v
	return out
