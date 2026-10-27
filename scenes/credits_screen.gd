extends Control
## KAN-45: クレジット・ライセンス画面。タイトル画面の左下のボタンから開く。
##
## 表示するのは次の3つ:
##   1. ゲーム名と版数
##   2. licenses/THIRD_PARTY_LICENSES.txt（配布フォルダに同梱するものと同じファイル。
##      export_presets.cfg の include_filter で pck にも入れている。文面を1か所で管理するため）
##   3. Godot 本体と同梱ライブラリの全件（Engine.get_copyright_info() / get_license_info() から作る）
##
## 3 は Godot の公式ドキュメント「Complying with licenses」が勧めるやり方で、エンジンを
## 上げても手で書き直さなくてよい。配布フォルダ用の licenses/GODOT_LICENSES.txt も
## godot_notice_text() の出力そのもので、tests/test_licenses.tscn がずれていないかを見ている。

const TITLE_SCENE := "res://scenes/title.tscn"
const THIRD_PARTY_PATH := "res://licenses/THIRD_PARTY_LICENSES.txt"

@onready var back_button: Button = $TopBar/BackButton
@onready var body: RichTextLabel = $ContentMargin/Body


func _ready() -> void:
	back_button.pressed.connect(_on_back_pressed)
	# 著作権者の名前には ó・ø・Å などが入るが、同梱フォント(M PLUS Rounded 1c)は
	# JIS 第一水準のサブセットで欧文の補助文字を持たない。Web 版にはシステムフォントの
	# 代替も無いので、エンジン既定のフォント(欧文の補助文字を持つ)を代替に足す
	var fv := FontVariation.new()
	fv.base_font = get_theme_default_font()
	fv.fallbacks = [ThemeDB.fallback_font]
	body.add_theme_font_override("normal_font", fv)
	# 利用者の入力ではないが、ライセンス本文が en.po の msgid と一致して訳されるのを防ぐ
	body.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	body.text = build_text()


func build_text() -> String:
	var parts := PackedStringArray()
	parts.append("%s\nVer %s\n" % [tr("逆転鬼ごっこ"), str(ProjectSettings.get_setting("application/config/version", ""))])
	var third_party := FileAccess.get_file_as_string(THIRD_PARTY_PATH)
	if third_party.is_empty():
		# 書き出しで include_filter から漏れたときに気付けるよう、黙って空にしない
		push_error("credits_screen: %s を読めない（export_presets.cfg の include_filter を確認）" % THIRD_PARTY_PATH)
	else:
		parts.append(third_party)
	parts.append(godot_notice_text())
	return "\n".join(parts)


## Godot 本体と同梱ライブラリの著作権表示とライセンス本文。
## licenses/GODOT_LICENSES.txt はこの戻り値をそのまま書き出したもの（tests/test_licenses.tscn）。
## 英語だけで書くのは、配布フォルダのテキストファイルとしても使うため（ここは tr() を通さない）
static func godot_notice_text() -> String:
	var v := Engine.get_version_info()
	var lines := PackedStringArray()
	var rule := "=".repeat(80)
	lines.append(rule)
	lines.append("Godot Engine %s - third-party components and license texts" % v["string"])
	lines.append(rule)
	lines.append("")
	lines.append("Generated from Engine.get_copyright_info() and Engine.get_license_info().")
	lines.append("")
	for c in Engine.get_copyright_info():
		lines.append("- %s" % c["name"])
		for p in c["parts"]:
			lines.append("    License: %s" % p["license"])
			for holder in p["copyright"]:
				lines.append("    Copyright: %s" % holder)
		lines.append("")
	var licenses: Dictionary = Engine.get_license_info()
	var names: Array = licenses.keys()
	names.sort()
	for n in names:
		lines.append(rule)
		lines.append("License: %s" % n)
		lines.append(rule)
		lines.append("")
		lines.append(str(licenses[n]).strip_edges())
		lines.append("")
	return "\n".join(lines)


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(TITLE_SCENE)
