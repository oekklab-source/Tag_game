@tool
extends EditorPlugin

## 書き出しガード（export_guard.gd）を登録するだけのエディタプラグイン。
## 第三者製の addons/epic-online-services-godot/ には手を入れないため、別プラグインにしてある。
##
## _enable_plugin() ではなく _enter_tree() で登録するのは、エディタ起動のたび
## （および --headless --export-release の CLI 書き出しのたび）に確実に登録されるようにするため。
## _enable_plugin() はプラグインを有効化した瞬間の1回しか呼ばれない。

var _export_guard: EditorExportPlugin = null


func _enter_tree() -> void:
	_export_guard = preload("res://addons/tag_game_export_guard/export_guard.gd").new()
	add_export_plugin(_export_guard)


func _exit_tree() -> void:
	if _export_guard != null:
		remove_export_plugin(_export_guard)
		_export_guard = null
