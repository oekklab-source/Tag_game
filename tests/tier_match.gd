extends Node

## ②レート帯（ティア）判定の検証テスト。
##
## 実行方法:
##   godot --headless --path . res://tests/tier_match.tscn

func _ready() -> void:
	await get_tree().process_frame
	print("==================================================")
	print("【TEST】レート帯（ティア）判定 検証")
	print("==================================================")

	test_tier_boundaries()
	test_tier_thresholds_match_bonus_thresholds()
	test_is_rating_compatible()

	print("==================================================")
	print("【TEST COMPLETED】全テストケースの検証完了")
	print("==================================================")
	get_tree().quit()


func test_tier_boundaries() -> void:
	print("\n--- [1] ティア境界値の検証 ---")
	var cases := [
		[0, &"bronze"], [1199, &"bronze"],
		[1200, &"silver"], [1399, &"silver"],
		[1400, &"gold"], [1599, &"gold"],
		[1600, &"platinum"], [1799, &"platinum"],
		[1800, &"diamond"], [1999, &"diamond"],
		[2000, &"master"], [3000, &"master"],
	]
	for c in cases:
		var rating: int = c[0]
		var expected: StringName = c[1]
		var got := RankingManager.tier_id(rating)
		print("   rating %d -> %s (expected %s)" % [rating, got, expected])
		assert(got == expected)
	print("   => 境界値ですべて期待通りのティアになることを確認 [OK]")


func test_tier_thresholds_match_bonus_thresholds() -> void:
	print("\n--- [2] ティア境界と③ボーナスしきい値の整合性検証 ---")
	# ②のティア境界と③のしきい値がずれると「ゴールド以下は伸びやすい／
	# ダイヤ以上は真剣勝負」の説明が破綻するため、ここで直接検証する
	assert(int(RankingManager.BONUS_FULL_BELOW) == 1400)
	assert(int(RankingManager.BONUS_ZERO_AT) == 1800)
	assert(RankingManager.tier_id(int(RankingManager.BONUS_FULL_BELOW)) == &"gold")
	assert(RankingManager.tier_id(int(RankingManager.BONUS_FULL_BELOW) - 1) == &"silver")
	assert(RankingManager.tier_id(int(RankingManager.BONUS_ZERO_AT)) == &"diamond")
	assert(RankingManager.tier_id(int(RankingManager.BONUS_ZERO_AT) - 1) == &"platinum")
	print("   => 1400/1800 の境界がティアとボーナスしきい値で一致していることを確認 [OK]")


func test_is_rating_compatible() -> void:
	print("\n--- [3] マッチング可否判定（is_rating_compatible）の検証 ---")
	# 同ティア同士は tolerance=0 でも許容
	assert(RankingManager.is_rating_compatible(1450, 1550, 0))
	# ゴールドとプラチナ（隣接ティア）は tolerance=0 で不許可、tolerance=1 で許容
	assert(not RankingManager.is_rating_compatible(1450, 1650, 0))
	assert(RankingManager.is_rating_compatible(1450, 1650, 1))
	# ブロンズとマスターのように大きく離れていれば tolerance=1 でも不許可
	assert(not RankingManager.is_rating_compatible(500, 2500, 1))
	print("   => tolerance の指定通りにマッチング可否が判定されることを確認 [OK]")
