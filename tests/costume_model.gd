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
