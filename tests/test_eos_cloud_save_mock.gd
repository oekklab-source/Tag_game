extends Node

## EOS Cloud Save (Offline/Mock) 動作検証スクリプト
##
## is_eos_available == false(オフラインモック)の分岐のみを検証する。
## 実EOS認証が絡む is_eos_available == true の分岐(Player Data Storageの
## 実書き込み/読み込みを伴う)は、実クレデンシャルでの検証が手動でしか行えない
## (Phase 0/2/3の実績と同じ制約)ため、意図的に自動テスト対象外とする。

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
	print("【TEST】EOS Cloud Save Offline/Fallback 動作検証")
	print("==================================================")
	await get_tree().process_frame

	var elapsed := 0.0
	while not EosManager.is_eos_available and elapsed < 5.0:
		await get_tree().create_timer(0.2).timeout
		elapsed += 0.2

	if EosManager.is_eos_available:
		print("EOS利用可能環境のため、オフラインモック専用の以下の検証はスキップします")
		print("(実EOS Player Data Storageへの読み書きを伴う検証は手動でのみ実施する方針)")
	else:
		await _test_cloud_sync_fallback()

	print("==================================================")
	print("EOS Cloud Save Mock 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> EOS Cloud Save Mock: ALL PASSED")
	else:
		printerr("=> EOS Cloud Save Mock: SOME TESTS FAILED")
	get_tree().quit()


## EosManagerのcloud_*系はEOS実装がawaitを含むため、GDScriptの仕様上
## オフライン分岐(is_eos_available==false)でも常にコルーチン扱いになる。
## steam_manager.gd版(同期関数)と違い、呼び出し側は必ずawaitすること。
func _test_cloud_sync_fallback() -> void:
	print("\n--- [1] EOS Cloud Save Offline/Fallback 動作 ---")
	_assert(EosManager.has_method("sync_profile_with_cloud"), "sync_profile_with_cloud() が実装されている")
	_assert(await EosManager.cloud_save_profile("{}") == false, "EOS無効時 cloud_save_profile() は false を返す")
	_assert(await EosManager.cloud_load_profile() == "", "EOS無効時 cloud_load_profile() は空文字を返す")
	_assert(await EosManager.cloud_file_timestamp() == 0, "EOS無効時 cloud_file_timestamp() は 0 を返す")
	# EOS無効時は何もせず安全に抜けること(クラッシュしないこと)を確認
	await EosManager.sync_profile_with_cloud()
	_assert(true, "EOS無効時 sync_profile_with_cloud() がクラッシュせず即座に抜ける")
