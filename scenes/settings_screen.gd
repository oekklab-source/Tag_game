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
@onready var reset_btn: Button = $ContentMargin/Scroll/MainVBox/ButtonsRow/ResetButton
@onready var save_btn: Button = $ContentMargin/Scroll/MainVBox/ButtonsRow/SaveButton

## _refresh_sliders() でスライダーの値をSettingsManagerに合わせて書き戻す間、
## value_changed経由でSettingsManager.set_*()を再度呼んでしまうのを防ぐガード
var _syncing := false

## OptionButtonのitem index ⇔ SettingsManager.touch_controls_mode の対応。
## room_match_dialog.gdのTierFilterと同じ「_ready()でadd_item、選択後はindexで引く」方式
const TOUCH_MODE_VALUES := ["auto", "on", "off"]
const TOUCH_MODE_LABELS := ["自動", "常に表示", "常に非表示"]


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
	reset_btn.pressed.connect(_on_reset_pressed)
	save_btn.pressed.connect(_on_save_pressed)
	_refresh_sliders()
	_refresh_touch_mode()


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


func _on_reset_pressed() -> void:
	SettingsManager.set_mouse_sensitivity(SettingsManager.DEFAULT_MOUSE_SENSITIVITY)
	SettingsManager.set_master_volume(SettingsManager.DEFAULT_MASTER_VOLUME)
	SettingsManager.set_touch_controls_mode(SettingsManager.DEFAULT_TOUCH_CONTROLS_MODE)
	SettingsManager.save_settings()
	_refresh_sliders()
	_refresh_touch_mode()


func _on_save_pressed() -> void:
	SettingsManager.save_settings()
	if get_tree().current_scene == self:
		get_tree().change_scene_to_file(TITLE_SCENE)
	else:
		closed.emit()
