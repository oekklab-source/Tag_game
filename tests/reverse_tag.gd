extends Node

## Reverse Tag（4対4・攻守入れ替え）の進行を検証する。
## test_phase1_rules.gd と同じく world.tscn をホストとして起動し、GameManager / TeamMode の
## 内部関数を直接呼ぶ（ホスト = peer 1 なので .rpc は手元でも実行される）。
##
##   pwsh tools/run_headless_test.ps1 res://tests/reverse_tag.tscn

var passed_count := 0
var failed_count := 0

var _team: Node


func _assert(condition: bool, msg: String) -> void:
	if condition:
		print("  [OK] %s" % msg)
		passed_count += 1
	else:
		printerr("  [FAIL] %s" % msg)
		failed_count += 1


func _ready() -> void:
	print("==================================================")
	print("【TEST】Reverse Tag（4対4・攻守入れ替え）")
	print("==================================================")
	await get_tree().process_frame

	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world
	for i in 30:
		await get_tree().physics_frame
	_team = GameManager.team

	await _test_start()
	await _test_touch_and_ghost()
	await _test_banana_revive(world)
	await _test_swap()
	await _test_wipe()
	await _test_score_and_draw()
	await _test_leave(world)
	await _test_classic_unchanged()
	_test_result_copy()

	print("==================================================")
	print("reverse_tag 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> reverse_tag: ALL PASSED")
	else:
		printerr("=> reverse_tag: SOME TESTS FAILED")
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


## 指定チームの、指定の状態のキャラを1体。人間（ホスト自身）は位置の権威が
## テスト側に無い操作を避けるため、できるだけ CPU を選ぶ
func _pick(team: int, hunter: bool, ghost := false) -> Node3D:
	var fallback: Node3D = null
	for n in _team.members(team):
		var nn := String(n.name)
		var ok: bool = (_team.is_ghost_name(nn) if ghost
			else (_team.is_hunter_name(nn) if hunter else _team.is_runner_name(nn)))
		if not ok:
			continue
		if nn.begins_with("CPU"):
			return n
		fallback = n
	return fallback


func _restart() -> void:
	if GameManager.state != GameManager.State.WAITING:
		GameManager._back_to_waiting()
	await _frames(3)
	GameManager.request_start_round()
	await _frames(5)


func _test_start() -> void:
	print("\n--- [1] ソロ開始で 4対4（人間1 + CPU7）になる ---")
	_team.set_enabled(true)
	_assert(_team.enabled, "ロビーでモードを切り替えられる")
	await _restart()
	_assert(GameManager.state == GameManager.State.PLAYING, "ラウンドが始まる")
	_assert(_team.team_of.size() == 8, "8人がチームに入る (%d)" % _team.team_of.size())
	_assert(_team.members(0).size() == 4 and _team.members(1).size() == 4, "4対4")
	_assert(_team.team_of.has("1"), "ホスト自身もチームに入る")
	var cpu_hunters := get_tree().get_nodes_in_group("cpu_hunters").size()
	var cpu_runners := get_tree().get_nodes_in_group("cpu_runners").size()
	_assert(cpu_hunters + cpu_runners == 7, "CPU は7体 (%d+%d)" % [cpu_hunters, cpu_runners])
	_assert(is_equal_approx(GameManager.time_left, _team.TURN_TIME), "時計は1ターンぶん")
	_assert(not GameManager.round_is_ranked, "レート対象外")
	var hunter := _pick(_team.hunting_team, true)
	_assert(hunter != null and GameManager.is_hunter_node(hunter), "鬼チームのキャラは鬼として扱われる")


func _test_touch_and_ghost() -> void:
	print("\n--- [2] タッチで幽霊になり、鬼チームに1点 ---")
	GameManager.head_start_left = 0.0
	var ht: int = _team.hunting_team
	var h := _pick(ht, true)
	var r := _pick(1 - ht, false)
	var r2: Node3D = null
	for n in _team.members(1 - ht):
		if n != r and _team.is_runner_name(String(n.name)):
			r2 = n
	GameManager.report_touch(h, r)
	_assert(_team.is_ghost_name(String(r.name)), "タッチされた逃げ役が幽霊になる")
	_assert(_team.score[ht] == 1, "鬼チームに1点")
	_assert(GameManager.state == GameManager.State.PLAYING, "全滅していないので続く")
	GameManager.report_touch(h, r)
	_assert(_team.score[ht] == 1, "幽霊にもう一度触れても点は増えない")
	GameManager.report_touch(r, r2)
	_assert(not _team.is_ghost_name(String(r2.name)), "幽霊は逃げ役を捕まえられない")
	for other in _team.members(ht):
		if other != h:
			GameManager.report_touch(h, other)
	_assert(_team.score[ht] == 1 and _team.ghosts.size() == 1, "鬼同士の接触は無視")
	_assert((r as PhysicsBody3D).get_collision_exceptions().has(h), "幽霊は他のキャラとぶつからない（衝突例外）")
	_assert((h as PhysicsBody3D).get_collision_exceptions().has(r), "衝突例外は双方向")
	_assert(GameManager.is_ghost(r), "GameManager.is_ghost が幽霊を返す")


func _test_banana_revive(world: Node) -> void:
	print("\n--- [3] 幽霊のバナナが敵の鬼に当たると復活 ---")
	var ht: int = _team.hunting_team
	var ghost := _pick(1 - ht, false, true)
	var gname := String(ghost.name)
	var teammate := _pick(1 - ht, false)
	_team.on_banana_hit(gname, teammate)
	_assert(_team.is_ghost_name(gname), "味方に当てても復活しない")
	# 実際にバナナを投げて当てる。鬼が動かないよう静止中にしておく
	GameManager.head_start_left = 100.0
	var h := _pick(ht, true)
	world.spawn_dropped_item(Player.Item.BANANA, h.global_position + Vector3(0, 1.0, 0), 0.0,
		Vector3(0, -2.0, 0), -1, gname)
	await _frames(20)
	_assert(not _team.is_ghost_name(gname), "敵の鬼に当てた幽霊が復活する")
	GameManager.head_start_left = 0.0
	GameManager.report_touch(h, ghost)
	_assert(not _team.is_ghost_name(gname), "復活直後は捕まらない（REVIVE_GRACE）")
	_assert(not (ghost as PhysicsBody3D).get_collision_exceptions().has(h), "復活すると衝突例外が外れる")


func _test_swap() -> void:
	print("\n--- [4] 時間で入れ替え（役割反転・全員復活・CPU の差し替え・新しい鬼の静止） ---")
	var ht: int = _team.hunting_team
	_team._revive_grace.clear()
	_team.on_touch(_pick(ht, true), _pick(1 - ht, false))
	var ghosts_before: int = _team.ghosts.size()
	GameManager.head_start_left = 0.0
	GameManager.time_left = 0.02
	await _frames(6)
	_assert(ghosts_before > 0, "入れ替え前に幽霊がいる")
	_assert(_team.turn == 1, "ターンが進む")
	_assert(_team.hunting_team == 1 - ht, "鬼チームが入れ替わる")
	_assert(_team.ghosts.is_empty(), "幽霊は全員復活")
	_assert(GameManager.head_start_left > 0.0, "新しい鬼は静止する")
	_assert(is_equal_approx(GameManager.time_left, _team.TURN_TIME), "時計が1ターンぶんに戻る")
	var ok := true
	for c in get_tree().get_nodes_in_group("cpu_hunters"):
		if _team.team_of_name(String(c.name)) != _team.hunting_team:
			ok = false
	for c in get_tree().get_nodes_in_group("cpu_runners"):
		if _team.team_of_name(String(c.name)) == _team.hunting_team:
			ok = false
	_assert(ok, "CPU が新しい役のシーンに差し替わる")
	_assert(_team.members(0).size() == 4 and _team.members(1).size() == 4, "差し替え後も4対4")


func _test_wipe() -> void:
	print("\n--- [5] 逃げチームが全員幽霊になったら即決着 ---")
	GameManager.head_start_left = 0.0
	var ht: int = _team.hunting_team
	var h := _pick(ht, true)
	for r in _team.members(1 - ht):
		if GameManager.state == GameManager.State.PLAYING:
			GameManager.report_touch(h, r)
	_assert(GameManager.state == GameManager.State.RESULT, "結果画面へ")
	_assert(GameManager.result_reason == GameManager.EndReason.TEAM_WIPE, "決着は全滅")
	_assert(GameManager.result_runner_won == (ht == 0), "runner_won は「チームAの勝ち」")


func _test_score_and_draw() -> void:
	print("\n--- [6] 最終ターン終了は得点の多い方、同点は引き分け ---")
	await _restart()
	_team.turn = _team.TURNS - 1
	_team.score[0] = 3
	_team.score[1] = 1
	GameManager.head_start_left = 0.0
	GameManager.time_left = 0.02
	await _frames(6)
	_assert(GameManager.state == GameManager.State.RESULT, "最終ターンの終わりで結果へ")
	_assert(GameManager.result_reason == GameManager.EndReason.TEAM_SCORE, "決着は得点")
	_assert(GameManager.result_runner_won, "3対1でチームAの勝ち")
	await _restart()
	_team.turn = _team.TURNS - 1
	_team.score[0] = 2
	_team.score[1] = 2
	GameManager.head_start_left = 0.0
	GameManager.time_left = 0.02
	await _frames(6)
	_assert(GameManager.result_reason == GameManager.EndReason.TEAM_DRAW, "同点は引き分け")


func _test_leave(_world: Node) -> void:
	print("\n--- [7] 抜けた人の穴は同じチーム・同じ役の CPU が埋める ---")
	await _restart()
	var ht: int = _team.hunting_team
	_team.team_of["77"] = 1 - ht
	_team.ghosts["77"] = true
	var before: int = get_tree().get_nodes_in_group("cpu_runners").size()
	_team.on_peer_left(77, Vector3(0, 5, 0))
	await _frames(2)
	_assert(not _team.team_of.has("77"), "抜けた人はチームから外れる")
	_assert(get_tree().get_nodes_in_group("cpu_runners").size() == before + 1, "逃げ役の CPU が1体増える")
	var replaced := false
	for n in _team.ghosts:
		if String(n).begins_with("CPU") and _team.team_of_name(n) == 1 - ht:
			replaced = true
	_assert(replaced, "幽霊だった人の代わりは幽霊の CPU")


func _test_classic_unchanged() -> void:
	print("\n--- [8] 旧モードに戻すと従来どおり 1対3 ---")
	GameManager._back_to_waiting()
	await _frames(3)
	_team.set_enabled(false)
	GameManager.request_start_round()
	await _frames(5)
	_assert(GameManager.runner_id == 1, "ソロは自分が逃走者")
	_assert(get_tree().get_nodes_in_group("cpu_hunters").size() == GameManager.MAX_HUNTERS, "CPU 鬼が定員ぶん")
	_assert(_team.team_of.is_empty(), "チームの表は空")
	GameManager._back_to_waiting()


func _test_result_copy() -> void:
	print("
--- [9] 結果画面の文言（チーム戦） ---")
	var hud: GDScript = load("res://scenes/hud.gd")
	for reason in [GameManager.EndReason.TEAM_WIPE, GameManager.EndReason.TEAM_SCORE,
			GameManager.EndReason.TEAM_DRAW]:
		for won in [true, false]:
			var copy: PackedStringArray = hud.team_result_copy(won, reason)
			_assert(copy.size() == 2 and not copy[0].is_empty() and not copy[1].is_empty(),
				"理由%d・勝ち=%s の文言が空でない" % [reason, won])
	_assert(hud.team_result_copy(true, GameManager.EndReason.TEAM_SCORE)[0] 		!= hud.team_result_copy(false, GameManager.EndReason.TEAM_SCORE)[0], "勝ちと負けで見出しが違う")


# --- 実セーブの保護（tests/save_guard.gd のヘッダを参照） ---
const _SaveGuard := preload("res://tests/save_guard.gd")
var _save_backup := {}


func _enter_tree() -> void:
	_save_backup = _SaveGuard.backup()


func _exit_tree() -> void:
	_SaveGuard.restore(_save_backup)
