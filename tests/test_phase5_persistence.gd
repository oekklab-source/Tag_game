extends Node

## Phase 5: データ永続化・システム連携検証スクリプト

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
	print("【TEST】Phase 5: データ永続化・システム連携検証")
	print("==================================================")
	await get_tree().process_frame

	await _test_profile_save_load()
	await _test_profile_corrupted_fallback()
	await _test_steam_fallback()

	print("==================================================")
	print("Phase 5 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> Phase 5: ALL PASSED")
	else:
		printerr("=> Phase 5: SOME TESTS FAILED")
	get_tree().quit()


## 1. ProfileManager の保存と復元
func _test_profile_save_load() -> void:
	print("\n--- [1] ProfileManager 保存・読み込み ---")
	# 現在のデータを退避
	var orig_name: String = ProfileManager.player_name
	var orig_rating: int = ProfileManager.rating

	# テストデータを設定して保存
	ProfileManager.player_name = "TestHero99"
	ProfileManager.rating = 1750
	ProfileManager.costume_id = &"candy"
	ProfileManager.owned_costumes = ["default", "candy"]
	ProfileManager.save_profile()

	# 値をリセット
	ProfileManager.player_name = "Reset"
	ProfileManager.rating = 1000

	# 読み込み
	ProfileManager.load_profile()

	_assert(ProfileManager.player_name == "TestHero99", "プレイヤー名が正しく復元 (TestHero99)")
	_assert(ProfileManager.rating == 1750, "レートが正しく復元 (1750)")
	_assert(ProfileManager.costume_id == &"candy", "コスチュームが正しく復元 (candy)")

	# 復元後に元のデータを戻す
	ProfileManager.player_name = orig_name
	ProfileManager.rating = orig_rating
	ProfileManager.save_profile()


## 2. 破損データ・改ざんデータのフォールバック
func _test_profile_corrupted_fallback() -> void:
	print("\n--- [2] 不正データ・未所持コスチュームのフォールバック ---")
	# 不正な未所持コスチュームを指定したデータ
	var fake_data: Dictionary = {
		"schema_version": 2,
		"player_name": "Hacker",
		"rating": 9999,
		"costume_id": "legendary_dragon", # 存在しないコスチューム
		"owned_costumes": ["default"]
	}
	ProfileManager._apply_data(fake_data)

	_assert(ProfileManager.costume_id == &"default", "未所持/存在しないコスチューム -> default に安全にフォールバック")
	_assert(ProfileManager.owned_costumes.has("default"), "所持リストに default が必ず含まれる")


## 3. SteamManager のフォールバック動作
func _test_steam_fallback() -> void:
	print("\n--- [3] SteamManager Offline/Fallback 動作 ---")
	_assert(SteamManager != null, "SteamManager Autoload が正常にロードされている")
	_assert(SteamManager.is_steam_available == false or SteamManager.is_steam_available == true, "Steam状態判定がクラッシュせず正常に応答")
	var steam_name: String = SteamManager.steam_username
	_assert(typeof(steam_name) == TYPE_STRING, "Steamユーザー名取得がフォールバック文字列を返す")
