extends Node3D

## ゲーム本体シーン。ピアの生成、プレイヤーのスポーン/デスポーンを担当する。
## クライアントはこのシーンを読み込んでから接続するため、
## MultiplayerSpawner のレプリケーションを取りこぼさない。

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const CPU_SCENE := preload("res://scenes/cpu_hunter.tscn")
const BANANA_SCENE := preload("res://scenes/gimmicks/banana.tscn")
const BLOCK_SCENE := preload("res://scenes/gimmicks/placed_block.tscn")
const INITIAL_SPAWN_RADIUS := 6.0
## 黄金角。連番で回すと、何人目でも既存の湧き点から最も離れた角度になる
const SPAWN_ANGLE_STEP := 2.39996
## 既存のキャラとこれ以上離れていれば湧いてよい（カプセル直径 0.7 の3倍弱）
const SPAWN_MIN_GAP := 2.0
## 混み合ったとき外側のリングへ逃がす幅。world_builder の SPAWN_CLEARANCE(10.0) と
## CORRIDOR_HALF(9.0) の内側に収めるので、遮蔽ブロックの中に湧くことはない
const SPAWN_RING_STEP := 1.5

var _cpu_counter := 0
var _drop_counter := 0
var _spawn_slot := 0

@onready var players: Node3D = $Players
@onready var nav_region: NavigationRegion3D = $NavRegion
@onready var map: Node3D = $NavRegion/Map
@onready var gimmicks: Node3D = $NavRegion/Gimmicks
@onready var decor: Node3D = $Decor
@onready var items: Node3D = $Items


func _ready() -> void:
	# マップは全ピアが同じテーブルから構築する（形状はベイクより先に存在させる）
	WorldBuilder.build(map, gimmicks, decor)
	if NetworkManager.mode == NetworkManager.Mode.NONE:
		# エディタから world.tscn を直接実行した場合はホストとして動かす
		NetworkManager.mode = NetworkManager.Mode.HOST
	if NetworkManager.setup_peer() != OK:
		return
	if multiplayer.is_server():
		# CPU 鬼の経路探索用ナビメッシュはホスト側でのみ必要
		var t0 := Time.get_ticks_msec()
		nav_region.bake_finished.connect(
			func() -> void: print("navmesh bake: %d ms" % (Time.get_ticks_msec() - t0)),
			CONNECT_ONE_SHOT)
		nav_region.bake_navigation_mesh()
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		_spawn_player(1)
		GameManager.broadcast_my_profile()
	else:
		# ②④ 接続が確立してから自分のプロフィール（レート/ティア/コスチューム）を
		# ホストへ報告する。setup_peer() 直後はまだハンドシェイク中のことがあるため待つ。
		# multiplayer は world.tscn を跨いで生き続ける SceneTree 側のオブジェクトなので、
		# ONE_SHOT にしないと再入室のたびに接続が積み重なってしまう
		multiplayer.connected_to_server.connect(
			func(): GameManager.broadcast_my_profile(), CONNECT_ONE_SHOT)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("start_round") and multiplayer.is_server():
		GameManager.request_start_round()
	elif event.is_action_pressed("toggle_role"):
		# 役割の立候補は全ピアができる（逃走者の枠は1つなので奪い合いになる）
		GameManager.toggle_my_role()
	elif event.is_action_pressed("cycle_runner") and multiplayer.is_server():
		GameManager.cycle_wanted_runner()


func _on_peer_connected(id: int) -> void:
	# 版数の照合が最初。食い違ったまま進むと「つながっているのに同期しない」になる
	GameManager.begin_version_check(id)
	var pos := _spawn_player(id)
	# 選んだ湧き位置は本人にだけ RPC で伝える（理由は _spawn_player を参照）
	GameManager.place_player.rpc_id(id, pos)
	GameManager.sync_to_peer(id)


func _on_peer_disconnected(id: int) -> void:
	var p := players.get_node_or_null(str(id))
	if p:
		p.queue_free()
	GameManager.on_player_left(id)


## 湧き位置を決めてプレイヤーを生成し、その座標を返す。
##
## sync_position を add_child より前に入れるのは、MultiplayerSpawner の
## スポーン状態に乗せて**他ピアから見た位置**を正しくするため。
## ただしスポーン状態は「送り手が権威を持つ同期ノード」の分しか配られず、
## プレイヤーの権威は本人にあるので、**本人にだけはこの座標が届かない**
## （本人の画面では原点に出る = 先に居た人と重なる）。
## そのため呼び出し側が place_player でもう一度本人へ伝える。
func _spawn_player(id: int) -> Vector3:
	var player: CharacterBody3D = PLAYER_SCENE.instantiate()
	player.name = str(id)
	player.position = _free_spawn_point()
	player.sync_position = player.position
	players.add_child(player)
	return player.position


## 既存のキャラと重ならない湧き位置。
##
## 重なったまま出すと CharacterBody3D 同士は move_and_slide() で押し合えないため、
## 横に重なれば楔状に固まって動けず、相手の頭に乗れば接地扱いで重力が止まり
## 空中に浮いたままになる（CharacterSeparation はその保険であって、
## そもそも重ねないのがここの仕事）。
func _free_spawn_point() -> Vector3:
	var p := Vector3.ZERO
	for attempt in 16:
		var angle := _spawn_slot * SPAWN_ANGLE_STEP
		var radius := INITIAL_SPAWN_RADIUS + float(attempt / 8) * SPAWN_RING_STEP
		_spawn_slot += 1
		# 地面の高さがゾーンごとに違うため、高めから落として着地させる
		p = Vector3(cos(angle) * radius, 4.0, sin(angle) * radius)
		if _is_clear(p):
			break
	return p


func _is_clear(p: Vector3) -> bool:
	for n in players.get_children():
		if Vector2(n.position.x - p.x, n.position.z - p.z).length() < SPAWN_MIN_GAP:
			return false
	return true


## プレイヤーの置きアイテム。GameManager.request_drop（ホスト）から呼ばれる
func spawn_dropped_item(kind: int, pos: Vector3, yaw: float) -> void:
	_drop_counter += 1
	var scene := BANANA_SCENE if kind == Player.Item.BANANA else BLOCK_SCENE
	var n: Node3D = scene.instantiate()
	n.name = "Drop%d" % _drop_counter
	n.position = pos
	n.rotation.y = yaw
	items.add_child(n)


## ソロモード時に GameManager（ホスト）から呼ばれる
func spawn_cpu_hunter(pos: Vector3) -> void:
	_cpu_counter += 1
	var cpu: CharacterBody3D = CPU_SCENE.instantiate()
	cpu.name = "CPU%d" % _cpu_counter
	cpu.position = pos
	cpu.sync_position = pos
	players.add_child(cpu)
