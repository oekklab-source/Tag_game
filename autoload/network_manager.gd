extends Node

## WebSocket 接続の確立と切断処理を担当する Autoload。
## クライアントは world シーンを読み込んでから接続する
## （MultiplayerSpawner のスポーン通知を取りこぼさないため）。

enum Mode { NONE, HOST, CLIENT }

const PORT := 9999
const WORLD_SCENE := "res://scenes/world.tscn"
const MAIN_SCENE := "res://scenes/main.tscn"

var mode := Mode.NONE
var join_address := "127.0.0.1"
var last_error := ""


func _ready() -> void:
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func start_host() -> void:
	mode = Mode.HOST
	get_tree().change_scene_to_file(WORLD_SCENE)


func start_client(address: String) -> void:
	mode = Mode.CLIENT
	join_address = address
	get_tree().change_scene_to_file(WORLD_SCENE)


## world._ready() から呼ばれ、実際にピアを生成する。
func setup_peer() -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	var err: Error
	if mode == Mode.HOST:
		err = peer.create_server(PORT)
	else:
		var url := join_address
		if not (url.begins_with("ws://") or url.begins_with("wss://")):
			url = "ws://%s:%d" % [join_address, PORT]
		err = peer.create_client(url)
	if err != OK:
		last_error = "Failed to start network (error %d)" % err
		leave()
		return err
	multiplayer.multiplayer_peer = peer
	return OK


func leave() -> void:
	mode = Mode.NONE
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	GameManager.reset()
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_connection_failed() -> void:
	last_error = "Could not connect to host"
	leave()


func _on_server_disconnected() -> void:
	last_error = "Disconnected from host"
	leave()
