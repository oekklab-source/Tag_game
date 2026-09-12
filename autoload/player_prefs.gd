extends Node

## ローカルなプレイヤー設定（ニックネームと着せ替え）。user://settings.cfg に保存する。

const CONFIG_PATH := "user://settings.cfg"
const SECTION := "player"
const KEY := "nickname"
const SKIN_KEY := "skin"
const MAX_LEN := 12

var nickname := ""
## Humanoid.SKINS の添字。範囲外の保存値は読み込み時に 0 へ丸める
var skin := 0


func _ready() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	nickname = String(cfg.get_value(SECTION, KEY, ""))
	if nickname.is_empty():
		nickname = _default_nickname()
	skin = _clamp_skin(int(cfg.get_value(SECTION, SKIN_KEY, 0)))


func set_nickname(raw: String) -> void:
	var trimmed := raw.strip_edges().left(MAX_LEN)
	nickname = trimmed if not trimmed.is_empty() else _default_nickname()
	_save(KEY, nickname)


func set_skin(id: int) -> void:
	skin = _clamp_skin(id)
	_save(SKIN_KEY, skin)


## スキンの一覧は Humanoid が持つ。設定ファイルに古い/壊れた値が入っていても
## 落ちないよう、読み込み時と保存時の両方でここを通す
func _clamp_skin(id: int) -> int:
	return id if id >= 0 and id < Humanoid.SKINS.size() else 0


func _save(key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	cfg.set_value(SECTION, key, value)
	cfg.save(CONFIG_PATH)


func _default_nickname() -> String:
	return "プレイヤー%d" % (randi() % 1000)
