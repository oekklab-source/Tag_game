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
	test_skin_catalog_compatibility()
	test_fixed_skin_designs()

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

	print("\n==================================================")
	print("【TEST】⑥CurrencyPackCatalog（実課金SKU定義） データモデル 検証")
	print("==================================================")
	test_currency_pack_catalog_integrity()

	print("\n==================================================")
	print("【TEST】M-11 名前バリデーション（sanitize_name/name_error） 検証")
	print("==================================================")
	test_sanitize_name_normalizes_whitespace_and_length()
	test_sanitize_name_empty_fallback()
	test_name_error_detects_ng_words_and_allows_clean_name()

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


## 既存セーブのskin番号を変えず、バスケ08が3番目に追加されていることを確認する。
func test_skin_catalog_compatibility() -> void:
	assert(Humanoid.SKINS.size() >= 3)
	assert(Humanoid.SKINS[0]["path"] == "res://assets/character/fallguy.glb")
	assert(Humanoid.SKINS[1]["path"] == "res://assets/character/ninja.glb")
	assert(Humanoid.SKINS[2]["path"] == "res://assets/character/outfits/basketball_prototype.glb")
	var required_anims := ["Idle", "Run", "Jump", "Dive", "Slip", "Nice", "Come",
		"ComeHip", "ComeCool", "SlideEnter", "SlideSit", "SlideReverseFall",
		"SlideProne", "SlideRecover", "RespawnDizzy"]
	var humanoid: Node3D = load("res://scenes/humanoid.tscn").instantiate()
	add_child(humanoid)
	for skin_id in range(3):
		humanoid.set_skin(skin_id)
		var player: AnimationPlayer = humanoid._anim
		for anim_name in required_anims:
			assert(player.has_animation(anim_name), "%s に %s がありません" % [Humanoid.SKINS[skin_id]["name"], anim_name])
	humanoid.queue_free()
	print("   => 既存skin番号を維持し、バスケ08が3番目にあることを確認 [OK]")
	print("   => 3キャラクターに共通の15アニメが揃っていることを確認 [OK]")


## しのびとバスケ08は固定デザインで、面構成が一致しても柄・カラーの
## マテリアル上書きを受けないことを確認する。帽子は別処理なので影響しない。
func test_fixed_skin_designs() -> void:
	var humanoid: Node3D = load("res://scenes/humanoid.tscn").instantiate()
	add_child(humanoid)
	var colors := PackedColorArray([Color.RED, Color.BLUE])
	for skin_id in [1, 2]:
		humanoid.set_skin(skin_id)
		humanoid.apply_costume(&"neon", colors)
		assert(humanoid._override_keys.is_empty())
	humanoid.set_skin(0)
	humanoid.apply_costume(&"neon", colors)
	assert(not humanoid._override_keys.is_empty())
	humanoid.queue_free()
	print("   => しのび・バスケ08の固定デザインが柄で上書きされないことを確認 [OK]")


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


## CurrencyPackCatalogの全SKUがstripe_price_id(Stripe連携用)を持ち、
## ジェム数が正の値であることを確認する
func test_currency_pack_catalog_integrity() -> void:
	print("\n--- [11] CurrencyPackCatalog の整合性検証 ---")
	for id in CurrencyPackCatalog.PACKS:
		var def: Dictionary = CurrencyPackCatalog.PACKS[id]
		print("   %s: %s" % [id, def.get("name", "?")])
		assert(def.has("stripe_price_id"))
		assert(not String(def["stripe_price_id"]).is_empty())
		assert(int(def.get("gems", 0)) > 0)
		assert(not String(def.get("display_price", "")).is_empty())
	print("   => 全パックがstripe_price_id/正のジェム数を持つことを確認 [OK]")


## 全角/半角混在の連続空白が1個に圧縮され、16文字を超える名前が切り詰められることを確認する
func test_sanitize_name_normalizes_whitespace_and_length() -> void:
	print("\n--- [12] sanitize_name() の空白圧縮・文字数制限検証 ---")
	var collapsed := ProfileManager.sanitize_name("  A　  B\tC  ")
	print("   collapsed: '%s'" % collapsed)
	assert(collapsed == "A B C")
	var truncated := ProfileManager.sanitize_name("12345678901234567890")
	print("   truncated: '%s' (len=%d)" % [truncated, truncated.length()])
	assert(truncated.length() == ProfileManager.MAX_NAME_LENGTH)
	assert(truncated == "1234567890123456")
	print("   => 連続空白の圧縮・16文字切り詰めを確認 [OK]")


## 空文字・空白のみの名前が "Player" にフォールバックすることを確認する
func test_sanitize_name_empty_fallback() -> void:
	print("\n--- [13] sanitize_name() の空文字フォールバック検証 ---")
	assert(ProfileManager.sanitize_name("") == "Player")
	assert(ProfileManager.sanitize_name("   　  ") == "Player")
	print("   => 空文字・空白のみの名前が Player になることを確認 [OK]")


## NGワードを含む名前はエラー文言を返し、含まない名前は空文字を返すことを確認する
func test_name_error_detects_ng_words_and_allows_clean_name() -> void:
	print("\n--- [14] name_error() のNGワード検出検証 ---")
	assert(not ProfileManager.name_error("admin").is_empty())
	assert(not ProfileManager.name_error("Administrator99").is_empty())
	assert(not ProfileManager.name_error("運営です").is_empty())
	assert(ProfileManager.name_error("TestHero99").is_empty())
	print("   => NGワードを含む名前のみエラーになることを確認 [OK]")

# --- 実セーブ(user://profile.json / settings.json)とクラウドセーブの保護 ---
# ラウンドを回さないテストでも、EOS にログインできる環境では起動時のクラウドセーブ同期が
# 実セーブを書き換える(2026-09-25 に boost_panel の実行中に実測)。どのテストが
# 踏むかを個別に見極めるより、全テストで一律に挟む。詳細は tests/save_guard.gd のヘッダ。
const _SaveGuard := preload("res://tests/save_guard.gd")
var _save_backup := {}


func _enter_tree() -> void:
	_save_backup = _SaveGuard.backup()


func _exit_tree() -> void:
	_SaveGuard.restore(_save_backup)
