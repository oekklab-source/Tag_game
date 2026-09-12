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
	await _test_cloud_merge_logic()
	await _test_purchase_provider_selection()

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


## 3. merge_server_inventory() のマージロジック検証。
## この関数は変更があると内部で save_profile() を呼ぶ(=ディスク書き込みを伴う)ため、
## costume_model.gd のような「ファイルI/Oなしの純粋テスト」には置けない。
## _test_profile_save_load() と同じく、実データを退避してから検証し、最後に復元する
func _test_cloud_merge_logic() -> void:
	print("\n--- [3] merge_server_inventory() マージロジック検証 ---")
	var orig := {
		"player_name": ProfileManager.player_name,
		"premium_currency": ProfileManager.premium_currency,
		"costume_id": ProfileManager.costume_id,
		"owned_costumes": ProfileManager.owned_costumes.duplicate(),
		"hat_id": ProfileManager.hat_id,
		"owned_hats": ProfileManager.owned_hats.duplicate(),
		"rating": ProfileManager.rating,
		"matches_played": ProfileManager.matches_played,
		"runner_wins": ProfileManager.runner_wins,
		"hunter_wins": ProfileManager.hunter_wins,
		"highest_rating": ProfileManager.highest_rating,
		"casual_matches_played": ProfileManager.casual_matches_played,
	}

	# 所持品は和集合(縮小しない)
	ProfileManager._apply_data({
		"schema_version": 5, "costume_id": "default", "owned_costumes": ["default", "candy"],
		"hat_id": "none", "owned_hats": ["none"], "last_modified_unix": 1000,
	})
	ProfileManager.merge_server_inventory({
		"schema_version": 5, "owned_costumes": ["default", "neon"],
		"owned_hats": ["none"], "last_modified_unix": 1, # ローカルより古い
	})
	_assert(ProfileManager.owned_costumes.has("candy") and ProfileManager.owned_costumes.has("neon"),
		"所持品は和集合になり、古いリモートとマージしても縮小しない")

	# 単純フィールドはタイムスタンプでLWW(新しい方採用)
	ProfileManager._apply_data({
		"schema_version": 5, "player_name": "MergeTestLocal", "premium_currency": 100,
		"costume_id": "default", "owned_costumes": ["default"],
		"hat_id": "none", "owned_hats": ["none"], "last_modified_unix": 100,
	})
	ProfileManager.merge_server_inventory({
		"schema_version": 5, "player_name": "MergeTestRemote", "premium_currency": 500,
		"owned_costumes": ["default"], "owned_hats": ["none"], "last_modified_unix": 200,
	})
	_assert(ProfileManager.player_name == "MergeTestRemote" and ProfileManager.premium_currency == 500,
		"新しいリモートの単純フィールド(ジェム/名前)が採用される")

	# リモートの方が古い場合、単純フィールドは変更されない
	ProfileManager._apply_data({
		"schema_version": 5, "player_name": "MergeTestLocal2", "premium_currency": 100,
		"costume_id": "default", "owned_costumes": ["default"],
		"hat_id": "none", "owned_hats": ["none"], "last_modified_unix": 200,
	})
	ProfileManager.merge_server_inventory({
		"schema_version": 5, "player_name": "MergeTestRemote2", "premium_currency": 999,
		"owned_costumes": ["default"], "owned_hats": ["none"], "last_modified_unix": 100,
	})
	_assert(ProfileManager.player_name == "MergeTestLocal2" and ProfileManager.premium_currency == 100,
		"古いリモートの単純フィールドは反映されない")

	# レート/戦績クラスタは matches_played が多い方をタイムスタンプに関わらず採用する
	ProfileManager._apply_data({
		"schema_version": 5, "costume_id": "default", "owned_costumes": ["default"],
		"hat_id": "none", "owned_hats": ["none"],
		"rating": 1600, "matches_played": 10, "highest_rating": 1600, "last_modified_unix": 100,
	})
	ProfileManager.merge_server_inventory({
		"schema_version": 5, "owned_costumes": ["default"], "owned_hats": ["none"],
		"rating": 1700, "matches_played": 20, "highest_rating": 1700, "last_modified_unix": 1,
	})
	_assert(ProfileManager.rating == 1700 and ProfileManager.matches_played == 20,
		"matches_played が多いクラスタがタイムスタンプに関わらず採用される")

	# highest_rating はクラスタの勝敗に関わらず常に退行しない(ratchet)
	ProfileManager._apply_data({
		"schema_version": 5, "costume_id": "default", "owned_costumes": ["default"],
		"hat_id": "none", "owned_hats": ["none"],
		"rating": 1600, "matches_played": 10, "highest_rating": 1800, "last_modified_unix": 100,
	})
	ProfileManager.merge_server_inventory({
		"schema_version": 5, "owned_costumes": ["default"], "owned_hats": ["none"],
		"rating": 1500, "matches_played": 5, "highest_rating": 1500, "last_modified_unix": 200,
	})
	_assert(ProfileManager.highest_rating == 1800, "highest_rating はクラスタが負けても退行しない")
	ProfileManager.merge_server_inventory({
		"schema_version": 5, "owned_costumes": ["default"], "owned_hats": ["none"],
		"rating": 1500, "matches_played": 3, "highest_rating": 2000, "last_modified_unix": 300,
	})
	_assert(ProfileManager.highest_rating == 2000, "リモートの highest_rating が大きければ採用される")

	# 実データを復元
	ProfileManager.player_name = orig.player_name
	ProfileManager.premium_currency = orig.premium_currency
	ProfileManager.costume_id = orig.costume_id
	ProfileManager.owned_costumes = orig.owned_costumes
	ProfileManager.hat_id = orig.hat_id
	ProfileManager.owned_hats = orig.owned_hats
	ProfileManager.rating = orig.rating
	ProfileManager.matches_played = orig.matches_played
	ProfileManager.runner_wins = orig.runner_wins
	ProfileManager.hunter_wins = orig.hunter_wins
	ProfileManager.highest_rating = orig.highest_rating
	ProfileManager.casual_matches_played = orig.casual_matches_played
	ProfileManager.save_profile()


## 4. PurchaseManagerのプロバイダ選択、およびMockPurchaseProviderの戻り値形状の検証。
## buy_pack()がbool単体からDictionary({"ok","granted_gems","reason"})に変わった
## 破壊的変更に対する回帰防止(全呼び出し元がこの形状の更新に追従できているか)
func _test_purchase_provider_selection() -> void:
	print("\n--- [4] PurchaseManager プロバイダ選択・戻り値形状 検証 ---")
	if PurchaseManager.USE_LIVE_PURCHASES:
		_assert(PurchaseManager._provider is StripePurchaseProvider, "USE_LIVE_PURCHASES=true時はStripePurchaseProviderが選択される")
	else:
		_assert(PurchaseManager._provider is MockPurchaseProvider, "USE_LIVE_PURCHASES=false時はMockPurchaseProviderが選択される")

	var mock := MockPurchaseProvider.new()
	var result: Dictionary = await mock.buy_pack(&"small")
	_assert(result.get("ok", false) == true, "MockPurchaseProviderは既知パックでok=trueを返す")
	_assert(int(result.get("granted_gems", 0)) == 300, "MockPurchaseProviderはカタログ通りのgranted_gemsを返す(small=300)")

	var unknown_result: Dictionary = await mock.buy_pack(&"no_such_pack")
	_assert(unknown_result.get("ok", true) == false, "MockPurchaseProviderは未知パックでok=falseを返す")
