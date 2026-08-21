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
## tools/serve.ps1（トンネル）の PID。同一セッションで再ホストしても二重起動しないための記録
var _tunnel_pid := -1


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


## ホストを始める。始められなければ false を返し、理由は last_error に入れる。
##
## ポートが空いているかを**シーンを移る前に**確かめるのが肝。
## world.tscn へ移ってから create_server に失敗すると、画面はゲームなのに
## 誰ともつながらない状態になる。しかも前回の Godot が生きたまま 9999 を
## 掴んでいるので、配った参加リンクは**その古いホスト**につながってしまい、
## 「参加者からは begin しない・こちらの操作が届かない」という
## 極めて分かりにくい症状になる（実際にこれで詰まった）。
func start_host() -> bool:
	var probe := TCPServer.new()
	var err := probe.listen(PORT)
	probe.stop()
	if err != OK:
		last_error = ("ポート %d が既に使われています。
"
			+ "前に起動した Godot（ゲーム）が残っていないか確認して、閉じてから試してください。") % PORT
		return false
	mode = Mode.HOST
	get_tree().change_scene_to_file(WORLD_SCENE)
	return true


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
		if mode == Mode.HOST:
			last_error = ("ポート %d で待ち受けられませんでした。
"
				+ "前に起動した Godot（ゲーム）が残っていないか確認してください。") % PORT
		else:
			last_error = "通信を開始できませんでした（エラー %d）" % err
		# ここは world.tscn の _ready() の途中。その場でシーンを差し替えると
		# 「Parent node is busy adding/removing children」で失敗し、
		# タイトルにも戻れない半端な状態のまま残る
		leave.call_deferred()
		return err
	multiplayer.multiplayer_peer = peer
	if mode == Mode.HOST:
		_launch_tunnel()
	return OK


## HOST 開始と同時に Cloudflare Tunnel を張って参加リンクを作る（tools/serve.ps1）。
## そのスクリプトは Get-NetTCPConnection / Set-Clipboard など Windows PowerShell 前提なので
## Windows デスクトップ版でのみ起動する。同一プロセス内で再ホストしても、前のトンネルが
## まだ生きていれば張り直さない（cloudflare 側のサブドメインが変わって混乱するのを防ぐ）
func _launch_tunnel() -> void:
	if OS.has_feature("web") or OS.get_name() != "Windows":
		return
	# ヘッドレス（テストや CI）ではトンネルを張らない。
	# ここを塞がないと tests/ でホストを起こすたびに公開トンネルが増え、
	# 実行が終わっても cloudflared が residual プロセスとして残り続ける
	if DisplayServer.get_name() == "headless":
		return
	if _tunnel_pid != -1 and OS.is_process_running(_tunnel_pid):
		return
	var script_path := ProjectSettings.globalize_path("res://tools/serve.ps1")
	# create_process は PID をそのまま返す（失敗時 -1）。辞書ではない
	_tunnel_pid = OS.create_process("pwsh", ["-NoProfile", "-File", script_path], true)


func leave() -> void:
	mode = Mode.NONE
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	GameManager.reset()
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_connection_failed() -> void:
	last_error = "ホストに接続できませんでした"
	leave()


func _on_server_disconnected() -> void:
	last_error = "ホストとの接続が切れました"
	leave()
