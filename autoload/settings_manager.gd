extends Node

## プレイヤーのローカル設定（マウス感度・マスター音量）を管理・保存する Autoload。
## user://settings.json にローカル保存する。ProfileManager（プロフィール・戦績・課金）とは
## 責務を分離し、クラウド同期は行わない。

const SAVE_PATH := "user://settings.json"
const DEFAULT_MOUSE_SENSITIVITY := 0.003
const DEFAULT_MASTER_VOLUME := 0.8
const MOUSE_SENSITIVITY_MIN := 0.0005
const MOUSE_SENSITIVITY_MAX := 0.01
const DEFAULT_TOUCH_CONTROLS_MODE := "auto"
## _apply_data() でのホワイトリスト検証に使う。順序に意味は無い
const VALID_TOUCH_CONTROLS_MODES := ["auto", "on", "off"]
## L-09: 表示言語。"auto" は OS(Web版ならブラウザ)の言語が日本語なら日本語、それ以外は英語。
## 翻訳は res://locale/en.po の1枚だけで、msgid は日本語の原文そのもの。
## project.godot の locale/fallback は "ja"(=原文を返す)にしてある。"en" にすると、
## Godot はロケール ja の訳が無い文字列を fallback で訳すため、日本語環境でも全部英語になる
## (実測)。そのため「日本語以外なら英語」は fallback に頼らず resolve_locale() で明示的に決める
const DEFAULT_LANGUAGE := "auto"
const VALID_LANGUAGES := ["auto", "ja", "en"]

var mouse_sensitivity: float = DEFAULT_MOUSE_SENSITIVITY
var master_volume: float = DEFAULT_MASTER_VOLUME
var touch_controls_mode: String = DEFAULT_TOUCH_CONTROLS_MODE
var language: String = DEFAULT_LANGUAGE


func _ready() -> void:
	load_settings()
	apply_master_volume()  # 起動直後からMasterバスに反映しておく
	apply_language()


## メモリへの反映のみ。ディスクへの保存は呼び出し側の責務
## （スライダーのdrag_ended、画面離脱時など、連打のたびにI/Oさせないため）
func set_mouse_sensitivity(v: float) -> void:
	mouse_sensitivity = v


## メモリへの反映と同時にMasterバスへ即座に反映する（保存はしない）
func set_master_volume(v: float) -> void:
	master_volume = v
	apply_master_volume()


## master_volume の現在値をMasterバスへ反映する。0はミュートとして扱う
## (linear_to_db(0.0) は -inf になり AudioServer.set_bus_volume_db() に渡すと危険なため)
func apply_master_volume() -> void:
	var bus := AudioServer.get_bus_index("Master")
	if bus == -1:
		return
	AudioServer.set_bus_mute(bus, master_volume <= 0.0001)
	if master_volume > 0.0001:
		AudioServer.set_bus_volume_db(bus, linear_to_db(master_volume))


## メモリへの反映のみ。ディスクへの保存は呼び出し側の責務
## (settings_screen.gd の OptionButton.item_selected で即座に save_settings() する。
## ドラッグ中の連打が無いのでスライダーのような drag_ended 待ちは不要)
func set_touch_controls_mode(v: String) -> void:
	touch_controls_mode = v


## メモリへの反映と同時にロケールへ即座に反映する（保存はしない）。
## .tscn 由来の文言(auto_translate)はロケール変更の通知でその場で切り替わる
func set_language(v: String) -> void:
	language = v
	apply_language()


## language の現在値を TranslationServer へ反映する
func apply_language() -> void:
	TranslationServer.set_locale(resolve_locale(language, OS.get_locale_language()))


## 設定値と OS の言語コード("ja" / "en" / "fr" 等)から、実際に使うロケールを決める
## (純粋関数、tests/test_i18n.gd で直接検証)
static func resolve_locale(lang: String, os_language: String) -> String:
	if lang != "auto":
		return lang
	return "ja" if os_language == "ja" else "en"


## タッチ操作UIを表示すべきか。"on"/"off"は明示的な上書き、"auto"(既定)は
## DisplayServer.is_touchscreen_available()に従う(プラットフォーム非依存。Web版の
## 「スマホでブラウザから遊ぶ」を主眼に最適化しており、Windows Desktopでの
## タッチノートPC体験の作り込みはC-07のスコープ外)
func should_show_touch_controls() -> bool:
	match touch_controls_mode:
		"on":
			return true
		"off":
			return false
		_:
			return DisplayServer.is_touchscreen_available()


## 現在の設定状態を保存用Dictionaryに変換する(ファイルI/Oを含まない)
func to_save_dict() -> Dictionary:
	return {
		"mouse_sensitivity": mouse_sensitivity,
		"master_volume": master_volume,
		"touch_controls_mode": touch_controls_mode,
		"language": language,
	}


## 設定の保存
func save_settings() -> void:
	var data := to_save_dict()
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))


## 設定の読み込み
func load_settings() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if file:
			var text := file.get_as_text()
			var json := JSON.new()
			if json.parse(text) == OK and typeof(json.data) == TYPE_DICTIONARY:
				_apply_data(json.data)
				return

	# 初回起動時、または破損データ: 既定値のまま保存しておく
	save_settings()


## 読み込んだ JSON 辞書をインスタンス変数へ反映する（ファイルI/Oを含まない純粋な部分）。
## tests/test_phase5_persistence.gd から保存・読込の往復を検証する際にも使う
func _apply_data(data: Dictionary) -> void:
	mouse_sensitivity = clampf(
		float(data.get("mouse_sensitivity", DEFAULT_MOUSE_SENSITIVITY)),
		MOUSE_SENSITIVITY_MIN, MOUSE_SENSITIVITY_MAX)
	master_volume = clampf(float(data.get("master_volume", DEFAULT_MASTER_VOLUME)), 0.0, 1.0)
	# 文字列フィールド初のホワイトリスト検証。不正値/未知の文字列/欠損キーはすべて既定"auto"へ
	var touch_mode := String(data.get("touch_controls_mode", DEFAULT_TOUCH_CONTROLS_MODE))
	touch_controls_mode = (
		touch_mode if VALID_TOUCH_CONTROLS_MODES.has(touch_mode) else DEFAULT_TOUCH_CONTROLS_MODE)
	var lang := String(data.get("language", DEFAULT_LANGUAGE))
	language = lang if VALID_LANGUAGES.has(lang) else DEFAULT_LANGUAGE
