extends Node

## Gift Manager (Offline/Mock) 動作検証スクリプト
##
## EosManager.is_eos_available == false(オフライン、EOS未接続)の分岐のみを検証する。
## GiftManagerはEosManager.eos_initialized(true)を合図に初めて_gift_peer
## (EOSGMultiplayerPeer)を生成するため、EOSが利用可能な環境では実際にEOS P2P mesh
## ピアを介した通信が走ってしまう。実クレデンシャルが存在するこの手元環境で誤って
## 実EOSバックエンドへ接続することを避けるため、既存のEOS系テストと同じ
## 「実EOS利用可能ならスキップ」ガード構造にする。

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
	print("【TEST】Gift Manager Offline/Fallback 動作検証")
	print("==================================================")
	await get_tree().process_frame

	# EosManagerの初期化は非同期。is_eos_availableがtrueになる経路は必ず
	# awaitを経由するため、ここでポーリングして待っても「既に完了済みの
	# false分岐」を取りこぼす心配はない(false→trueにしか遷移しないため)
	var elapsed := 0.0
	while not EosManager.is_eos_available and elapsed < 5.0:
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2

	if EosManager.is_eos_available:
		print("EOS利用可能環境のため、オフラインモック専用の以下の検証はスキップします")
		print("(実EOS P2P meshピア接続を伴う検証は手動でのみ実施する方針)")
	else:
		await _test_gift_peer_not_created()
		await _test_send_gift_without_peer()
		await _test_send_gift_empty_puid()

	print("==================================================")
	print("Gift Manager Mock 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> Gift Manager Mock: ALL PASSED")
	else:
		printerr("=> Gift Manager Mock: SOME TESTS FAILED")
	get_tree().quit()


func _test_gift_peer_not_created() -> void:
	print("\n--- [1] _gift_peer Offline/Fallback ---")
	_assert(GiftManager._gift_peer == null, "EOS未接続時は_gift_peerがnullのまま(EOSGMultiplayerPeerを生成しない)")


func _test_send_gift_without_peer() -> void:
	print("\n--- [2] send_gift() _gift_peer未確立時 ---")
	var ok: bool = await GiftManager.send_gift("some-puid", &"costume", &"some_id")
	_assert(ok == false, "_gift_peerが未確立のときsend_gift()は即falseを返す(ハングしない)")


func _test_send_gift_empty_puid() -> void:
	print("\n--- [3] send_gift() 空文字列PUID ---")
	var ok: bool = await GiftManager.send_gift("", &"costume", &"some_id")
	_assert(ok == false, "空文字列PUIDでのsend_gift()はfalseを返す(クラッシュしない)")
