extends Node

## ④コスチュームのデータモデル検証テスト。
## ProfileManager._apply_data() / CostumeCatalog の純粋なロジックのみを検証し、
## user://profile.json への読み書きは一切行わない（開発者の実データを壊さないため）。
##
## 実行方法:
##   godot --headless --path . res://tests/costume_model.tscn

func _ready() -> void:
	await get_tree().process_frame
	print("==================================================")
	print("【TEST】④コスチューム データモデル 検証")
	print("==================================================")

	test_legacy_schema_migration()
	test_current_schema_roundtrip()
	test_invalid_costume_id_fallback()
	test_unowned_costume_id_not_auto_granted()
	test_costume_catalog_integrity()

	print("\n==================================================")
	print("【TEST】⑤帽子 データモデル 検証")
	print("==================================================")
	test_hat_catalog_integrity()
	test_hat_schema_v3_migration()
	test_unowned_hat_not_auto_granted()
	test_humanoid_apply_hat_unowned_ok()

	print("\n==================================================")
	print("【TEST】②ジェム（課金モック通貨） データモデル 検証")
	print("==================================================")
	test_premium_currency_schema_v4_migration()
	test_premium_currency_roundtrip()

	print("==================================================")
	print("【TEST COMPLETED】全テストケースの検証完了")
	print("==================================================")
	get_tree().quit()


## 旧セーブ（schema_version が無く body_color しか持たない）を読ませたとき、
## 選んでいた色を無駄にせず costume_colors[0] へ引き継ぐことを確認する
func test_legacy_schema_migration() -> void:
	print("\n--- [1] 旧セーブ（schema_version無し）からの移行検証 ---")
	var legacy_color := Color(0.95, 0.35, 0.35) # コーラルレッド
	var legacy_data := {
		"player_name": "OldPlayer",
		"body_color": legacy_color.to_html(),
		"rating": 1620,
	}
	ProfileManager._apply_data(legacy_data)
	print("   costume_id: %s, costume_colors[0]: %s" % [ProfileManager.costume_id, ProfileManager.costume_colors[0]])
	assert(ProfileManager.costume_id == CostumeCatalog.DEFAULT_ID)
	assert(ProfileManager.costume_colors.size() == 1)
	# body_color は常に to_html()/Color.html() の8bit量子化を経由して保存・復元される
	# （production側でも body_color.to_html() 済みの文字列しか渡らない）ため、
	# 元の Color と厳密一致はしない。期待値も同じ量子化を経由させて比較する
	assert(ProfileManager.costume_colors[0].is_equal_approx(Color.html(legacy_color.to_html())))
	assert(ProfileManager.owned_costumes.has("default"))
	assert(ProfileManager.rating == 1620)
	print("   => 旧セーブの色が costume_colors[0] に引き継がれることを確認 [OK]")


## 現行スキーマ（schema_version=2）を読ませたとき、そのままの値が反映されることを確認する
func test_current_schema_roundtrip() -> void:
	print("\n--- [2] 現行スキーマ（schema_version=2）の読み込み検証 ---")
	var data := {
		"schema_version": 2,
		"player_name": "NewPlayer",
		"body_color": Color(0.05, 0.05, 0.08).to_html(),
		"costume_id": "neon",
		"costume_colors": [Color(0.05, 0.05, 0.08).to_html(), Color(1.0, 0.2, 0.9).to_html()],
		"owned_costumes": ["default", "neon"],
		"rating": 1750,
	}
	ProfileManager._apply_data(data)
	print("   costume_id: %s, colors: %d件" % [ProfileManager.costume_id, ProfileManager.costume_colors.size()])
	assert(ProfileManager.costume_id == &"neon")
	assert(ProfileManager.costume_colors.size() == 2)
	assert(ProfileManager.owns_costume(&"neon"))
	print("   => 現行スキーマの値がそのまま反映されることを確認 [OK]")


## 壊れた/未知の costume_id が入っていた場合、default にフォールバックすることを確認する
func test_invalid_costume_id_fallback() -> void:
	print("\n--- [3] 不正な costume_id のフォールバック検証 ---")
	var data := {
		"schema_version": 2,
		"costume_id": "no_such_costume",
		"costume_colors": [],
		"owned_costumes": ["default"],
	}
	ProfileManager._apply_data(data)
	print("   costume_id: %s" % ProfileManager.costume_id)
	assert(ProfileManager.costume_id == CostumeCatalog.DEFAULT_ID)
	assert(ProfileManager.owned_costumes.has(String(CostumeCatalog.DEFAULT_ID)))
	print("   => 未知の costume_id は default にフォールバックすることを確認 [OK]")


## 実在はするが所持していないコスチューム（改造されたセーブファイル等）が装備された
## 状態で読み込まれても、所持を自動付与せず default に戻すことを確認する。
## （所持していないコスチュームを黙って所持扱いにすると、有償コスチュームのロックが無意味になる）
func test_unowned_costume_id_not_auto_granted() -> void:
	print("\n--- [4] 未所持コスチュームが自動付与されないことの検証 ---")
	var data := {
		"schema_version": 2,
		"costume_id": "gold", # 実在するが owned_costumes には含まれていない
		"costume_colors": [],
		"owned_costumes": ["default"],
	}
	ProfileManager._apply_data(data)
	print("   costume_id: %s, owns(gold): %s" % [ProfileManager.costume_id, ProfileManager.owns_costume(&"gold")])
	assert(ProfileManager.costume_id == CostumeCatalog.DEFAULT_ID)
	assert(not ProfileManager.owns_costume(&"gold"))
	print("   => 未所持のコスチュームは自動付与されず default に戻ることを確認 [OK]")


## CostumeCatalog の全エントリが必須キーを持ち、surfaces がモデルの実構造
## （Body:1面 / Costume:5面 / Face:2面）の範囲内に収まっていることを確認する
func test_costume_catalog_integrity() -> void:
	print("\n--- [4] CostumeCatalog の整合性検証 ---")
	assert(CostumeCatalog.has(CostumeCatalog.DEFAULT_ID))
	for id in CostumeCatalog.COSTUMES:
		var def: Dictionary = CostumeCatalog.COSTUMES[id]
		print("   %s: %s" % [id, def.get("name", "?")])
		assert(def.has("name"))
		assert(def.has("rarity"))
		assert(def.has("unlock"))
		assert(def.has("color_slots"))
		assert(def.has("surfaces"))
		var slots: int = def["color_slots"]
		assert(slots >= 1)
		var has_role_tint := false
		for surf in def["surfaces"]:
			assert(CostumeCatalog.PART_SURFACES.has(surf["part"]))
			var max_index: int = CostumeCatalog.PART_SURFACES[surf["part"]]
			assert(surf["index"] >= 0 and surf["index"] < max_index)
			if surf.has("slot"):
				assert(surf["slot"] >= 0 and surf["slot"] < slots)
			if surf.get("role_tint", false):
				has_role_tint = true
		# 役割色（鬼/逃走者の識別）を持たないコスチュームは存在してはいけない
		assert(has_role_tint)
	print("   => 全コスチュームがモデル構造の範囲内に収まっていることを確認 [OK]")


## HatCatalog の全エントリが必須キーを持ち、none 以外は scene の preload に
## 成功していることを確認する
func test_hat_catalog_integrity() -> void:
	print("\n--- [5] HatCatalog の整合性検証 ---")
	assert(HatCatalog.has(HatCatalog.DEFAULT_ID))
	for id in HatCatalog.HATS:
		var def: Dictionary = HatCatalog.HATS[id]
		print("   %s: %s" % [id, def.get("name", "?")])
		assert(def.has("name"))
		assert(def.has("rarity"))
		assert(def.has("unlock"))
		if id != HatCatalog.DEFAULT_ID:
			assert(def.get("scene") != null)
	print("   => 全帽子定義が必須キーを持ち scene が読み込めていることを確認 [OK]")


## schema_version=2（帽子フィールドが存在しない既存セーブ）を読ませたとき、
## コスチュームはそのまま反映され、帽子だけ none に初期化されることを確認する
func test_hat_schema_v3_migration() -> void:
	print("\n--- [6] schema_version=2 からの帽子フィールド移行検証 ---")
	var data := {
		"schema_version": 2,
		"costume_id": "neon",
		"costume_colors": [],
		"owned_costumes": ["default", "neon"],
	}
	ProfileManager._apply_data(data)
	print("   costume_id: %s, hat_id: %s" % [ProfileManager.costume_id, ProfileManager.hat_id])
	assert(ProfileManager.costume_id == &"neon")  # コスチュームは schema<2 分岐と無関係にそのまま
	assert(ProfileManager.hat_id == HatCatalog.DEFAULT_ID)
	assert(ProfileManager.owned_hats.has("none"))
	print("   => schema=2 の既存セーブはコスチュームそのまま・帽子だけ初期化されることを確認 [OK]")


## 実在するが所持していない帽子（改造されたセーブファイル等）が装備された状態で
## 読み込まれても、所持を自動付与せず none に戻すことを確認する
func test_unowned_hat_not_auto_granted() -> void:
	print("\n--- [7] 未所持帽子が自動付与されないことの検証 ---")
	var data := {
		"schema_version": 3,
		"hat_id": "cap",
		"owned_hats": ["none"],
	}
	ProfileManager._apply_data(data)
	print("   hat_id: %s, owns(cap): %s" % [ProfileManager.hat_id, ProfileManager.owns_hat(&"cap")])
	assert(ProfileManager.hat_id == HatCatalog.DEFAULT_ID)
	assert(not ProfileManager.owns_hat(&"cap"))
	print("   => 未所持の帽子は自動付与されず none に戻ることを確認 [OK]")


## humanoid.apply_hat() が未所持IDでも描画上は成功する（所持判定は ProfileManager
## 層の責務で、humanoid/HatCatalog は純粋な見た目の適用のみを行う）ことを確認する
func test_humanoid_apply_hat_unowned_ok() -> void:
	print("\n--- [8] 未所持帽子でも humanoid.apply_hat() が成功することの検証 ---")
	var humanoid: Node3D = load("res://scenes/humanoid.tscn").instantiate()
	add_child(humanoid)
	var attachment: Node = humanoid.find_child("HatAttachment", true, false)
	humanoid.apply_hat(&"cap")  # 未所持でも描画は成功するはず（所持ガードはUI/ProfileManager側）
	assert(attachment.get_child_count() == 1)
	var cap_instance: Node = attachment.get_child(0)
	humanoid.apply_hat(&"none")
	# queue_free() は当フレーム末までノード削除を遅延するため、get_child_count() は
	# まだ更新されない。削除が「予約された」ことを直接確認する
	assert(cap_instance.is_queued_for_deletion())
	humanoid.queue_free()
	print("   => 未所持IDでも描画が成功し、none で装着解除できることを確認 [OK]")


## schema_version=3（premium_currencyフィールドが存在しない既存セーブ）を読ませたとき、
## クラッシュせずジェムが0で初期化されることを確認する
func test_premium_currency_schema_v4_migration() -> void:
	print("\n--- [9] schema_version=3 からのジェムフィールド移行検証 ---")
	var data := {
		"schema_version": 3,
		"costume_id": "default",
		"owned_costumes": ["default"],
		"hat_id": "none",
		"owned_hats": ["none"],
	}
	ProfileManager._apply_data(data)
	print("   premium_currency: %d" % ProfileManager.premium_currency)
	assert(ProfileManager.premium_currency == 0)
	print("   => schema=3 の既存セーブはジェム 0 で初期化されることを確認 [OK]")


## schema_version=4（現行）を読ませたとき、保存されていたジェム残高がそのまま反映されることを確認する
func test_premium_currency_roundtrip() -> void:
	print("\n--- [10] 現行スキーマ（schema_version=4）のジェム読み込み検証 ---")
	var data := {
		"schema_version": 4,
		"costume_id": "default",
		"owned_costumes": ["default"],
		"hat_id": "none",
		"owned_hats": ["none"],
		"premium_currency": 1234,
	}
	ProfileManager._apply_data(data)
	print("   premium_currency: %d" % ProfileManager.premium_currency)
	assert(ProfileManager.premium_currency == 1234)
	print("   => 現行スキーマのジェム残高がそのまま反映されることを確認 [OK]")
