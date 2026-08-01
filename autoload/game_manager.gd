extends Node

## ゲーム進行を管理する Autoload。
## 役割抽選・鬼の速度補正・タイマー・タッチ判定はすべてホスト側で実行し、
## 結果を RPC で全ピアへ配信する。

## HUD の演出（役割バッジのポップイン等）はエッジ検出が必要なので、
## 毎フレームのポーリングではなく状態遷移を通知する
signal state_changed(new_state: int)
## 「今 誰かに見られている」の変化。HUD のバナーはエッジで駆動する
signal spotted_changed(is_spotted: bool)

enum State { WAITING, PLAYING, RESULT }

## 索敵が視界のみになり「見つかる -> 追われる」が本番になったので、
## 以前 150 に縮めた分を戻す。5〜6体で全域を一度掃くのに実効110秒ほどかかる
const ROUND_TIME := 180.0
const RESULT_TIME := 5.0
## 「見えないこと」自体がヘッドスタートになったので、初期位置を離れる分で足りる。
## 8秒 ≒ 69m（約1.3ゾーン分）
const HEAD_START := 8.0
## 探索速度に線形に効く最大のレバー。きつすぎると感じたらまずここを 5 に戻す
const SOLO_CPU_COUNT := 6
const RUNNER_SPAWN := Vector3(0, 2, 0)
## 鬼のスポーンゾーン（辺 -> 角の順）。広いマップでは逃走者の周囲に固めるより
## ゾーン中心に散らした方がマップ全体を覆えて機能する。中央(4)は逃走者用
const HUNTER_SPAWN_ZONES: Array[int] = [1, 3, 5, 7, 0, 2, 6, 8]
# ゾーンごとに地面の高さが違うため、スポーンは高めから落として着地させる
const HUNTER_SPAWN_HEIGHT := 3.0

## --- 視界（索敵） -------------------------------------------------------
## 鬼は逃走者の位置を既定では一切知らない。誰か一人が「視認」した時だけ、
## 逃走者がいる**ゾーン**が全鬼へ共有される。

## ゾーン幅(53〜54m)よりわずかに短い。ゾーン中心からそのゾーンをほぼ覆えるが、
## 160mマップを見通すことは絶対にできない = 「自分のゾーンか隣接でなければ見えない」
const SIGHT_RANGE := 48.0
## 水平の全角。Camera3D は既定の垂直75°で 16:9 なら水平約107°なので、
## 検出コーンを画面より意図的に狭くしてある（見えていないのに通報される方が悪い）
const SIGHT_FOV_DEG := 100.0
const SIGHT_EYE := 1.5
## 頭と胴。どちらか通れば視認とする。単一レイだと ？ブロック1個で全身が隠れてしまう
const SIGHT_TARGET_Y: Array[float] = [1.55, 0.85]
## World(1) + Platform(8)。Character(2) を含めないので鬼同士や逃走者自身で自己遮蔽しない。
## player.tscn の SpringArm3D.collision_mask と同じ値 = カメラアームが当たる物は視線も遮る
const SIGHT_MASK := 9
const SIGHT_TICK := 0.1     # 10Hz。消費側の REPATH_INTERVAL(0.3) に対して十分速い
const INTEL_TIME := 20.0    # 見失ってからゾーン情報が消えるまで
## 視認が途切れてから spotted を落とすまでの猶予。これが無いと逃走者が柱の陰を
## 横切るだけで 10Hz でばたつき、RPC を撒き散らしバナーも点滅する
const SPOTTED_HOLD := 1.5

var state: int = State.WAITING
var runner_id := -1
var hunter_mult := 1.0
var time_left := ROUND_TIME
var head_start_left := 0.0
var result_text := ""
var result_left := 0.0  # リザルト表示の残り秒（HUD の "Next round in N" 用）
## 動く床・回転床の位相に使う全ピア共通の時計。
## 物理 delta は全ピアで固定値なので、ラウンド開始（reliable RPC）で
## 揃えれば以後もずれない。
var world_time := 0.0

## 索敵の共有状態（全ピアが持つ）
var spotted := false      # 今この瞬間、誰かが視認している
var spotted_zone := -1    # 最後に目撃されたゾーン。-1 = 情報なし
var intel_left := 0.0

var _sight_timer := 0.0
var _seer_ids := {}       # ホスト専用。視認中の鬼の instance_id
var _no_sight_for := 0.0


func reset() -> void:
	state = State.WAITING
	runner_id = -1
	hunter_mult = 1.0
	time_left = ROUND_TIME
	head_start_left = 0.0
	result_text = ""
	_clear_intel()


func _clear_intel() -> void:
	var was := spotted
	spotted = false
	spotted_zone = -1
	intel_left = 0.0
	_seer_ids.clear()
	_no_sight_for = 0.0
	_sight_timer = 0.0
	if was:
		spotted_changed.emit(false)


## マップの色分けエリア判定（レイアウト定義は WorldData に一本化してある）
func zone_at(pos: Vector3) -> int:
	return WorldData.zone_index(pos)


## 鬼の人数に応じた速度補正。広いマップでは鬼が分散するので、
## 以前の 80% のような強い減速は逆効果になる
func hunter_mult_for(hunter_count: int) -> float:
	if hunter_count >= 5:
		return 0.90
	if hunter_count >= 3:
		return 0.95
	return 1.0


func get_speed_mult(peer_id: int) -> float:
	if state == State.PLAYING and peer_id != runner_id:
		return hunter_mult
	return 1.0


func get_runner() -> Node:
	return _find_player(runner_id)


func _find_player(peer_id: int) -> Node:
	for p in get_tree().get_nodes_in_group("players"):
		if p.name == str(peer_id):
			return p
	return null


## --- ホスト側ロジック -------------------------------------------------

func request_start_round() -> void:
	if not multiplayer.is_server() or state == State.PLAYING:
		return
	var players := get_tree().get_nodes_in_group("players")
	if players.is_empty():
		return
	_clear_cpu_hunters()
	var ids: Array[int] = []
	for p in players:
		ids.append(String(p.name).to_int())
	# 1人だけならソロモード: 自分が Runner になり CPU 鬼が追う
	var solo := ids.size() == 1
	var new_runner: int
	var mult := 1.0
	if solo:
		new_runner = ids[0]
	else:
		new_runner = ids.pick_random()
		mult = hunter_mult_for(ids.size() - 1)
	# スポーン位置: Runner は中央ゾーン、Hunter は外周ゾーンの中心に散らす
	var spawns := {}
	spawns[new_runner] = RUNNER_SPAWN
	var i := 0
	for id in ids:
		if id == new_runner:
			continue
		spawns[id] = _hunter_spawn(i)
		i += 1
	_start_round.rpc(new_runner, mult, spawns)
	if solo:
		var world := get_tree().current_scene
		for n in SOLO_CPU_COUNT:
			if world.has_method("spawn_cpu_hunter"):
				world.spawn_cpu_hunter(_hunter_spawn(n))


func _hunter_spawn(i: int) -> Vector3:
	var zone: int = HUNTER_SPAWN_ZONES[i % HUNTER_SPAWN_ZONES.size()]
	return WorldData.zone_center(zone) + Vector3(0, HUNTER_SPAWN_HEIGHT, 0)


func _clear_cpu_hunters() -> void:
	for cpu in get_tree().get_nodes_in_group("cpu_hunters"):
		cpu.queue_free()


func _physics_process(delta: float) -> void:
	world_time += delta  # ギミックの位相用。全ピアで進める
	if not multiplayer.is_server() or state != State.PLAYING:
		return
	# ヘッドスタート中も視認は成立させる（凍っていても目はある）。
	# 検出が視界のみになった分の埋め合わせにもなる
	_update_sight(delta)
	# ヘッドスタート中は鬼が凍結され、本タイマーとタッチ判定は動かない
	if head_start_left > 0.0:
		var prev_head := ceili(head_start_left)
		head_start_left = maxf(head_start_left - delta, 0.0)
		if head_start_left == 0.0 or ceili(head_start_left) != prev_head:
			_sync_head.rpc(head_start_left)
		if head_start_left == 0.0:
			_sweep_tag_overlaps()
		return
	var prev_sec := ceili(time_left)
	time_left -= delta
	if time_left <= 0.0:
		_end_round.rpc("RUNNER WINS!  (survived the round)")
		return
	if ceili(time_left) != prev_sec:
		_sync_time.rpc(time_left)


## --- 視界判定 -----------------------------------------------------------

## hunter が target を「今」見ているか。
##
## 向きは**カメラではなくボディの -Z** を使う。player.gd は rotate_y() でボディ自体を
## 回してピッチだけ SpringArm に渡すため、ボディの -Z が水平の視線方向になる。
## 決定的なのはレプリケーションで、player.tscn は position と rotation だけを同期するので
## サーバは各リモート鬼のヨーを持っている（カメラは同期されない）。
## ヨーをボディから外すとこの仕組みは静かに壊れるので注意。
##
## 上下方向の判定は入れない。段丘マップは高低差が8mあり、垂直コーンや3D距離だと
## CLOUD DECK(地面8m) から CASTLE COURT(0m) を見下ろす時に不可解な false negative が出る。
func can_see(hunter: Node3D, target: Node3D) -> bool:
	if hunter == null or target == null:
		return false
	var to_target := target.global_position - hunter.global_position
	var t2 := Vector2(to_target.x, to_target.z)
	if t2.length() > SIGHT_RANGE:
		return false
	var fwd := -hunter.global_transform.basis.z
	var f2 := Vector2(fwd.x, fwd.z)
	if f2.length_squared() < 1e-6 or t2.length_squared() < 1e-6:
		return false
	if f2.normalized().dot(t2.normalized()) < cos(deg_to_rad(SIGHT_FOV_DEG * 0.5)):
		return false
	# GameManager は Node なので get_world_3d() を持たない。空間は対象ノード側から取る。
	# また intersect_ray は物理フレーム内から呼ぶこと（_process だと flushing エラー）
	var space := hunter.get_world_3d().direct_space_state
	var from := hunter.global_position + Vector3(0, SIGHT_EYE, 0)
	for y in SIGHT_TARGET_Y:
		var q := PhysicsRayQueryParameters3D.create(
			from, target.global_position + Vector3(0, y, 0), SIGHT_MASK)
		if space.intersect_ray(q).is_empty():
			return true
	return false


## CPU が「自分は見えているか」を問い合わせる窓口。
## CPU 側で個別にレイを飛ばさせず、判定はここに一本化する
func hunter_sees_runner(h: Node) -> bool:
	return _seer_ids.has(h.get_instance_id())


## ホストのみ。全鬼を走査して共有情報を更新する
func _update_sight(delta: float) -> void:
	var runner := get_runner()
	if runner == null:
		return
	_sight_timer -= delta
	if _sight_timer <= 0.0:
		_sight_timer = SIGHT_TICK
		# 鬼を tick 間で分散させない。一括評価の方が spotted_zone が一貫する
		_seer_ids.clear()
		for h in get_tree().get_nodes_in_group("players"):
			if h != runner and can_see(h, runner):
				_seer_ids[h.get_instance_id()] = true
		for h in get_tree().get_nodes_in_group("cpu_hunters"):
			if can_see(h, runner):
				_seer_ids[h.get_instance_id()] = true

	# 新しい値はローカルに組み立て、代入と signal は必ず _set_intel に通す。
	# ここで直接 spotted を書き換えると、call_local の _set_intel が
	# 「変化なし」と判断してホスト側だけ spotted_changed が飛ばなくなる
	var new_zone := spotted_zone
	var new_intel := intel_left
	var new_live := spotted
	if not _seer_ids.is_empty():
		new_zone = zone_at(runner.global_position)
		new_intel = INTEL_TIME
		new_live = true
		_no_sight_for = 0.0
	else:
		_no_sight_for += delta
		new_live = spotted and _no_sight_for < SPOTTED_HOLD
		new_intel = maxf(intel_left - delta, 0.0)
		if new_intel == 0.0:
			new_zone = -1

	if new_zone != spotted_zone or new_live != spotted:
		_set_intel.rpc(new_zone, new_intel, new_live)
	else:
		var prev_sec := ceili(intel_left)
		intel_left = new_intel
		if new_intel > 0.0 and ceili(new_intel) != prev_sec:
			_sync_intel.rpc(new_intel)  # 1Hz の補正だけ


## --- 置き物アイテム -----------------------------------------------------

## クライアントから「ここに置きたい」と要求する。生成はサーバだけが行う
## （クライアントが自前で生成しても MultiplayerSpawner を通らず他ピアへ同期されない）。
## Autoload なのでノードパスが全ピアで一致し、RPC の宛先として安定している
@rpc("any_peer", "reliable")
func request_drop(kind: int, pos: Vector3, yaw: float) -> void:
	if not multiplayer.is_server() or state != State.PLAYING:
		return
	var world := get_tree().current_scene
	if world and world.has_method("spawn_dropped_item"):
		world.spawn_dropped_item(kind, pos, yaw)


## 接触判定。各キャラの TagArea(Area3D) から body_entered 経由でホスト側のみ呼ばれる。
## サーバはレプリケートされた全ボディのコピーを持つため、ここで重なりを判定できる。
func report_touch(a: Node3D, b: Node3D) -> void:
	if not multiplayer.is_server() or state != State.PLAYING or head_start_left > 0.0:
		return
	var runner := get_runner()
	if runner == null:
		return
	# 片方だけが逃走者のときにだけ成立する（鬼同士の接触は無視）
	if (a == runner) == (b == runner):
		return
	_end_round.rpc("HUNTERS WIN!  (runner tagged)")


## body_entered は「入った瞬間」しか鳴らないため、
## ヘッドスタート終了時に既に重なっている組み合わせを一度だけ拾う。
func _sweep_tag_overlaps() -> void:
	var runner := get_runner()
	if runner == null:
		return
	var area := runner.get_node_or_null("TagArea") as Area3D
	if area == null:
		return
	for body in area.get_overlapping_bodies():
		report_touch(runner, body)
		if state != State.PLAYING:
			return


func _process(delta: float) -> void:
	if state == State.RESULT:
		result_left = maxf(result_left - delta, 0.0)
	# クライアント側はローカルで滑らかに減算し、毎秒の同期で補正する
	if multiplayer.is_server() or state != State.PLAYING:
		return
	if head_start_left > 0.0:
		head_start_left = maxf(head_start_left - delta, 0.0)
	else:
		time_left = maxf(time_left - delta, 0.0)
	# 情報の残り秒もローカルで滑らかに減らす。1Hz の同期が落ちても自己修復する
	if intel_left > 0.0:
		intel_left = maxf(intel_left - delta, 0.0)
		if intel_left == 0.0:
			spotted_zone = -1


## 途中参加者へ現在の状態を送る（ホストのみ呼ぶ）
func sync_to_peer(peer_id: int) -> void:
	if multiplayer.is_server():
		_sync_state.rpc_id(peer_id, state, runner_id, hunter_mult,
			time_left, head_start_left, result_text, spotted_zone, intel_left, spotted)


func on_player_left(peer_id: int) -> void:
	if multiplayer.is_server() and state == State.PLAYING and peer_id == runner_id:
		_end_round.rpc("Round ended (runner disconnected)")


func _schedule_next_round() -> void:
	await get_tree().create_timer(RESULT_TIME).timeout
	if state != State.RESULT:
		return
	_back_to_waiting.rpc()
	request_start_round()


## --- RPC（ホスト -> 全ピア） -------------------------------------------

@rpc("authority", "call_local", "reliable")
func _start_round(new_runner: int, mult: float, spawns: Dictionary) -> void:
	runner_id = new_runner
	hunter_mult = mult
	time_left = ROUND_TIME
	head_start_left = HEAD_START
	result_text = ""
	state = State.PLAYING
	world_time = 0.0  # 全ピアのギミック位相をここで揃える
	_clear_intel()    # 前ラウンドの目撃情報を持ち越さない
	state_changed.emit(state)
	# 位置の権威は各クライアントにあるため、自分のプレイヤーは自分で移動する
	var my_id := multiplayer.get_unique_id()
	if spawns.has(my_id):
		var me := _find_player(my_id)
		if me:
			me.teleport(spawns[my_id])


@rpc("authority", "call_local", "unreliable")
func _sync_time(t: float) -> void:
	time_left = t


@rpc("authority", "call_local", "unreliable")
func _sync_head(t: float) -> void:
	head_start_left = t


@rpc("authority", "call_local", "reliable")
func _end_round(text: String) -> void:
	state = State.RESULT
	head_start_left = 0.0
	result_text = text
	result_left = RESULT_TIME
	_clear_intel()
	state_changed.emit(state)
	if multiplayer.is_server():
		_schedule_next_round()


@rpc("authority", "call_local", "reliable")
func _back_to_waiting() -> void:
	state = State.WAITING
	runner_id = -1
	head_start_left = 0.0
	result_left = 0.0
	_clear_intel()
	state_changed.emit(state)
	if multiplayer.is_server():
		_clear_cpu_hunters()


## 目撃ゾーンや「見られている」状態が変わった瞬間だけ送る（毎フレームは送らない）
@rpc("authority", "call_local", "reliable")
func _set_intel(zone: int, left: float, live: bool) -> void:
	spotted_zone = zone
	intel_left = left
	var was := spotted
	spotted = live
	if was != live:
		spotted_changed.emit(live)


## 残り秒の補正。_sync_time / _sync_head と同じ 1Hz unreliable
@rpc("authority", "call_local", "unreliable")
func _sync_intel(left: float) -> void:
	intel_left = left


@rpc("authority", "call_remote", "reliable")
func _sync_state(s: int, r_id: int, mult: float, t: float, head: float, res: String,
		zone: int, intel: float, live: bool) -> void:
	state = s
	runner_id = r_id
	hunter_mult = mult
	time_left = t
	head_start_left = head
	result_text = res
	spotted_zone = zone
	intel_left = intel
	var was := spotted
	spotted = live
	state_changed.emit(state)
	if was != live:
		spotted_changed.emit(live)
