extends Control

## H-07: 設定画面（専用シーン、shop_screen.gd/costume_screen.gdと同じ画面遷移方式の二役構造）。
## マウス感度・マスター音量（SettingsManager）を調整する。まだBGM/SEが実装されていないため
## 音量スライダーは見た目上の効果が無いが、SettingsManagerがAudioServerへは反映済みなので
## 音源実装時にそのまま効くようになる。

const TITLE_SCENE := "res://scenes/title.tscn"

## hud.gdがオーバーレイとして埋め込んだ場合に、閉じる操作の代わりに発火する。
## タイトルから専用シーンとして開かれた場合(get_tree().current_scene == self)は
## 従来通りタイトルへのシーン遷移を行うため、その場合は発火しない
## (現時点ではhud.gd側の呼び出し口は未配線。将来1行足すだけで開けるようにするための下地)
signal closed

@onready var sensitivity_slider: HSlider = $ContentMargin/Scroll/MainVBox/SensitivitySection/Row/Slider
@onready var sensitivity_value_label: Label = $ContentMargin/Scroll/MainVBox/SensitivitySection/Row/ValueLabel
@onready var volume_slider: HSlider = $ContentMargin/Scroll/MainVBox/VolumeSection/Row/Slider
@onready var volume_value_label: Label = $ContentMargin/Scroll/MainVBox/VolumeSection/Row/ValueLabel
@onready var touch_mode_option: OptionButton = $ContentMargin/Scroll/MainVBox/TouchSection/Row/ModeOption
@onready var language_option: OptionButton = $ContentMargin/Scroll/MainVBox/LanguageSection/Row/LanguageOption
@onready var text_size_option: OptionButton = $ContentMargin/Scroll/MainVBox/TextSizeSection/Row/TextSizeOption
@onready var reset_btn: Button = $ContentMargin/Scroll/MainVBox/ButtonsRow/ResetButton
@onready var save_btn: Button = $ContentMargin/Scroll/MainVBox/ButtonsRow/SaveButton
@onready var support_version_label: Label = $ContentMargin/Scroll/MainVBox/SupportSection/VersionLabel
@onready var support_contact_label: Label = $ContentMargin/Scroll/MainVBox/SupportSection/ContactLabel
@onready var support_hint_label: Label = $ContentMargin/Scroll/MainVBox/SupportSection/HintLabel
@onready var log_path_label: Label = $ContentMargin/Scroll/MainVBox/SupportSection/LogPathLabel
@onready var open_logs_btn: Button = $ContentMargin/Scroll/MainVBox/SupportSection/OpenLogsButton

## _refresh_sliders() でスライダーの値をSettingsManagerに合わせて書き戻す間、
## value_changed経由でSettingsManager.set_*()を再度呼んでしまうのを防ぐガード
var _syncing := false

## OptionButtonのitem index ⇔ SettingsManager.touch_controls_mode の対応。
## room_match_dialog.gdのTierFilterと同じ「_ready()でadd_item、選択後はindexで引く」方式
const TOUCH_MODE_VALUES := ["auto", "on", "off"]
const TOUCH_MODE_LABELS := ["自動", "常に表示", "常に非表示"]
## L-09: 言語の選択肢。"自動"だけは表示言語に合わせて訳すが、言語名は
## 「今読めない言語の画面からでも自分の言語を探せる」ように各言語の自称で固定する
## (en.po に msgid を置かないので、OptionButton の自動翻訳を通っても変わらない)
const LANGUAGE_VALUES := ["auto", "ja", "en"]
const LANGUAGE_LABELS := ["自動", "日本語", "English"]
## L-10: 文字サイズ(倍率は SettingsManager.TEXT_SIZE_SCALES)
const TEXT_SIZE_VALUES := ["normal", "large", "xlarge"]
const TEXT_SIZE_LABELS := ["標準", "大", "特大"]

## KAN-71: ユーザーからの問い合わせ窓口（KAN-14 でオーナーが決めた公開用アドレス。
## EULA 第12条・プライバシーポリシー第13条・ストアページと同じ値にそろえること）。
## クラッシュやエラーを自動で集める仕組みは無いので、報告にはここで案内する
## 版数とログのファイルが再現の唯一の手掛かりになる
const SUPPORT_EMAIL := "yuya.hamaguchi@solpinto.jp"
## Godot の既定のログの出力先。プロジェクト設定で変えていればそちらを使う
const DEFAULT_LOG_PATH := "user://logs/godot.log"


func _ready() -> void:
	sensitivity_slider.min_value = SettingsManager.MOUSE_SENSITIVITY_MIN
	sensitivity_slider.max_value = SettingsManager.MOUSE_SENSITIVITY_MAX
	sensitivity_slider.value_changed.connect(_on_sensitivity_changed)
	sensitivity_slider.drag_ended.connect(_on_sensitivity_drag_ended)
	volume_slider.value_changed.connect(_on_volume_changed)
	volume_slider.drag_ended.connect(_on_volume_drag_ended)
	for label in TOUCH_MODE_LABELS:
		touch_mode_option.add_item(label)
	touch_mode_option.item_selected.connect(_on_touch_mode_selected)
	for label in LANGUAGE_LABELS:
		language_option.add_item(label)
	language_option.item_selected.connect(_on_language_selected)
	for label in TEXT_SIZE_LABELS:
		text_size_option.add_item(label)
	text_size_option.item_selected.connect(_on_text_size_selected)
	reset_btn.pressed.connect(_on_reset_pressed)
	save_btn.pressed.connect(_on_save_pressed)
	open_logs_btn.pressed.connect(_on_open_logs_pressed)
	_refresh_sliders()
	_refresh_touch_mode()
	_refresh_language()
	_refresh_text_size()
	_refresh_support()


## 問い合わせ欄の文言はスクリプトで組み立てる(版数・パスを差し込むため)ので、
## .tscn 由来の文言と違って自動では訳し直されない。言語を切り替えたらここで作り直す
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_refresh_support()


func _refresh_sliders() -> void:
	_syncing = true
	sensitivity_slider.value = SettingsManager.mouse_sensitivity
	_update_sensitivity_label(SettingsManager.mouse_sensitivity)
	volume_slider.value = SettingsManager.master_volume
	_update_volume_label(SettingsManager.master_volume)
	_syncing = false


## OptionButton.select()はitem_selectedを再発火しないため、スライダーと違い
## _syncingガードは不要
func _refresh_touch_mode() -> void:
	touch_mode_option.select(maxi(TOUCH_MODE_VALUES.find(SettingsManager.touch_controls_mode), 0))


func _refresh_language() -> void:
	language_option.select(maxi(LANGUAGE_VALUES.find(SettingsManager.language), 0))


func _refresh_text_size() -> void:
	text_size_option.select(maxi(TEXT_SIZE_VALUES.find(SettingsManager.text_size), 0))


## KAN-71: 問い合わせ先・版数・ログの場所。版数はタイトル画面(title.gd、KAN-32)と同じ文言・
## 同じ取り方にして、報告に書かれた版数がどちらの画面から写したものでも同じ形になるようにする
func _refresh_support() -> void:
	support_version_label.text = tr("Ver %s（通信 v%d）") % [
		str(ProjectSettings.get_setting("application/config/version", "")),
		GameManager.PROTOCOL_VERSION,
	]
	support_contact_label.text = tr("お問い合わせ: %s") % SUPPORT_EMAIL
	# Web 版はログをファイルに書かない(ブラウザの中で動くため)。
	# 開けないボタンや存在しない場所は出さず、代わりに環境を書いてもらう
	var has_log_file := not OS.has_feature("web")
	log_path_label.visible = has_log_file
	open_logs_btn.visible = has_log_file
	if has_log_file:
		support_hint_label.text = tr("不具合を報告するときは、上の版数と、下のログのファイル（godot.log）を添えてください")
		log_path_label.text = tr("ログの場所: %s") % log_file_path_for_display()
	else:
		support_hint_label.text = tr("不具合を報告するときは、上の版数と、使っている端末・ブラウザの名前を書いてください")


## ログのファイルの OS 上の絶対パス(テストからも使う)
static func log_file_path() -> String:
	var path := str(ProjectSettings.get_setting("debug/file_logging/log_path", DEFAULT_LOG_PATH))
	return ProjectSettings.globalize_path(path)


## 画面に出す形。Windows では区切りを「\」にして、エクスプローラーのアドレス欄に
## そのまま貼れるようにする(globalize_path は Windows でも「/」で返す)
static func log_file_path_for_display() -> String:
	var path := log_file_path()
	return path.replace("/", "\\") if OS.has_feature("windows") else path


func _on_open_logs_pressed() -> void:
	var dir := log_file_path().get_base_dir()
	# 起動直後などでフォルダがまだ無いと、エクスプローラーが「見つからない」と出すだけになる
	DirAccess.make_dir_recursive_absolute(dir)
	OS.shell_open(dir)


func _update_sensitivity_label(value: float) -> void:
	sensitivity_value_label.text = "×%.2f" % (value / SettingsManager.DEFAULT_MOUSE_SENSITIVITY)


func _update_volume_label(value: float) -> void:
	volume_value_label.text = "%d%%" % roundi(value * 100.0)


func _on_sensitivity_changed(value: float) -> void:
	if _syncing:
		return
	SettingsManager.set_mouse_sensitivity(value)
	_update_sensitivity_label(value)


## スライダーを離した時だけディスクへ保存する（value_changedのたびに保存すると
## ドラッグ中に大量のファイルI/Oが走るため）
func _on_sensitivity_drag_ended(_value_changed: bool) -> void:
	SettingsManager.save_settings()


func _on_volume_changed(value: float) -> void:
	if _syncing:
		return
	SettingsManager.set_master_volume(value)
	_update_volume_label(value)


func _on_volume_drag_ended(_value_changed: bool) -> void:
	SettingsManager.save_settings()


## OptionButtonにはスライダーのdrag_endedに相当する中間状態が無いので、選択直後に即保存する
func _on_touch_mode_selected(index: int) -> void:
	SettingsManager.set_touch_controls_mode(TOUCH_MODE_VALUES[index])
	SettingsManager.save_settings()


## タッチ操作と同じく即保存する。画面の作り直しは要らない: この画面の文言は
## .tscn 由来(auto_translate)と OptionButton の項目がほとんどで、どちらもロケール変更の
## 通知でその場で訳し直される(数値ラベルは言語に依存しない)。スクリプトで組み立てる
## 問い合わせ欄だけは _notification() で作り直す
func _on_language_selected(index: int) -> void:
	SettingsManager.set_language(LANGUAGE_VALUES[index])
	SettingsManager.save_settings()


## 言語と同じく即保存する。選んだ瞬間にこの画面も含めて全体が拡大・縮小されるが、
## 中身は ScrollContainer に入っているので、特大で縦にはみ出しても操作できる
func _on_text_size_selected(index: int) -> void:
	SettingsManager.set_text_size(TEXT_SIZE_VALUES[index])
	SettingsManager.save_settings()


func _on_reset_pressed() -> void:
	SettingsManager.set_mouse_sensitivity(SettingsManager.DEFAULT_MOUSE_SENSITIVITY)
	SettingsManager.set_master_volume(SettingsManager.DEFAULT_MASTER_VOLUME)
	SettingsManager.set_touch_controls_mode(SettingsManager.DEFAULT_TOUCH_CONTROLS_MODE)
	SettingsManager.set_language(SettingsManager.DEFAULT_LANGUAGE)
	SettingsManager.set_text_size(SettingsManager.DEFAULT_TEXT_SIZE)
	SettingsManager.save_settings()
	_refresh_sliders()
	_refresh_touch_mode()
	_refresh_language()
	_refresh_text_size()


func _on_save_pressed() -> void:
	SettingsManager.save_settings()
	if get_tree().current_scene == self:
		get_tree().change_scene_to_file(TITLE_SCENE)
	else:
		closed.emit()
