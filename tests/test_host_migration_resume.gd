extends Node

## ホスト引き継ぎ後の「進行中ラウンドの再開」の検証スクリプト
##
## 実ネットワーク・実EOSロビーは張らず、GameManager/HostMigrationのAPIを OfflineMultiplayerPeer
## のまま直接叩く(tests/test_phase8_host_migration.gdと同じ流儀)。call_localのRPCは
## オフラインでもローカル実行される。実バックエンドへ通信する経路(report_disconnect_penalty等)は踏まない。

var passed_count := 0
var failed_count := 0

var _saved_puid := ""


## snapshot_for_resume()が読む最小限の項目だけを持つプレイヤーの代用品
class _DummyPlayer extends Node3D:
	var stamina := 55.0
	var item := 2

	func teleport(_pos: Vector3) -> void:
		pass


func _assert(condition: bool, msg: String) -> void:
	if condition:
		print("  [OK] %s" % msg)
		passed_count += 1
	else:
		printerr("  [FAIL] %s" % msg)
		failed_count += 1


func _ready() -> void:
	print("==================================================")
	print("【TEST】ホスト引き継ぎ後のラウンド再開")
	print("==================================================")
	await get_tree().process_frame
	_saved_puid = EosManager.product_user_id

	_test_snapshot_empty_unless_playing()
	_test_snapshot_contents()
	_test_resolve_resume_runner()
	await _test_resume_flow()
	_test_addr_timeout_longer_than_wait()

	EosManager.product_user_id = _saved_puid
	GameManager.reset()
	print("==================================================")
	print("再開テスト結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> Resume: ALL PASSED")
	else:
		printerr("=> Resume: SOME TESTS FAILED")
	get_tree().quit()


func _add_dummy(peer_id: int, pos := Vector3.ZERO) -> _DummyPlayer:
	var p := _DummyPlayer.new()
	p.name = str(peer_id)
	add_child(p)
	p.add_to_group("players")
	p.global_position = pos
	return p


func _remove_dummies() -> void:
	for p in get_tree().get_nodes_in_group("players"):
		p.remove_from_group("players")
		p.free()  # queue_free だと同名の次のダミーが改名されてしまう


## 1. PLAYING以外ではスナップショットは空(従来どおり準備中へ戻す)
func _test_snapshot_empty_unless_playing() -> void:
	print("\n--- [1] PLAYING以外ではsnapshot_for_resume()が空 ---")
	GameManager.reset()
	_assert(GameManager.snapshot_for_resume().is_empty(), "WAITINGでは空")
	GameManager.state = GameManager.State.RESULT
	_assert(GameManager.snapshot_for_resume().is_empty(), "RESULTでは空")
	GameManager.reset()


## 2. PLAYING中のスナップショットに時間・役割・生存者のpuid・自分の状態が入る
func _test_snapshot_contents() -> void:
	print("\n--- [2] PLAYING中のスナップショットの中身 ---")
	GameManager.reset()
	GameManager._start_round(99, 0.9, 3, {99: Vector3.ZERO}, true)
	GameManager.round_is_ranked = true
	GameManager.time_left = 120.0
	GameManager.world_time = 33.0
	GameManager.peer_profiles = {
		1: {"name": "Host", "puid": "p-host"},
		2: {"name": "A", "puid": "p-a"},
		99: {"name": "Runner", "puid": "p-runner"},
	}
	_add_dummy(1, Vector3(1, 0, 1))
	_add_dummy(2)
	_add_dummy(99, Vector3(5, 0, 7))
	EosManager.product_user_id = "p-a"

	var snap: Dictionary = GameManager.snapshot_for_resume()
	_assert(not snap.is_empty(), "PLAYING中は空でない")
	_assert(is_equal_approx(float(snap.get("time_left", -1.0)), 120.0), "残り時間が入る")
	_assert(snap.get("round_is_ranked") == true, "round_is_rankedが入る")
	_assert(is_equal_approx(float(snap.get("world_time", -1.0)), 33.0), "world_timeが入る")
	_assert(int(snap.get("hunter_count", 0)) == 3, "鬼の人数が入る")
	_assert(snap.get("runner_puid") == "p-runner", "逃走者のpuidが入る")
	_assert(snap.get("runner_is_cpu") == false, "逃走者は人間")
	var survivors: Array = snap.get("survivor_puids", [])
	_assert(survivors.has("p-a") and survivors.has("p-runner") and not survivors.has("p-host"),
		"survivor_puidsは旧ホスト(peer_id 1)を含まない")
	var me: Dictionary = snap.get("me", {})
	_assert(is_equal_approx(float(me.get("stamina", -1.0)), 55.0) and int(me.get("item", -1)) == 2,
		"自分(puidで特定したpeer 2)のスタミナ・アイテムが入る")

	_remove_dummies()
	GameManager.reset()


## 3. 逃走者の引き直し
func _test_resolve_resume_runner() -> void:
	print("\n--- [3] resolve_resume_runner() ---")
	var H := GameManager._HostMigrationScript
	var snap := {"runner_is_cpu": false, "runner_puid": "p-a"}
	_assert(H.resolve_resume_runner(snap, {"p-a": 7, "p-b": 8}) == 7, "生存していれば新しいpeer_id")
	_assert(H.resolve_resume_runner(snap, {"p-b": 8}) == GameManager.CPU_RUNNER_ID, "戻らなければCPU")
	_assert(H.resolve_resume_runner({"runner_is_cpu": true, "runner_puid": "p-a"}, {"p-a": 7})
		== GameManager.CPU_RUNNER_ID, "元からCPUならCPU")
	_assert(H.resolve_resume_runner({"runner_is_cpu": false, "runner_puid": ""}, {"p-a": 7})
		== GameManager.CPU_RUNNER_ID, "puidが無ければCPU")


## 4. 再開待ち中は新ラウンドを始められず、全員のpuidが届いたら状態が保たれたまま再開する
func _test_resume_flow() -> void:
	print("\n--- [4] 再開待ちと再開 ---")
	GameManager.reset()
	EosManager.product_user_id = "p-self"
	var snap := {
		"time_left": 100.0, "head_start_left": 0.0, "hunter_mult": 0.9, "hunter_count": 3,
		"round_hunter_count": 3, "round_is_ranked": true, "spotted_zone": -1, "intel_left": 0.0,
		"world_time": 42.0, "runner_is_cpu": false, "runner_puid": "p-a", "runner_name": "A",
		"runner_pos": Vector3.ZERO, "survivor_puids": ["p-self", "p-a", "p-b"],
		"cpu_hunters": [], "me": {},
	}
	var hm = GameManager._host_migration
	hm.begin_resume(snap)
	_assert(hm.resume_pending, "begin_resume()後はresume_pendingがtrue")

	# 人間が1人いないと request_start_round() は早期returnして、ガードが無くても通ってしまう
	_add_dummy(1)
	GameManager.request_start_round()
	_assert(GameManager.state != GameManager.State.PLAYING, "再開待ちの間はrequest_start_round()が効かない")

	GameManager.peer_profiles = {1: {"puid": "p-self"}, 5: {"puid": "p-a"}}
	hm.on_profile_reported()
	_assert(hm.resume_pending, "待っているpuidが揃うまでは再開しない")

	GameManager.peer_profiles[6] = {"puid": "p-b"}
	hm.on_profile_reported()
	_assert(not hm.resume_pending, "全員揃ったら再開してpendingが下りる")
	_assert(GameManager.state == GameManager.State.PLAYING, "再開後はPLAYING")
	_assert(is_equal_approx(GameManager.time_left, 100.0), "残り時間が保たれる")
	_assert(GameManager.round_is_ranked, "round_is_rankedが保たれる")
	_assert(is_equal_approx(GameManager.world_time, 42.0), "world_timeが保たれる")
	_assert(GameManager.runner_id == 5, "逃走者が新しいpeer_idに引き直される")

	hm.cancel_resume()
	_remove_dummies()
	GameManager.reset()


## 5. アドレス待ちの見張りタイマーは、アドレス待ち自体より長い
func _test_addr_timeout_longer_than_wait() -> void:
	print("\n--- [5] MIGRATION_ADDR_TIMEOUT_SEC ---")
	_assert(NetworkManager.MIGRATION_ADDR_TIMEOUT_SEC > NetworkManager.MIGRATION_ADDR_WAIT_SEC,
		"見張りタイマーがアドレス待ちより長い")


# --- Phase 3 L-12: 実セーブ(user://profile.json / settings.json)の保護 ---
# 詳細は tests/save_guard.gd のヘッダを参照。
const _SaveGuard := preload("res://tests/save_guard.gd")
var _save_backup := {}


func _enter_tree() -> void:
	_save_backup = _SaveGuard.backup()


func _exit_tree() -> void:
	_SaveGuard.restore(_save_backup)
