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
## URL の ?s= による自動参加は1回だけ。接続失敗時は leave() が main.tscn へ戻すので、
## ガードが無いと同じアドレスへ無限に再接続しに行く
var auto_join_done := false


func _ready() -> void:
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_apply_cmdline()


## 動作確認用。`-- client <addr>` を付けて world.tscn を直接起動するとロビーを飛ばす。
## ホストは world.gd 側で mode == NONE をホスト扱いするので指定不要。
##   godot --headless --path . res://scenes/world.tscn
##   godot --headless --path . res://scenes/world.tscn -- client 127.0.0.1
func _apply_cmdline() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("client")
	if i < 0:
		return
	mode = Mode.CLIENT
	if i + 1 < args.size():
		join_address = args[i + 1]


func start_host() -> void:
	mode = Mode.HOST
	get_tree().change_scene_to_file(WORLD_SCENE)


func start_client(address: String) -> void:
	mode = Mode.CLIENT
	join_address = address
	get_tree().change_scene_to_file(WORLD_SCENE)


## 入力されたアドレスを接続先 URL にする。
##
## LAN の IP は従来どおり平文の ws://IP:9999。ホスト名が来た場合は
## トンネル（Cloudflare 等）経由とみなして wss://host（443）にする。
## https で配信された Web ビルドからは ws:// が mixed content でブロックされるため、
## 外部公開の経路は必ず wss でなければならない。
func resolve_url(addr: String) -> String:
	if addr.begins_with("ws://") or addr.begins_with("wss://"):
		return addr
	var host := addr
	var port := PORT
	var colon := addr.rfind(":")
	if colon > 0:
		host = addr.substr(0, colon)
		port = addr.substr(colon + 1).to_int()
	if host == "localhost" or host.is_valid_ip_address():
		return "ws://%s:%d" % [host, port]
	return "wss://%s" % host


## world._ready() から呼ばれ、実際にピアを生成する。
func setup_peer() -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	var err: Error
	if mode == Mode.HOST:
		err = peer.create_server(PORT)
	else:
		err = peer.create_client(resolve_url(join_address))
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
