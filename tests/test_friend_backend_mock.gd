extends Node

## Friend Backend (Offline/Mock) 動作検証スクリプト
##
## USE_LIVE_FRIEND_BACKEND == false(オフラインモック)の分岐のみを検証する。
## HTTPコールはawaitで直接待てるため、EOS系テストのような可用性ポーリングは
## 不要。ただし手元でUSE_LIVE_FRIEND_BACKENDをtrueに書き換えた状態で誤って
## 実バックエンドへ発火しないよう、既存テストと同じ「スキップ」ガード構造は残す。

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
	print("【TEST】Friend Backend Offline/Fallback 動作検証")
	print("==================================================")
	await get_tree().process_frame

	if FriendManager.USE_LIVE_FRIEND_BACKEND:
		print("USE_LIVE_FRIEND_BACKEND == true のため、オフラインモック専用の以下の検証はスキップします")
	else:
		await _test_sync_with_backend()
		await _test_get_friends()
		await _test_get_pending_requests()
		await _test_send_friend_request()
		await _test_respond_to_request()
		await _test_remove_friend()
		await _test_invite_to_lobby()

	print("==================================================")
	print("Friend Backend Mock 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> Friend Backend Mock: ALL PASSED")
	else:
		printerr("=> Friend Backend Mock: SOME TESTS FAILED")
	get_tree().quit()


func _test_sync_with_backend() -> void:
	print("\n--- [1] sync_with_backend() Offline/Fallback ---")
	var code: String = await FriendManager.sync_with_backend()
	_assert(not code.is_empty(), "フレンドコードが非空のStringで返る")


func _test_get_friends() -> void:
	print("\n--- [2] get_friends() Offline/Fallback ---")
	var friends: Array = await FriendManager.get_friends()
	_assert(friends.size() == 3, "モックフレンドが3件返る")
	for f in friends:
		_assert(typeof(f.get("id")) == TYPE_STRING, "各フレンドの id が String 型(PUID)")
		_assert(typeof(f.get("online")) == TYPE_BOOL, "各フレンドの online が bool 型")


func _test_get_pending_requests() -> void:
	print("\n--- [3] get_pending_requests() Offline/Fallback ---")
	var requests: Array = await FriendManager.get_pending_requests()
	_assert(requests.size() == 1, "モックの保留中リクエストが1件返る")
	if not requests.is_empty():
		var r: Dictionary = requests[0]
		_assert(r.has("request_id") and r.has("from_puid") and r.has("from_name"), "リクエストのキーが揃っている")


func _test_send_friend_request() -> void:
	print("\n--- [4] send_friend_request() Offline/Fallback ---")
	var empty_res: Dictionary = await FriendManager.send_friend_request("")
	_assert(empty_res.get("ok") == false, "空コードでの送信は ok == false")
	_assert(empty_res.get("reason") == "invalid_code", "空コードでの送信は reason == invalid_code")

	var ok_res: Dictionary = await FriendManager.send_friend_request("ANYCODE")
	_assert(ok_res.get("ok") == true, "非空コードでの送信は ok == true (モック)")
	_assert(not String(ok_res.get("target_name", "")).is_empty(), "target_name が非空で返る")


func _test_respond_to_request() -> void:
	print("\n--- [5] respond_to_request() Offline/Fallback ---")
	_assert(await FriendManager.respond_to_request("fake-id", true) == true, "承諾(モック)は true を返す")
	_assert(await FriendManager.respond_to_request("fake-id", false) == true, "拒否(モック)は true を返す")


func _test_remove_friend() -> void:
	print("\n--- [6] remove_friend() Offline/Fallback ---")
	_assert(await FriendManager.remove_friend("mock-puid-1") == true, "remove_friend(モック)は true を返す")


func _test_invite_to_lobby() -> void:
	print("\n--- [7] invite_to_lobby() ---")
	EosManager.leave_lobby()
	_assert(await FriendManager.invite_to_lobby() == false, "ロビー未参加時は invite_to_lobby() == false")

	if not EosManager.is_eos_available:
		EosManager.create_lobby(2, 8, "TestRoom")
		_assert(await FriendManager.invite_to_lobby() == true, "ロビー参加中(オフラインモック)は invite_to_lobby() == true")
		EosManager.leave_lobby()
	else:
		print("EOS利用可能環境のため、実ロビー作成を伴う招待検証はスキップします")
