extends Node

## EOS Lobby (Offline/Mock) 動作検証スクリプト
##
## is_eos_available == false(オフラインモック)の分岐のみを検証する。
## 実EOS認証が絡む is_eos_available == true の分岐は、実クレデンシャルでの
## 検証が手動でしか行えない(Phase 0の実績と同じ制約)ことに加え、このテストを
## 自動実行するたびに実際のEOSバックエンドへロビーを作成してしまう副作用を
## 避けるため、意図的に自動テスト対象外としスキップする。

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
	print("【TEST】EOS Lobby Offline/Fallback 動作検証")
	print("==================================================")
	await get_tree().process_frame

	# EosManagerの初期化(EOS Platform setup + Connect匿名ログイン)は非同期。
	# is_eos_available が true になる経路は必ず await を経由するため、
	# ここでポーリングして待っても「既に完了済みのfalse分岐」を取りこぼす
	# 心配はない(false→trueにしか遷移しないため)
	var elapsed := 0.0
	while not EosManager.is_eos_available and elapsed < 5.0:
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2

	if EosManager.is_eos_available:
		print("EOS利用可能環境のため、オフラインモック専用の以下の検証はスキップします")
		print("(実EOSロビー作成を伴う検証は手動でのみ実施する方針)")
	else:
		await _test_create_lobby()
		await _test_request_lobby_list()
		await _test_join_lobby()
		await _test_leave_lobby()

	print("==================================================")
	print("EOS Lobby Mock 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> EOS Lobby Mock: ALL PASSED")
	else:
		printerr("=> EOS Lobby Mock: SOME TESTS FAILED")
	get_tree().quit()


## モック分岐はawaitを挟まず同期的にシグナルを発火するため、
## CONNECT_ONE_SHOTで発火直後の引数をそのまま捕捉できる
func _test_create_lobby() -> void:
	print("\n--- [1] create_lobby() Offline/Fallback ---")
	# 注意: ラムダは外側のローカル変数を値渡しでキャプチャするため、
	# `captured = {...}` のような再代入は外側へ伝播しない。
	# 既存のDictionary/Arrayのキー・要素を書き換える形にする必要がある
	var captured := {}
	var cb := func(status: int, lobby_id: String) -> void:
		captured["connect_status"] = status
		captured["lobby_id"] = lobby_id
	EosManager.lobby_created.connect(cb, CONNECT_ONE_SHOT)
	EosManager.create_lobby(2, 8, "TestRoom")

	_assert(captured.has("lobby_id"), "lobby_created シグナルが同期的に発火する(オフラインモック)")
	var lobby_id: String = String(captured.get("lobby_id", ""))
	_assert(not lobby_id.is_empty(), "lobby_created が非空のString lobby_idで発火する")
	_assert(captured.get("connect_status") == 1, "connect_status == 1 (成功)")
	_assert(EosManager.is_host == true, "作成者は is_host == true になる")
	_assert(EosManager.current_lobby_id == lobby_id, "current_lobby_id が lobby_created 発火時の id と一致する")


func _test_request_lobby_list() -> void:
	print("\n--- [2] request_lobby_list() Offline/Fallback ---")
	var captured_lobbies: Array = []
	var cb := func(lobbies: Array) -> void:
		captured_lobbies.append_array(lobbies)
	EosManager.lobby_match_list.connect(cb, CONNECT_ONE_SHOT)
	EosManager.request_lobby_list()

	_assert(captured_lobbies.size() == 3, "モックロビーが3件返る")
	for lobby in captured_lobbies:
		_assert(typeof(lobby.get("id")) == TYPE_STRING, "各ロビーの id が String 型")


func _test_join_lobby() -> void:
	print("\n--- [3] join_lobby() Offline/Fallback ---")
	var captured := {}
	var cb := func(lobby_id: String, _permissions: int, _locked: bool, response: int) -> void:
		captured["lobby_id"] = lobby_id
		captured["response"] = response
	EosManager.lobby_joined.connect(cb, CONNECT_ONE_SHOT)
	EosManager.join_lobby("mock-9999")

	_assert(captured.get("response") == 1, "join_lobby(オフライン時)は response == 1 で成功する")
	_assert(EosManager.is_host == false, "参加者は is_host == false になる")
	_assert(EosManager.current_lobby_id == "mock-9999", "current_lobby_id が参加した id と一致する")


func _test_leave_lobby() -> void:
	print("\n--- [4] leave_lobby() ---")
	EosManager.leave_lobby()
	_assert(EosManager.current_lobby_id == "", "leave_lobby() 後 current_lobby_id が空文字になる")
	_assert(EosManager.is_host == false, "leave_lobby() 後 is_host が false になる")
