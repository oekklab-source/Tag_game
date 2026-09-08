extends Node

## ローカルなプレイヤー設定（ニックネームのみ）。user://settings.cfg に保存する。

const CONFIG_PATH := "user://settings.cfg"
const SECTION := "player"
const KEY := "nickname"
const MAX_LEN := 12

var nickname := ""


func _ready() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	nickname = String(cfg.get_value(SECTION, KEY, ""))
	if nickname.is_empty():
		nickname = _default_nickname()


func set_nickname(raw: String) -> void:
	var trimmed := raw.strip_edges().left(MAX_LEN)
	nickname = trimmed if not trimmed.is_empty() else _default_nickname()
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	cfg.set_value(SECTION, KEY, nickname)
	cfg.save(CONFIG_PATH)


func _default_nickname() -> String:
	return "プレイヤー%d" % (randi() % 1000)
