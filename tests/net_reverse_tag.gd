extends Node

## 2ピアをつないで Reverse Tag（4対4・攻守入れ替え）を実際の通信で確かめる。
##
##   ホスト:     godot --headless --path . res://tests/net_reverse_tag.tscn -- host
##   クライアント: godot --headless --path . res://tests/net_reverse_tag.tscn -- client 127.0.0.1
##
## 見るところ（ふつうの流れ）:
##   1. ホストのモード切替と、クライアント自身のチーム希望が両側に届く
##   2. 開始で両チーム4人（人間1+CPU3ずつ）になり、CPU がクライアントにも複製される
##   3. 逃げ側の人間がタッチで幽霊になり、得点と当たり無効が両側でそろう
##   4. 幽霊の持ち主のプロセスでバナナが補充され、投げると持ち主の名前つきでホストに出る。
##      それが敵の鬼に当たると幽霊が復活する
##   5. 入れ替えで役割が反転し、幽霊が全員戻り、CPU が反対の役のシーンに差し替わる
##   6. 逃げ側の全滅で決着し、リザルト後は準備中に戻ってモードは残る
##   7. ラウンド中にクライアントが抜けると、同じチームの CPU が穴を埋める
##
## 途中参加は別の起動で見る（ホストを先に起動し、5秒ほどおいてクライアントを起動する）:
##
##   ホスト:     ... res://tests/net_reverse_tag.tscn -- host late
##   クライアント: ... res://tests/net_reverse_tag.tscn -- client 127.0.0.1 late
##
##   ホストがひとりでラウンドを始めてから参加し、人数の少ないチームに幽霊で入ること、
##   状態とキャラが全部届くことを見る。
##
## 進行は net_roles と同じく「接続確立からの経過秒」で揃え、両側が同じ時刻に同じ検査をする。

var _is_host := false
var _late := false
var _fails := 0
var _client_id := -1
var _world: Node


func _ready() -> void:
	_is_host = NetworkManager.mode != NetworkManager.Mode.CLIENT
	_late = OS.get_cmdline_user_args().has("late")
	await get_tree().process_frame
	_world = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(_world)
	get_tree().current_scene = _world

	if _late and _is_host:
		await _wait(1.0)
		GameManager.team.set_enabled(true)
		GameManager.request_start_round()

	if not await _wait_for_peer():
		print("FAIL: 相手がつながらなかった（このテストはホストとクライアントの"
			+ "2プロセスで起動する必要がある。ヘッダの手順を参照）")
		get_tree().quit()
		return
	_client_id = multiplayer.get_peers()[0] if _is_host else multiplayer.get_unique_id()
	print("=== %s%s (peer %d / 相手 %d) ===" % ["HOST" if _is_host else "CLIENT",
		" late" if _late else "", multiplayer.get_unique_id(), _client_id])

	await _wait(2.0)
	if _late:
		await _late_join()
	else:
		await _full_round()

	print("=== %s の結果: %s ===" % ["HOST" if _is_host else "CLIENT",
		"ALL OK" if _fails == 0 else "%d 件 FAIL" % _fails])
	await _wait(2.0 if _is_host else 5.0)
	get_tree().quit()


func _full_round() -> void:
	var team = GameManager.team
	var me := str(_client_id)

	# 1) モード切替とチーム希望
	if _is_host:
		team.set_enabled(true)
	await _settle()
	_ok("モードが両側でオン", team.enabled)
	await _gap()

	if _is_host:
		team.cycle_my_team()  # ホスト: おまかせ -> A
	else:
		team.cycle_my_team()  # クライアント: おまかせ -> A
		team.cycle_my_team()  # A -> B
	await _settle()
	_eq("ホストの希望チーム", int(team.wanted_team.get(1, -1)), 0)
	_eq("クライアントの希望チーム", int(team.wanted_team.get(_client_id, -1)), 1)
	await _gap()

	# 2) 開始
	if _is_host:
		GameManager.request_start_round()
	await _settle()
	_eq("状態", GameManager.state, GameManager.State.PLAYING)
	_eq("チーム表の人数", team.team_of.size(), 8)
	_eq("ホストのチーム", team.team_of_name("1"), 0)
	_eq("クライアントのチーム", team.team_of_name(me), 1)
	_eq("チームAの人数", team.members(0).size(), 4)
	_eq("チームBの人数", team.members(1).size(), 4)
	_check_nodes_match_table()
	print("  先攻の鬼チーム: %s" % team.TEAM_NAMES[team.hunting_team])
	await _gap()

	# 3) タッチで幽霊になる。逃げ側の人間を、鬼側の人間が捕まえる
	var runner_name := "1" if team.hunting_team == 1 else me
	var hunter_name := me if runner_name == "1" else "1"
	if _is_host:
		GameManager.head_start_left = 0.0
		GameManager.report_touch(_node(hunter_name), _node(runner_name))
	await _settle()
	_ok("捕まった %s が幽霊" % runner_name, team.is_ghost_name(runner_name))
	_eq("鬼チームの得点", team.score[team.hunting_team], 1)
	_eq("逃げチームの得点", team.score[1 - team.hunting_team], 0)
	var ghost := _node(runner_name) as PhysicsBody3D
	_ok("幽霊と鬼の当たりが無い", ghost != null
		and ghost.get_collision_exceptions().has(_node(hunter_name)))
	await _gap()

	# 4) バナナ。幽霊の持ち主のプロセスで補充され、そこで投げる
	var owns_ghost := (runner_name == "1") == _is_host
	if owns_ghost:
		var p := _node(runner_name)
		_eq("幽霊の手持ちがバナナ", p.item, Player.Item.BANANA)
		p._use_item()
	await _settle()
	var banana := _banana_of(runner_name)
	if _is_host:
		_ok("投げたバナナに投げ手 %s の名前がある" % runner_name, banana != null)
	else:
		_ok("投げたバナナがクライアントにも出る", _world.items.get_child_count() > 0)
	await _gap()

	# 敵の鬼に当たったことにする（狙って当てるのは headless では不安定なので、当たった瞬間の処理を直接呼ぶ）
	if _is_host and banana != null:
		banana._on_body_entered(_node(hunter_name))
	await _settle()
	_ok("バナナを当てた %s が復活" % runner_name, not team.is_ghost_name(runner_name))
	_eq("復活しても得点は減らない", team.score[team.hunting_team], 1)
	await _gap()

	# 5) 入れ替え
	var first_hunters: int = team.hunting_team
	if _is_host:
		GameManager.time_left = 0.3
	await _settle()
	_eq("ターン", team.turn, 1)
	_eq("鬼チームが反転", team.hunting_team, 1 - first_hunters)
	_eq("幽霊は全員復活", team.ghosts.size(), 0)
	_eq("入れ替え後もチーム表は8人", team.team_of.size(), 8)
	_check_nodes_match_table()
	_check_cpu_roles()
	await _gap()

	# 6) 逃げ側の全滅で決着
	if _is_host:
		var hunter: Node3D = team.members(team.hunting_team)[0]
		for r in team.members(1 - team.hunting_team):
			team.on_touch(hunter, r)
	await _settle()
	_eq("全滅で決着", GameManager.state, GameManager.State.RESULT)
	_eq("全滅させた側の得点", team.score[team.hunting_team], 4)
	await _wait(GameManager.RESULT_TIME + 3.0)
	_eq("リザルト後は準備中", GameManager.state, GameManager.State.WAITING)
	_ok("モードは残る", team.enabled)
	_eq("チーム表は空", team.team_of.size(), 0)
	await _gap()

	# 7) ラウンド中にクライアントが抜けたら CPU が穴を埋める
	if _is_host:
		GameManager.request_start_round()
	await _settle()
	_eq("2ラウンド目の状態", GameManager.state, GameManager.State.PLAYING)
	var client_team := team.team_of_name(me)
	await _gap()
	if not _is_host:
		print("  (クライアントはここで抜ける)")
		return
	await _wait(4.0)  # クライアントが落ちるまで（落ちる側は結果行を出してから 5 秒で quit する）
	var waited := 0.0
	while not multiplayer.get_peers().is_empty() and waited < 10.0:
		await _wait(0.5)
		waited += 0.5
	await _settle()
	_ok("抜けた人はチーム表から消える", not team.team_of.has(me))
	_eq("チーム表は8人のまま", team.team_of.size(), 8)
	_eq("抜けた人のチームも4人のまま", team.members(client_team).size(), 4)


func _late_join() -> void:
	var team = GameManager.team
	var me := str(_client_id)
	await _settle()
	_ok("モードがオン", team.enabled)
	_eq("状態", GameManager.state, GameManager.State.PLAYING)
	_ok("途中参加者がチーム表にいる", team.team_of.has(me))
	_ok("途中参加者は幽霊", team.is_ghost_name(me))
	_eq("チーム表の人数（4+5）", team.team_of.size(), 9)
	_eq("途中参加者は人数の少なかったチーム（4人のほう）へ",
		team.members(team.team_of_name(me)).size(), 5)
	_check_nodes_match_table()
	if not _is_host:
		var p := _node(me)
		_eq("途中参加の幽霊の手持ちがバナナ", p.item if p else -1, Player.Item.BANANA)


## チーム表の名前がすべてキャラとして存在し、キャラもすべて表に載っていること
## （クライアントでは CPU が MultiplayerSpawner で複製されて初めてそろう）
func _check_nodes_match_table() -> void:
	var names := {}
	for c in _world.players.get_children():
		if not c.is_queued_for_deletion():
			names[String(c.name)] = true
	var missing: Array[String] = []
	for n in GameManager.team.team_of:
		if not names.has(n):
			missing.append(n)
	var extra: Array[String] = []
	for n in names:
		if not GameManager.team.team_of.has(n):
			extra.append(n)
	_report("キャラとチーム表が一致（キャラ %d 体）" % names.size(),
		missing.is_empty() and extra.is_empty(), "表にあってキャラが無い %s / 表に無いキャラ %s" % [missing, extra])


## CPU は鬼チームなら cpu_hunter、逃げチームなら cpu_runner のシーンになっていること
func _check_cpu_roles() -> void:
	var team = GameManager.team
	var wrong: Array[String] = []
	for c in _world.players.get_children():
		var n := String(c.name)
		if not n.begins_with("CPU") or c.is_queued_for_deletion():
			continue
		var hunter: bool = team.team_of_name(n) == team.hunting_team
		if c.is_in_group("cpu_hunters") != hunter:
			wrong.append(n)
	_report("CPU が役に合ったシーン", wrong.is_empty(), "役と違う %s" % [wrong])


func _node(n: String) -> Node:
	return _world.players.get_node_or_null(n)


func _banana_of(thrower: String) -> Node:
	for d in _world.items.get_children():
		if "thrower_name" in d and d.thrower_name == thrower:
			return d
	return null


func _wait_for_peer() -> bool:
	var waited := 0.0
	while multiplayer.get_peers().is_empty() and waited < 25.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	return not multiplayer.get_peers().is_empty()


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


## ホストの操作が全ピアへ行き渡るのを待つ
func _settle() -> void:
	await _wait(1.2)


## 検査から次の操作までの間（net_roles.gd の _gap と同じ理由）
func _gap() -> void:
	await _wait(1.2)


func _eq(what: String, got: int, want: int) -> void:
	_report("%s = %d" % [what, got], got == want, "期待値 %d" % want)


func _ok(what: String, cond: bool) -> void:
	_report(what, cond, "成り立たない")


func _report(what: String, ok: bool, why: String) -> void:
	if not ok:
		_fails += 1
	print("  %s  %s" % [what, "OK" if ok else "FAIL（%s）" % why])


# --- Phase 3 L-12: 実セーブ(user://profile.json / settings.json)の保護 ---
# ラウンドを回すので、通常のゲーム終了経路から間接的に save_profile() を踏む。
# 詳細と実測値は tests/save_guard.gd のヘッダを参照。
const _SaveGuard := preload("res://tests/save_guard.gd")
var _save_backup := {}


func _enter_tree() -> void:
	_save_backup = _SaveGuard.backup()


func _exit_tree() -> void:
	_SaveGuard.restore(_save_backup)
