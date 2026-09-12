extends CanvasLayer

## ⑨ホストマイグレーション中に表示する簡易オーバーレイ。
## NetworkManagerがget_tree().root直下に動的追加する想定
## (マイグレーション中にworld.tscnごと作り直されても道連れで消えないため)。

@onready var label: Label = $ColorRect/Label


func _ready() -> void:
	if not NetworkManager.migration_status_changed.is_connected(set_text):
		NetworkManager.migration_status_changed.connect(set_text)


func set_text(text: String) -> void:
	label.text = text


func _exit_tree() -> void:
	if NetworkManager.migration_status_changed.is_connected(set_text):
		NetworkManager.migration_status_changed.disconnect(set_text)
