extends Node

## EOS Live Lobby + P2P Gift Smoke Test — 実クレデンシャル・実バックエンド接続専用。
## 2プロセス(host/join)を同一PC上で別々の --user-data-dir から起動し、
## 「見知らぬ相手同士」のEOS Lobbyマッチングと、EOS P2P(GiftManager)経由の
## 実際のパケット往復が成立するかを確認する。自動テストスイート・CIの対象には含めない
## (実バックエンドへ都度ロビーを作成する副作用があるため、既存のtest_eos_lobby_mock.gd
## と同じ理由で手動実行専用とする)。
##
## 実行例(PowerShell、2プロセスを別々に起動する):
##   godot --headless --user-data-dir <dirA> --path . \
##       res://tests/test_eos_live_lobby_p2p.tscn -- host RUNTAG_XXXX
##   godot --headless --user-data-dir <dirB> --path . \
##       res://tests/test_eos_live_lobby_p2p.tscn -- join RUNTAG_XXXX
##
## run_tagはロビー名に埋め込まれ、join側はこのタグで検索することで
## lobby_id/PUIDのファイル受け渡しを不要にしている。

var passed_count := 0
var failed_count := 0
var _role := "host"


func _assert(condition: bool, msg: String) -> void:
	if condition:
		print("  [%s][OK] %s" % [_role, msg])
		passed_count += 1
	else:
		printerr("  [%s][FAIL] %s" % [_role, msg])
		failed_count += 1


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_role = args[0] if args.size() > 0 else "host"
	var run_tag: String = args[1] if args.size() > 1 else "RUNTAG_DEFAULT"

	print("==================================================")
	print("【TEST】EOS Live Lobby + P2P Gift Smoke Test [%s] tag=%s" % [_role, run_tag])
	print("==================================================")
	await get_tree().process_frame

	# 注意: EosManager._init_eos()はis_eos_available=true設定後、eos_initialized
	# 発火前にsync_profile_with_cloud()(PDS読み書き)を内部実行する。実機検証の結果、
	# このPDS書き込みが(恐らくClient PolicyでPlayer Data Storage機能が未有効なため)
	# 応答なくハングする既知の問題を確認済み。ロビー/P2P検証はPDSに依存しないため、
	# eos_initializedシグナル(PDS完了待ち)ではなくis_eos_availableのポーリングで進める
	var elapsed := 0.0
	while not EosManager.is_eos_available and elapsed < 20.0:
		await get_tree().create_timer(0.5).timeout
		elapsed += 0.5

	if not EosManager.is_eos_available:
		printerr("[%s][FAIL] EOS is not available" % _role)
		failed_count += 1
		_finish()
		return

	print("[%s] PUID=%s" % [_role, EosManager.product_user_id])

	if _role == "host":
		await _run_host(run_tag)
	else:
		await _run_join(run_tag)

	_finish()


func _run_host(run_tag: String) -> void:
	var captured := {}
	var cb := func(status: int, lobby_id: String) -> void:
		captured["status"] = status
		captured["id"] = lobby_id
	EosManager.lobby_created.connect(cb, CONNECT_ONE_SHOT)
	EosManager.create_lobby(0, 2, "LIVETEST-%s" % run_tag)
	await _wait_until(func() -> bool: return captured.has("id"), 15.0)
	_assert(captured.get("status") == 1, "create_lobby() が成功する(status=%s)" % captured.get("status"))
	if captured.get("status") != 1:
		return

	var lobby: HLobby = EosManager._current_lobby
	_assert(lobby != null, "_current_lobbyが取得できる")
	if lobby == null:
		return

	var joined := await _wait_until(func() -> bool: return lobby.members.size() >= 2, 40.0)
	_assert(joined, "相手が実際にロビーへ参加した(members=%d)" % lobby.members.size())

	if joined:
		await _try_gift_roundtrip(lobby)

	await EosManager.leave_lobby()


func _run_join(run_tag: String) -> void:
	# ホストが部屋を作り終えるまで少し待ってから検索する
	await get_tree().create_timer(3.0).timeout

	var found_id := ""
	var deadline := 30.0
	var elapsed := 0.0
	while found_id.is_empty() and elapsed < deadline:
		var lobbies: Array = []
		var got := false
		var cb := func(l: Array) -> void:
			lobbies = l
			got = true
		EosManager.lobby_match_list.connect(cb, CONNECT_ONE_SHOT)
		EosManager.request_lobby_list()
		await _wait_until(func() -> bool: return got, 8.0)
		for l in lobbies:
			if String(l.get("name", "")).contains(run_tag):
				found_id = String(l["id"])
				break
		if found_id.is_empty():
			await get_tree().create_timer(2.0).timeout
			elapsed += 2.0

	_assert(not found_id.is_empty(), "request_lobby_list()でホストの部屋をタグ検索で発見できた")
	if found_id.is_empty():
		return

	var joined_res := {}
	var cb2 := func(id: String, _perm: int, _locked: bool, resp: int) -> void:
		joined_res["id"] = id
		joined_res["resp"] = resp
	EosManager.lobby_joined.connect(cb2, CONNECT_ONE_SHOT)
	EosManager.join_lobby(found_id)
	await _wait_until(func() -> bool: return joined_res.has("resp"), 15.0)
	_assert(joined_res.get("resp") == 1, "join_lobby() が成功する(response=%s)" % joined_res.get("resp"))
	if joined_res.get("resp") != 1:
		return

	var lobby: HLobby = EosManager._current_lobby
	var ready := await _wait_until(func() -> bool: return lobby != null and lobby.members.size() >= 2, 10.0)
	_assert(ready, "自分から見てもmembers=2になった")

	if ready:
		await _try_gift_roundtrip(lobby)

	await EosManager.leave_lobby()


func _try_gift_roundtrip(lobby: HLobby) -> void:
	var my_puid := EosManager.product_user_id
	var peer_puid := ""
	for m in lobby.members:
		if m.product_user_id != my_puid:
			peer_puid = m.product_user_id
			break
	_assert(not peer_puid.is_empty(), "相手のPUIDをロビーメンバーから取得できた: %s" % peer_puid)
	if peer_puid.is_empty():
		return

	# GiftManagerの_gift_peerはEosManager.eos_initialized(true)を合図に生成される
	var peer_ready := await _wait_until(func() -> bool: return GiftManager._gift_peer != null, 10.0)
	_assert(peer_ready, "GiftManager._gift_peerが生成されている")
	if not peer_ready:
		return

	var received: Array = []
	var recv_cb := func(kind: StringName, id: StringName, from_name: String) -> void:
		received.append([kind, id, from_name])
	GiftManager.gift_received.connect(recv_cb)

	var ok: bool = await GiftManager.send_gift(peer_puid, &"costume", CostumeCatalog.DEFAULT_ID)
	_assert(ok, "GiftManager.send_gift()がack受領まで成功した(実EOS P2P mesh)")

	# 相手からのギフトが先に届いていた可能性もあるので少し待って確認する
	await get_tree().create_timer(1.0).timeout
	print("[%s] received_count=%d" % [_role, received.size()])


func _wait_until(predicate: Callable, timeout_sec: float) -> bool:
	var elapsed := 0.0
	while not predicate.call() and elapsed < timeout_sec:
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2
	return predicate.call()


func _finish() -> void:
	print("==================================================")
	print("[%s] EOS Live Lobby + P2P Gift Smoke Test 結果: PASS=%d, FAIL=%d" % [_role, passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> [%s] ALL PASSED" % _role)
	else:
		printerr("=> [%s] SOME TESTS FAILED" % _role)
	get_tree().quit()
