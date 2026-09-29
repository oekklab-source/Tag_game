@tool
extends EditorExportPlugin

## Windows 書き出し時に eos_credentials.cfg の不備を検出して知らせる（Phase 3 L-08）。
##
## 背景: eos_credentials.cfg は .gitignore 対象で、無いまま（または空欄のまま）書き出しても
## Godot は何も言わない。実行時の EosManager はクラッシュせずにオフライン/フォールバック
## モードへ落ちるだけなので、「EOS に一切つながらない版」が黙って出荷される。
## encryption_key が空の場合も同様に、クラウドセーブだけが黙って常に失敗する。
##
## 【重要: プラグインからは書き出しを止められない（2026-09-25 実測）】
## Godot 4.7.2 で次の2つを試したが、どちらも CLI の --export-release は最後まで完走し、
## exe が出力され、終了コードも 0 のままだった:
##   - _get_export_option_warning() で空でない文字列を返す
##     → CLI では表示すらされない。エディタの書き出しダイアログで赤字になるだけ
##   - _export_begin() で add_message(EXPORT_MESSAGE_ERROR) / push_error()
##     → "ERROR:" 行が出るだけで、書き出しは続行される
## そのため本当に止めるのは tools/export_windows.ps1 の役目で、このプラグインは
## 「目に見えるようにする」ことと、ラッパーが拾う目印（BLOCK_MARKER）を出すことに徹する。
## 素の godot --export-release を直接叩くと、この目印に誰も気付かないまま exe ができる。
##
## 意図的にオフライン版を作りたいときは、書き出しプリセットの
## tag_game/require_eos_credentials を false にする（export_presets.cfg に残るので
## 「意図してオフライン版にした」ことが差分で分かる）。
##
## Web 版は対象外: 認証情報を同梱しない設計（export_presets.cfg の Web プリセットは
## include_filter が空。ブラウザ版では EOS 自体が動かない）。

const _CredentialsCheck := preload("res://autoload/eos_credentials_check.gd")
const CREDENTIALS_PATH := "res://eos_credentials.cfg"
const OPTION_REQUIRE := "tag_game/require_eos_credentials"
## tools/export_windows.ps1 がこの文字列を出力から探す。変えるならあちらも合わせること
const BLOCK_MARKER := "[TagGameExportGuard] BLOCKED"


func _get_name() -> String:
	return "TagGameExportGuard"


func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform is EditorExportPlatformWindows


func _get_export_options(_platform: EditorExportPlatform) -> Array[Dictionary]:
	return [{
		"option": {"name": OPTION_REQUIRE, "type": TYPE_BOOL},
		"default_value": true,
	}]


## エディタの書き出しダイアログで、オプションの下に赤字で出る（書き出しボタンは押せてしまう）
func _get_export_option_warning(_platform: EditorExportPlatform, option: String) -> String:
	if option != OPTION_REQUIRE:
		return ""
	return _describe_problems()


## 書き出し結果のメッセージ一覧（エディタ）と標準出力（CLI）にエラーとして出す
func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	var text := _describe_problems()
	if text.is_empty():
		return
	get_export_platform().add_message(EditorExportPlatform.EXPORT_MESSAGE_ERROR, "EOS", text)
	printerr("%s %s" % [BLOCK_MARKER, text.replace("\n", " ")])


## 問題が無い（またはガードを明示的に切ってある）なら空文字
func _describe_problems() -> String:
	if not get_option(OPTION_REQUIRE):
		return ""
	var problems := _CredentialsCheck.find_problems(CREDENTIALS_PATH)
	if problems.is_empty():
		return ""
	return "eos_credentials.cfg に不備がある（このままだとEOSなしの版になる）:\n- %s\n" \
			% "\n- ".join(problems) \
			+ "（意図的にEOSなしで書き出すなら %s を false にする）" % OPTION_REQUIRE
