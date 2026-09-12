extends Node

## EOS Live Smoke Test — 実クレデンシャル・実バックエンド接続専用の手動実行テスト。
##
## 既存の test_eos_*_mock.gd とは逆に、is_eos_available == false(オフライン/未設定)
## の場合はFAILとして報告する(このテストの目的自体が「実際にEOSへ繋がるか」の
## 確認であるため)。eos_credentials.cfg に実クレデンシャルが設定されているPCで
## 手動実行することを前提とし、自動テストスイート・CIの対象には含めない。
##
## 実機検証で判明した既知の問題: EosManager._init_eos()はis_eos_available=true
## 設定後、eos_initialized発火前にsync_profile_with_cloud()(PDS書き込み)を内部
## 実行するが、このPDS書き込みが応答なくハングする(Client PolicyでPlayer Data
## Storage機能が未有効な可能性)。そのためeos_initializedではなくis_eos_available
## のポーリングで進み、各サブテストは fire-and-forget + タイムアウト方式にして、
## 個々のハングが後続のテストや全体の結果表示をブロックしないようにしている。
## それでもプロセス自体は内部同期がハングしたままquit()後も終了しない可能性が
## あるため、実行側は結果ログ確認後にプロセスを強制終了すること。
##
## 実行: godot --headless --path . res://tests/test_eos_live_smoke.tscn

var passed_count := 0
var failed_count := 0

func _assert(condition: bool, msg: String) -> void:
	if condition:
		print("  [OK] %s" % msg)
		passed_count += 1
	else:
		printerr("  [FAIL] %s" % msg)
		failed_count += 1


func _ready() -> void:
	print("==================================================")
	print("【TEST】EOS Live Smoke Test(実バックエンド接続)")
	print("==================================================")
	await get_tree().process_frame

	var elapsed := 0.0
	while not EosManager.is_eos_available and elapsed < 20.0:
		await get_tree().create_timer(0.5).timeout
		elapsed += 0.5

	if not EosManager.is_eos_available:
		printerr("[FAIL] EOS is not available (eos_credentials.cfg 未設定 or 初期化失敗)")
		failed_count += 1
		_finish()
		return

	_assert(not EosManager.product_user_id.is_empty(), "PUIDが払い出された")
	print("PUID=%s" % EosManager.product_user_id)

	await _test_cloud_save_roundtrip()
	await _test_leaderboard()

	_finish()


## 既存プロフィールをそのまま再アップロード→読み戻して一致を確認する。
## 合成データで上書きしない(実データを破壊しない安全策)。
## write_file_async等が応答なくハングする既知の問題があるため、実処理は
## _cloud_save_worker()にfire-and-forgetで投げ、ここでは結果をタイムアウト付きで待つ
func _test_cloud_save_roundtrip() -> void:
	print("\n--- [1] Cloud Save (Player Data Storage) live疎通 ---")
	var result := {}
	_cloud_save_worker(result)  # awaitしない(ハングしても後続をブロックしない)
	var finished := await _wait_until(func() -> bool: return result.has("done"), 15.0)
	if not finished:
		_assert(false, "cloud save往復が15秒以内に完了する(既知の問題: PDS書き込みがハングする可能性あり)")
		return
	_assert(result.get("write_ok", false), "cloud_save_profile() が成功する")
	_assert(result.get("ts", 0) != 0, "cloud_file_timestamp() が非0を返す")
	_assert(result.get("readback_match", false), "書き込んだJSONがそのまま読み戻る")


func _cloud_save_worker(result: Dictionary) -> void:
	var before := await EosManager.cloud_load_profile()
	var current_json := JSON.stringify(ProfileManager.to_save_dict())

	var write_ok: bool = await EosManager.cloud_save_profile(current_json)
	var ts: int = await EosManager.cloud_file_timestamp()
	var readback := await EosManager.cloud_load_profile()

	result["write_ok"] = write_ok
	result["ts"] = ts
	result["readback_match"] = (readback == current_json)

	# 安全網: 元の内容と異なっていた場合(既存データがあった場合)は復元しておく
	if not before.is_empty() and before != current_json:
		await EosManager.cloud_save_profile(before)
		print("  NOTE: 元のクラウドデータへ復元しました")

	result["done"] = true


func _test_leaderboard() -> void:
	print("\n--- [2] Leaderboard live疎通 ---")
	var lb_result := {}
	_leaderboard_worker(lb_result)  # 同様にfire-and-forget
	var finished := await _wait_until(func() -> bool: return lb_result.has("done"), 15.0)
	if not finished:
		_assert(false, "leaderboard疎通が15秒以内に完了する(既知の問題: 応答ハングの可能性あり)")
		return
	_assert(lb_result.get("entries_ok", false), "request_leaderboard() が完了する(entries=%d件)" % lb_result.get("entries_count", -1))
	if lb_result.get("entries_count", -1) == 0:
		print("  NOTE: 0件 = Developer PortalでStat/Leaderboard定義が未作成の可能性(想定内)")
	_assert(lb_result.get("upload_ok", false), "upload_rating() が完了する(success=%s)" % lb_result.get("upload_success"))


func _leaderboard_worker(result: Dictionary) -> void:
	var entries: Array = []
	var got_entries := false
	var cb := func(e: Array) -> void:
		entries = e
		got_entries = true
	EosManager.leaderboard_loaded.connect(cb, CONNECT_ONE_SHOT)
	EosManager.request_leaderboard()
	await _wait_until(func() -> bool: return got_entries, 10.0)
	result["entries_ok"] = got_entries
	result["entries_count"] = entries.size() if got_entries else -1

	var captured := {}
	var cb2 := func(ok: bool, score: int) -> void:
		captured["ok"] = ok
		captured["score"] = score
	EosManager.leaderboard_score_uploaded.connect(cb2, CONNECT_ONE_SHOT)
	EosManager.upload_rating(ProfileManager.rating)
	await _wait_until(func() -> bool: return captured.has("ok"), 10.0)
	result["upload_ok"] = captured.has("ok")
	result["upload_success"] = captured.get("ok", false)
	result["done"] = true


func _wait_until(predicate: Callable, timeout_sec: float) -> bool:
	var elapsed := 0.0
	while not predicate.call() and elapsed < timeout_sec:
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2
	return predicate.call()


func _finish() -> void:
	print("==================================================")
	print("EOS Live Smoke Test 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> EOS Live Smoke Test: ALL PASSED")
	else:
		printerr("=> EOS Live Smoke Test: SOME TESTS FAILED")
	get_tree().quit()
