extends Node

## GameManager の子ノード（`$TeamMode`）。Reverse Tag（4対4で鬼チームと逃げチームが
## 一定時間ごとに入れ替わるモード）のチーム状態と進行を持つ。
## 旧モード（逃げ1人 vs 鬼）の runner_id / get_runner() / hunters() には一切触れず、
## このモードの間だけ GameManager がここへ処理を回す。旧モードの経路を書き換えないのは、
## CPU 鬼の連携（HunterSquad）や視界の共有が「逃げは1人」を前提に作り込まれていて、
## 混ぜると両方が壊れるため。
##
## キャラは**ノード名の文字列**で引く（人間 = peer_id、CPU = "CPUA3" のような名前）。
## 人間と CPU を同じ表で扱え、ノード名は全ピアで一致する（player.gd / banana.gd と同じ前提）。
##
## 役割は「チーム」と「今どちらのチームが鬼か（hunting_team）」から決まる。
## 個々のキャラに役割を持たせないので、入れ替えは hunting_team を反転するだけで全員に効く。
## 幽霊（つかまった逃げ役）は ghosts に名前を入れる。幽霊は鬼にも逃げにも数えず、
## タッチされず、他のキャラとぶつからない（衝突例外を双方向に張る。レイヤーを変えると
## ジャンプ台・マンホール等のギミックの Area3D が幽霊を検知しなくなるため）。
##
## 進行（ホストだけが動かす）:
##   開始 -> 鬼チームはヘッドスタートの間だけ静止 -> TURN_TIME で入れ替え（幽霊は全員復活、
##   新しい鬼は SWAP_FREEZE 静止）-> TURNS 回目の終わりで得点の多い方の勝ち。
##   途中で逃げチームが全員幽霊になったら、その時点で鬼チームの勝ち。
## 時計は GameManager.time_left / head_start_left をそのまま使う（ターンの残り秒）。
## クライアント側の滑らかな減算・HUD のヘッドスタート表示・_sync_time / _sync_head が
## 旧モードと同じ経路で動くため。

signal changed

const TEAM_SIZE := 4
const TURN_TIME := 60.0
const TURNS := 4
## 入れ替えの予告を出し始める残り秒
const SWAP_WARN := 10.0
## 入れ替え直後、新しく鬼になったチームが動けない秒。目の前にいた相手が
## 入れ替わった瞬間に捕まるだけにならないよう、逃げ始める間を作る
const SWAP_FREEZE := 3.0
## 幽霊のバナナの再装填。投げ放題にすると鬼が転び続けて何もできなくなる
const GHOST_BANANA_COOLDOWN := 4.0
## 復活直後に捕まらない秒。当てた瞬間に鬼の目の前で復活することが多いため
const REVIVE_GRACE := 2.0
## 視界の評価間隔。人数が旧モードの倍(8人x8人)なので 20Hz では重い。
## ミニマップの点と CPU の判断に使うだけなので 5Hz で足りる
const VISION_TICK := 0.2
## 最後に見えた場所を CPU 鬼が捜索し続ける秒（sight_system.gd の INTEL_TIME と同じ役目）
const LAST_SEEN_TIME := 16.0
## 幽霊の当たり無効（衝突例外）を張り直す間隔。途中で湧いたキャラにも行き渡らせる
const GHOST_COLLISION_TICK := 0.5

const TEAM_NAMES: Array[String] = ["チームA", "チームB"]
## 頭上ラベル・ミニマップ・HUD で揃える色。役割色（緑=逃げ / 赤=鬼）と被らない青と橙
const TEAM_COLORS: Array[Color] = [Color(0.3, 0.62, 1.0), Color(1.0, 0.6, 0.18)]
## チームAは北の列、Bは南の列に湧く。中央を挟んで向かい合うので、開始直後に
## 鬼と逃げが隣り合わない
const TEAM_SPAWN_ZONES: Array = [[0, 1, 2], [6, 7, 8]]
const SPAWN_HEIGHT := 3.0
const SPAWN_SPREAD := 9.0

var enabled := false
## ノード名 -> 0/1。ラウンド中だけ埋まる
var team_of := {}
## 準備中の希望。peer_id -> 0/1（無い人はおまかせ）
var wanted_team := {}
var hunting_team := 0
var turn := 0
var score: Array[int] = [0, 0]
## 幽霊のノード名 -> true
var ghosts := {}
## チームごとに「今見えている敵」のノード名 -> true。ミニマップと CPU が使う
var visible_to: Array[Dictionary] = [{}, {}]

# --- ホストだけが持つ ---
var _vision_timer := 0.0
var _ghost_col_timer := 0.0
## 視認者のノード名 -> {敵のノード名: true}。CPU の「自分の目で見ているか」用
var _seen_by := {}
## チームごとに、最後に敵の逃げ役が見えた位置と残り秒
var _last_seen_pos: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _last_seen_left: Array[float] = [0.0, 0.0]
var _revive_grace := {}
## 衝突例外を張っているペア（"a|b"）。外すときに漏れなく外すため
var _ghost_pairs := {}


func reset() -> void:
	enabled = false
	wanted_team.clear()
	_clear_round()


func _clear_round() -> void:
	team_of.clear()
	ghosts.clear()
	score = [0, 0]
	turn = 0
	hunting_team = 0
	visible_to = [{}, {}]
	_seen_by.clear()
	_revive_grace.clear()
	_last_seen_left = [0.0, 0.0]
	_clear_ghost_collisions()


## --- 問い合わせ（全ピア） -----------------------------------------------

func team_of_name(n: String) -> int:
	return int(team_of.get(n, -1))


func my_team() -> int:
	return team_of_name(str(multiplayer.get_unique_id()))


func is_ghost_name(n: String) -> bool:
	return ghosts.has(n)


func is_hunter_name(n: String) -> bool:
	return team_of.has(n) and team_of_name(n) == hunting_team and not ghosts.has(n)


func is_runner_name(n: String) -> bool:
	return team_of.has(n) and team_of_name(n) != hunting_team and not ghosts.has(n)


## 入れ替えまでの予告中か（HUD 用）
func swap_warning() -> bool:
	return enabled and GameManager.state == GameManager.State.PLAYING \
		and GameManager.head_start_left <= 0.0 and GameManager.time_left <= SWAP_WARN


## このチームの現在のキャラ（人間 + CPU、幽霊を含む）
func members(team: int) -> Array[Node3D]:
	var out: Array[Node3D] = []
	for n in _characters():
		if team_of_name(String(n.name)) == team:
			out.append(n)
	return out


func alive_count(team: int) -> int:
	var c := 0
	for n in members(team):
		if not ghosts.has(String(n.name)):
			c += 1
	return c


func _characters() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for g in ["players", "cpu_hunters", "cpu_runners"]:
		for n in get_tree().get_nodes_in_group(g):
			out.append(n)
	return out


## --- 準備中のチーム選び ---------------------------------------------------

## ホスト専用。モードの切替（ロビーのボタン）
func set_enabled(on: bool) -> void:
	if not multiplayer.is_server() or GameManager.state != GameManager.State.WAITING:
		return
	if NetworkManager.matched_via_eos_lobby:
		return  # レーティング戦は旧モード固定（このモードはレート対象外）
	_set_enabled.rpc(on)


## 自分の希望チームを切り替える。おまかせ -> A -> B -> おまかせ の順
func cycle_my_team() -> void:
	if not enabled or GameManager.state != GameManager.State.WAITING:
		return
	var me := multiplayer.get_unique_id()
	var next := _next_wanted(me)
	if multiplayer.is_server():
		_apply_wanted(me, next)
	else:
		# 返事を待たずに手元の表も進める。待つと、往復の間に2回押したとき
		# 2回とも同じ値を送ってしまい1つしか進まない。正はホストの配信で上書きされる
		if next < 0:
			wanted_team.erase(me)
		else:
			wanted_team[me] = next
		request_team.rpc_id(1, next)


## ホスト専用。名簿の行クリックで、その人の希望チームを順送りする
func cycle_team_of(peer_id: int) -> void:
	if not multiplayer.is_server() or not enabled or GameManager.state != GameManager.State.WAITING:
		return
	_apply_wanted(peer_id, _next_wanted(peer_id))


func _next_wanted(peer_id: int) -> int:
	match int(wanted_team.get(peer_id, -1)):
		-1:
			return 0
		0:
			return 1
		_:
			return -1


@rpc("any_peer", "reliable")
func request_team(team: int) -> void:
	if not multiplayer.is_server():
		return
	_apply_wanted(multiplayer.get_remote_sender_id(), team)


func _apply_wanted(peer_id: int, team: int) -> void:
	if not multiplayer.is_server() or GameManager.state != GameManager.State.WAITING:
		return
	_set_wanted_team.rpc(peer_id, clampi(team, -1, 1))


## --- ラウンドの開始（ホスト） ----------------------------------------------

## GameManager.request_start_round() から呼ばれる。人間を希望どおりに分けて偏りを均し、
## 両チームが TEAM_SIZE 人になるまで CPU で埋める（人間が多ければ多い方に揃える）
func start_round(ids: Array[int]) -> void:
	var teams: Array = [[], []]
	var free: Array[int] = []
	for id in ids:
		var w := int(wanted_team.get(id, -1))
		if w < 0:
			free.append(id)
		else:
			teams[w].append(id)
	free.shuffle()
	for id in free:
		teams[0 if teams[0].size() <= teams[1].size() else 1].append(id)
	# 希望が片寄って差が2以上なら、後から希望した人ではなく末尾の人から少ない方へ移す
	while absi(teams[0].size() - teams[1].size()) > 1:
		var big := 0 if teams[0].size() > teams[1].size() else 1
		teams[1 - big].append(teams[big].pop_back())
	var size := maxi(TEAM_SIZE, maxi(teams[0].size(), teams[1].size()))
	var first_hunters := randi() % 2

	var assign := {}
	var spawns := {}
	for t in 2:
		var i := 0
		for id in teams[t]:
			assign[str(id)] = t
			spawns[id] = _team_spawn(t, i)
			i += 1
	_begin.rpc(assign, first_hunters)
	GameManager._start_round.rpc(-1, 1.0, size, spawns, false)
	var world := get_tree().current_scene
	if not world.has_method("spawn_team_cpu"):
		return
	for t in 2:
		for i in range(teams[t].size(), size):
			var cpu_name: String = world.spawn_team_cpu(t == first_hunters, t, _team_spawn(t, i))
			team_of[cpu_name] = t
	_broadcast()


func _team_spawn(team: int, i: int) -> Vector3:
	var zones: Array = TEAM_SPAWN_ZONES[team]
	var zone: int = zones[i % zones.size()]
	var lap := i / zones.size()
	# 2人目以降の同じゾーンは東西にずらす（中心に重ねると出た瞬間に固まる）
	var dx := 0.0 if lap == 0 else SPAWN_SPREAD * float((lap + 1) / 2) * (1.0 if lap % 2 == 1 else -1.0)
	return WorldData.zone_point(zone, dx, 0.0) + Vector3(0, SPAWN_HEIGHT, 0)


## --- 進行（ホスト。GameManager._physics_process から PLAYING 中だけ呼ばれる） ---

func tick(delta: float) -> void:
	for n in _revive_grace.keys():
		_revive_grace[n] = float(_revive_grace[n]) - delta
		if _revive_grace[n] <= 0.0:
			_revive_grace.erase(n)
	for t in 2:
		_last_seen_left[t] = maxf(_last_seen_left[t] - delta, 0.0)
	_vision_timer -= delta
	if _vision_timer <= 0.0:
		_vision_timer = VISION_TICK
		_update_vision()

	var gm := GameManager
	if gm.head_start_left > 0.0:
		var prev_head := ceili(gm.head_start_left)
		gm.head_start_left = maxf(gm.head_start_left - delta, 0.0)
		if gm.head_start_left == 0.0 or ceili(gm.head_start_left) != prev_head:
			gm._sync_head.rpc(gm.head_start_left)
		if gm.head_start_left == 0.0:
			_sweep_overlaps()
		return
	var prev_sec := ceili(gm.time_left)
	gm.time_left -= delta
	if gm.time_left <= 0.0:
		if turn + 1 >= TURNS:
			_finish_by_score()
		else:
			_swap_now()
		return
	if ceili(gm.time_left) != prev_sec:
		gm._sync_time.rpc(gm.time_left)


func _swap_now() -> void:
	_swap.rpc(turn + 1, 1 - hunting_team)
	# CPU は鬼と逃げで別のシーンなので、同じ位置・同じチームで反対の役へ差し替える
	var world := get_tree().current_scene
	if not world.has_method("spawn_team_cpu"):
		return
	for cpu in get_tree().get_nodes_in_group("cpu_hunters") + get_tree().get_nodes_in_group("cpu_runners"):
		var old_name := String(cpu.name)
		if not team_of.has(old_name):
			continue
		var t := team_of_name(old_name)
		var pos: Vector3 = cpu.global_position
		var was_hunter: bool = cpu.is_in_group("cpu_hunters")
		# グループから外してから消す（game_manager.gd の _clear_cpu_hunters と同じ理由）
		cpu.remove_from_group("cpu_hunters")
		cpu.remove_from_group("cpu_runners")
		cpu.queue_free()
		team_of.erase(old_name)
		team_of[world.spawn_team_cpu(not was_hunter, t, pos)] = t
	_broadcast()


func _finish_by_score() -> void:
	if score[0] == score[1]:
		GameManager._end_round.rpc(false, GameManager.EndReason.TEAM_DRAW)
	else:
		GameManager._end_round.rpc(score[0] > score[1], GameManager.EndReason.TEAM_SCORE)


## 全員の視界を評価し、チームごとの「見えている敵」が変わった時だけ配る。
## 幽霊も見張り役になれる（味方に敵の位置を知らせるのが幽霊の仕事のひとつ）。
## 幽霊は見られる側には数えない（捕まらない相手を点で出しても邪魔になるだけ）
func _update_vision() -> void:
	var chars := _characters()
	_seen_by.clear()
	for t in 2:
		var seen := {}
		for seer in chars:
			if team_of_name(String(seer.name)) != t:
				continue
			var mine := {}
			for target in chars:
				var tn := String(target.name)
				if not team_of.has(tn) or team_of_name(tn) == t or ghosts.has(tn):
					continue
				if GameManager.can_see(seer, target):
					mine[tn] = true
					seen[tn] = true
					if t == hunting_team:
						_last_seen_pos[t] = target.global_position
						_last_seen_left[t] = LAST_SEEN_TIME
			_seen_by[String(seer.name)] = mine
		if not _same_keys(seen, visible_to[t]):
			_sync_vision.rpc(t, PackedStringArray(seen.keys()))


## keys() の比較は並び順まで見るので、中身が同じでも差分ありと判定して RPC を撒いてしまう
func _same_keys(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k):
			return false
	return true


## ホスト専用。seer が自分の目で target を見ているか（CPU の追跡判断用）
func sees(seer: Node, target: Node) -> bool:
	var mine: Dictionary = _seen_by.get(String(seer.name), {})
	return mine.has(String(target.name))


## ホスト専用。CPU 鬼の標的: 自チームに見えている敵の逃げ役のうち最も近い者
func nearest_visible_runner(from: Node3D) -> Node3D:
	var t := team_of_name(String(from.name))
	if t < 0:
		return null
	var best: Node3D = null
	var best_d := INF
	for n in members(1 - t):
		var nn := String(n.name)
		if not visible_to[t].has(nn) or not is_runner_name(nn):
			continue
		var d := from.global_position.distance_squared_to(n.global_position)
		if d < best_d:
			best_d = d
			best = n
	return best


## 自チームに見えている敵の鬼。CPU 逃げ役・幽霊の判断（ホスト）と、HUD の危険表示・
## ミニマップ（全ピア）が使う。visible_to は全ピアへ配ってあるのでどこでも引ける
func visible_hunters(from: Node3D) -> Array[Node3D]:
	var out: Array[Node3D] = []
	var t := team_of_name(String(from.name))
	if t < 0:
		return out
	for n in members(1 - t):
		if visible_to[t].has(String(n.name)) and is_hunter_name(String(n.name)):
			out.append(n)
	return out


## ホスト専用。敵の誰かに見られているか（旧モードの GameManager.spotted に当たる）
func is_seen(n: Node) -> bool:
	var t := team_of_name(String(n.name))
	return t >= 0 and visible_to[1 - t].has(String(n.name))


## ホスト専用。CPU 鬼の捜索先。最後に逃げ役が見えた位置（古ければ -1 ゾーン）
func last_seen_zone(team: int) -> int:
	if team < 0 or _last_seen_left[team] <= 0.0:
		return -1
	return WorldData.zone_index(_last_seen_pos[team])


## --- タッチと幽霊（ホスト） ---------------------------------------------

## GameManager.report_touch から。鬼（幽霊でない）が逃げ（幽霊でも復活直後でもない）に
## 触れた時だけ成立する。同じチーム同士・幽霊がらみの接触は無視する
func on_touch(a: Node3D, b: Node3D) -> void:
	var an := String(a.name)
	var bn := String(b.name)
	var runner := ""
	var hunter := ""
	if is_hunter_name(an) and is_runner_name(bn):
		hunter = an
		runner = bn
	elif is_hunter_name(bn) and is_runner_name(an):
		hunter = bn
		runner = an
	else:
		return
	if _revive_grace.has(runner):
		return
	var new_score := score.duplicate()
	new_score[hunting_team] += 1
	_set_ghost.rpc(runner, true, new_score[0], new_score[1])
	if alive_count(1 - hunting_team) == 0:
		GameManager._end_round.rpc(hunting_team == 0, GameManager.EndReason.TEAM_WIPE,
			hunter.to_int() if hunter.is_valid_int() else -1)


## ヘッドスタート明けに、すでに重なっている組を一度だけ拾う
## （body_entered は入った瞬間しか鳴らない。game_manager.gd の _sweep_tag_overlaps と同じ理由）
func _sweep_overlaps() -> void:
	for n in members(1 - hunting_team):
		var area := n.get_node_or_null("TagArea") as Area3D
		if area == null:
			continue
		for body in area.get_overlapping_bodies():
			on_touch(n, body)
			if GameManager.state != GameManager.State.PLAYING:
				return


## banana.gd から（ホスト）。幽霊の投げたバナナが敵の鬼に当たったら、投げた幽霊が復活する
func on_banana_hit(thrower_name: String, victim: Node) -> void:
	if not enabled or GameManager.state != GameManager.State.PLAYING:
		return
	if not ghosts.has(thrower_name) or not is_hunter_name(String(victim.name)):
		return
	if team_of_name(thrower_name) == team_of_name(String(victim.name)):
		return
	_revive_grace[thrower_name] = REVIVE_GRACE
	_set_ghost.rpc(thrower_name, false, score[0], score[1])


## --- 途中参加・離脱（ホスト） -------------------------------------------

## 途中参加者を人数の少ないチームへ入れる。ラウンド中は次の入れ替えまで幽霊で待つ
## （いきなり逃げ役で入ると、そのターンの得点を取られる側が一方的に不利になる）
func on_peer_joined(peer_id: int) -> void:
	if not enabled or GameManager.state == GameManager.State.WAITING:
		return
	var t := 0 if members(0).size() <= members(1).size() else 1
	team_of[str(peer_id)] = t
	if GameManager.state == GameManager.State.PLAYING:
		ghosts[str(peer_id)] = true
	_broadcast()


## 抜けた人の穴は同じチーム・同じ役の CPU で埋める（4対4を崩さない）
func on_peer_left(peer_id: int, last_pos: Vector3) -> void:
	wanted_team.erase(peer_id)
	var n := str(peer_id)
	if not team_of.has(n):
		return
	var t := team_of_name(n)
	var was_ghost := ghosts.has(n)
	team_of.erase(n)
	ghosts.erase(n)
	var world := get_tree().current_scene
	if GameManager.state == GameManager.State.PLAYING and world.has_method("spawn_team_cpu"):
		var cpu_name: String = world.spawn_team_cpu(t == hunting_team, t, last_pos)
		team_of[cpu_name] = t
		if was_ghost:
			ghosts[cpu_name] = true
	_broadcast()
	if GameManager.state == GameManager.State.PLAYING and alive_count(1 - hunting_team) == 0:
		GameManager._end_round.rpc(hunting_team == 0, GameManager.EndReason.TEAM_WIPE)


## 途中参加者へ現在の状態を送る
func sync_to_peer(peer_id: int) -> void:
	_set_enabled.rpc_id(peer_id, enabled)
	for id in wanted_team:
		_set_wanted_team.rpc_id(peer_id, id, wanted_team[id])
	if not team_of.is_empty():
		_sync_teams.rpc_id(peer_id, team_of, ghosts, hunting_team, turn, score[0], score[1])


func _broadcast() -> void:
	_sync_teams.rpc(team_of, ghosts, hunting_team, turn, score[0], score[1])


## --- 幽霊の当たり無効（全ピア） -------------------------------------------

func _physics_process(delta: float) -> void:
	if not enabled or GameManager.state == GameManager.State.WAITING:
		return
	_ghost_col_timer -= delta
	if _ghost_col_timer <= 0.0:
		_ghost_col_timer = GHOST_COLLISION_TICK
		_apply_ghost_collisions()


## 幽霊と他の全キャラの間に衝突例外を双方向に張る。片側だけだと、
## 物理エンジンによっては相手の move_and_slide() で幽霊にぶつかってしまう
func _apply_ghost_collisions() -> void:
	var chars := _characters()
	var want := {}
	for g in chars:
		if not ghosts.has(String(g.name)):
			continue
		for c in chars:
			if c == g:
				continue
			var key := _pair_key(g, c)
			want[key] = [g, c]
	for key in _ghost_pairs.keys():
		if want.has(key):
			continue
		var pair: Array = _ghost_pairs[key]
		if is_instance_valid(pair[0]) and is_instance_valid(pair[1]):
			pair[0].remove_collision_exception_with(pair[1])
			pair[1].remove_collision_exception_with(pair[0])
		_ghost_pairs.erase(key)
	for key in want:
		if _ghost_pairs.has(key):
			continue
		var pair: Array = want[key]
		pair[0].add_collision_exception_with(pair[1])
		pair[1].add_collision_exception_with(pair[0])
		_ghost_pairs[key] = pair


func _clear_ghost_collisions() -> void:
	for key in _ghost_pairs:
		var pair: Array = _ghost_pairs[key]
		if is_instance_valid(pair[0]) and is_instance_valid(pair[1]):
			pair[0].remove_collision_exception_with(pair[1])
			pair[1].remove_collision_exception_with(pair[0])
	_ghost_pairs.clear()


func _pair_key(a: Node, b: Node) -> String:
	var x := a.get_instance_id()
	var y := b.get_instance_id()
	return "%d|%d" % [mini(x, y), maxi(x, y)]


## --- RPC（ホスト -> 全ピア） -------------------------------------------

@rpc("authority", "call_local", "reliable")
func _set_enabled(on: bool) -> void:
	enabled = on
	changed.emit()
	GameManager.roles_changed.emit()


@rpc("authority", "call_local", "reliable")
func _set_wanted_team(peer_id: int, team: int) -> void:
	if team < 0:
		wanted_team.erase(peer_id)
	else:
		wanted_team[peer_id] = team
	changed.emit()
	GameManager.roles_changed.emit()


## ラウンド開始。GameManager._start_round より先に送るので、state_changed を受けた
## HUD がチームの表を読める
@rpc("authority", "call_local", "reliable")
func _begin(assign: Dictionary, first_hunters: int) -> void:
	_clear_round()
	team_of = assign
	hunting_team = first_hunters
	changed.emit()


@rpc("authority", "call_local", "reliable")
func _sync_teams(teams: Dictionary, ghost_names: Dictionary, hunting: int, t: int,
		score_a: int, score_b: int) -> void:
	team_of = teams
	ghosts = ghost_names
	hunting_team = hunting
	turn = t
	score = [score_a, score_b]
	_apply_ghost_collisions()
	changed.emit()


## 入れ替え。幽霊は全員復活し、新しい鬼チームは SWAP_FREEZE だけ動けない
@rpc("authority", "call_local", "reliable")
func _swap(t: int, hunting: int) -> void:
	turn = t
	hunting_team = hunting
	ghosts.clear()
	_revive_grace.clear()
	_last_seen_left = [0.0, 0.0]
	GameManager.time_left = TURN_TIME
	GameManager.head_start_left = SWAP_FREEZE
	_apply_ghost_collisions()
	changed.emit()


@rpc("authority", "call_local", "reliable")
func _set_ghost(n: String, on: bool, score_a: int, score_b: int) -> void:
	if on:
		ghosts[n] = true
	else:
		ghosts.erase(n)
	score = [score_a, score_b]
	_apply_ghost_collisions()
	changed.emit()


@rpc("authority", "call_local", "reliable")
func _sync_vision(team: int, names: PackedStringArray) -> void:
	var d := {}
	for n in names:
		d[n] = true
	visible_to[team] = d
