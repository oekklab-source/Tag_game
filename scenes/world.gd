extends Node3D

## ゲーム本体シーン。ピアの生成、プレイヤーのスポーン/デスポーンを担当する。
## クライアントはこのシーンを読み込んでから接続するため、
## MultiplayerSpawner のレプリケーションを取りこぼさない。

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const CPU_SCENE := preload("res://scenes/cpu_hunter.tscn")
const INITIAL_SPAWN_RADIUS := 6.0

var _cpu_counter := 0

@onready var players: Node3D = $Players
@onready var nav_region: NavigationRegion3D = $NavRegion


func _ready() -> void:
	if NetworkManager.mode == NetworkManager.Mode.NONE:
		# エディタから world.tscn を直接実行した場合はホストとして動かす
		NetworkManager.mode = NetworkManager.Mode.HOST
	if NetworkManager.setup_peer() != OK:
		return
	if multiplayer.is_server():
		# CPU 鬼の経路探索用ナビメッシュはホスト側でのみ必要
		nav_region.bake_navigation_mesh()
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		_spawn_player(1)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("start_round") and multiplayer.is_server():
		GameManager.request_start_round()


func _on_peer_connected(id: int) -> void:
	_spawn_player(id)
	GameManager.sync_to_peer(id)


func _on_peer_disconnected(id: int) -> void:
	var p := players.get_node_or_null(str(id))
	if p:
		p.queue_free()
	GameManager.on_player_left(id)


func _spawn_player(id: int) -> void:
	var player: CharacterBody3D = PLAYER_SCENE.instantiate()
	player.name = str(id)
	var angle := randf() * TAU
	player.position = Vector3(cos(angle), 0, sin(angle)) * INITIAL_SPAWN_RADIUS + Vector3.UP
	players.add_child(player)


## ソロモード時に GameManager（ホスト）から呼ばれる
func spawn_cpu_hunter(pos: Vector3) -> void:
	_cpu_counter += 1
	var cpu: CharacterBody3D = CPU_SCENE.instantiate()
	cpu.name = "CPU%d" % _cpu_counter
	cpu.position = pos
	players.add_child(cpu)
