extends Node

## 非対称 Elo レーティング計算モデルの検証テスト。
##
## 実行方法:
##   godot --headless --path . res://tests/rating_model.tscn

func _ready() -> void:
	await get_tree().process_frame
	print("==================================================")
	print("【TEST】非対称 Elo レーティングモデル検証")
	print("==================================================")
	
	test_standard_cases()
	test_zero_sum_property()
	test_time_monotonicity()
	test_bonus_weight_curve()
	test_low_rating_bonus()
	test_high_rating_zero_sum()
	test_tier_boundaries_match_bonus_thresholds()
	test_per_client_touch_transfer_stays_zero_sum()
	test_clean_escape_symmetric_across_clients()

	print("==================================================")
	print("【TEST COMPLETED】全テストケースの検証完了")
	print("==================================================")
	get_tree().quit()


func test_standard_cases() -> void:
	print("\n--- [1] 要件シミュレーション例の検証 (1500 vs 1500 x 4) ---")
	
	# apply_bonus=false: このテストは従来の厳密ゼロサム計算のリグレッション確認が目的なので、
	# 低レート帯ボーナス（③）は無効化しておく
	# ケース①: 2分 (120秒) で捕まった場合
	var r_ratings: Array[float] = [1500.0, 1500.0, 1500.0, 1500.0]
	var res1: Dictionary = RankingManager.calculate_all_rating_changes(1500.0, r_ratings, 120.0, 0, false)
	print("① 2分(120秒)で捕獲:")
	print("   Runner Delta: %+.2f" % res1["runner_delta"])
	print("   Toucher (Hunter 0) Delta: %+.2f" % res1["hunter_deltas"][0])
	print("   Assist (Hunter 1..3) Delta: %+.2f" % res1["hunter_deltas"][1])
	var sum_h1 := 0.0
	for d in res1["hunter_deltas"]:
		sum_h1 += d
	print("   Hunter合計: %+.2f, 陣営合計(Zero-Sum): %+.4f" % [sum_h1, res1["runner_delta"] + sum_h1])
	
	# 検証: Runnerはマイナス、Toucherはプラス、Assistもプラス、Zero-sum
	assert(res1["runner_delta"] < 0.0)
	assert(res1["hunter_deltas"][0] > res1["hunter_deltas"][1])
	assert(abs(res1["runner_delta"] + sum_h1) < 0.001)

	# ケース②: 3分 (180秒) 逃げ切った場合
	var res2: Dictionary = RankingManager.calculate_all_rating_changes(1500.0, r_ratings, 180.0, -1, false)
	print("② 3分(180秒)逃げ切り:")
	print("   Runner Delta: %+.2f" % res2["runner_delta"])
	print("   Hunter 0..3 Delta: %+.2f" % res2["hunter_deltas"][0])
	var sum_h2 := 0.0
	for d in res2["hunter_deltas"]:
		sum_h2 += d
	print("   Hunter合計: %+.2f, 陣営合計(Zero-Sum): %+.4f" % [sum_h2, res2["runner_delta"] + sum_h2])
	
	assert(res2["runner_delta"] > 0.0)
	assert(res2["hunter_deltas"][0] < 0.0)
	assert(abs(res2["runner_delta"] + sum_h2) < 0.001)


func test_zero_sum_property() -> void:
	print("\n--- [2] 多様な人数・レート格差での Zero-Sum 特性検証 ---")
	var counts := [1, 3, 5, 7] # Hunter人数
	for n in counts:
		var h_ratings: Array[float] = []
		for i in range(n):
			h_ratings.append(1200.0 + i * 150.0) # レートばらつき
		var runner_r := 1600.0
		
		for t in [30.0, 90.0, 150.0, 180.0]:
			var toucher := 0 if t < 180.0 else -1
			var res: Dictionary = RankingManager.calculate_all_rating_changes(runner_r, h_ratings, t, toucher, false)
			var sum_h := 0.0
			for d in res["hunter_deltas"]:
				sum_h += d
			var net: float = res["runner_delta"] + sum_h
			if abs(net) >= 0.001:
				print("   [FAIL] N=%d, T=%.0f: Net = %f" % [n, t, net])
			assert(abs(net) < 0.001)
	print("   => 全パターンで Zero-Sum (レート保存則) が成立していることを確認 [OK]")


func test_time_monotonicity() -> void:
	print("\n--- [3] 生存時間に対する単調性 (Runnerは長く生きるほど得をする) ---")
	print("   （apply_bonus=true のまま実行し、③のボーナスが単調性を壊さないことも確認する）")
	var prev_runner_delta := -999.0
	var h_ratings: Array[float] = [1500.0, 1500.0, 1500.0]
	for sec in [0.0, 30.0, 60.0, 90.0, 120.0, 150.0, 179.9, 180.0]:
		var res: Dictionary = RankingManager.calculate_all_rating_changes(1500.0, h_ratings, sec, 0)
		var delta: float = res["runner_delta"]
		print("   生存 %5.1f 秒 -> Runner Delta: %+6.2f" % [sec, delta])
		assert(delta >= prev_runner_delta)
		prev_runner_delta = delta
	print("   => 生存時間が長いほど Runner の評価が単調増加することを確認 [OK]")


func test_bonus_weight_curve() -> void:
	print("\n--- [4] 低レート帯ボーナス係数のカーブ検証 ---")
	var samples := [1000.0, 1200.0, 1400.0, 1600.0, 1800.0, 2000.0]
	var prev_w := 2.0 # weight は 1.0 を超えないので、初期値はそれより大きくしておく
	for r in samples:
		var w := RankingManager.bonus_weight(r)
		print("   rating %.0f -> weight %.3f" % [r, w])
		assert(w <= prev_w) # 単調非増加
		prev_w = w
	assert(is_equal_approx(RankingManager.bonus_weight(1200.0), 1.0))
	assert(is_equal_approx(RankingManager.bonus_weight(1400.0), 1.0))
	assert(is_equal_approx(RankingManager.bonus_weight(1600.0), 0.5))
	assert(is_equal_approx(RankingManager.bonus_weight(1800.0), 0.0))
	assert(is_equal_approx(RankingManager.bonus_weight(2000.0), 0.0))
	print("   => bonus_weight が 1400 以下=1.0 / 1800 以上=0.0 / 間は線形減衰であることを確認 [OK]")


func test_low_rating_bonus() -> void:
	print("\n--- [5] 序盤レート帯 (全員1300) は純増になることの検証 ---")
	var h_ratings: Array[float] = [1300.0, 1300.0, 1300.0, 1300.0]
	# Runner が負けた（120秒で捕獲された）ケースでも純増になることを確認
	var res: Dictionary = RankingManager.calculate_all_rating_changes(1300.0, h_ratings, 120.0, 0, true)
	var sum_h := 0.0
	for d in res["hunter_deltas"]:
		sum_h += d
	var net: float = res["runner_delta"] + sum_h
	print("   Runner Delta: %+.2f, Hunter合計: %+.2f, 陣営合計(Net): %+.4f" % [res["runner_delta"], sum_h, net])
	assert(net > 0.0)
	print("   => 序盤レート帯では陣営合計がプラス（純増）になることを確認 [OK]")


func test_high_rating_zero_sum() -> void:
	print("\n--- [6] 上位レート帯 (全員2000) は従来通り完全ゼロサムのままであることの検証 ---")
	var h_ratings: Array[float] = [2000.0, 2000.0, 2000.0, 2000.0]
	var res: Dictionary = RankingManager.calculate_all_rating_changes(2000.0, h_ratings, 120.0, 0, true)
	var sum_h := 0.0
	for d in res["hunter_deltas"]:
		sum_h += d
	var net: float = res["runner_delta"] + sum_h
	print("   Runner Delta: %+.2f, Hunter合計: %+.2f, 陣営合計(Net): %+.4f" % [res["runner_delta"], sum_h, net])
	assert(abs(net) < 0.001)
	assert(is_equal_approx(res["bonus_total"], 0.0))
	print("   => 上位レート帯（ダイヤ以上）ではボーナスが乗らず完全ゼロサムのままであることを確認 [OK]")


## 本番同様、Runner・トドメ役・協力者がそれぞれ「自分の分だけ」を別クライアントとして
## 独立計算しても、トドメ再分配の後に陣営合計がゼロサムのまま保たれることを検証する。
## （calculate_rating_delta の toucher_idx を is_tagger で分岐すると、トドメ役の端末だけ
## 再分配後の値を返し、協力者の端末は未調整の満額を返してしまい陣営合計が過大になる回帰を防ぐ）
func test_per_client_touch_transfer_stays_zero_sum() -> void:
	print("\n--- [8] トドメ再分配が全クライアント独立計算でもゼロサムを保つことの検証 ---")
	# ③のボーナスの影響を排除するため、bonus_weight=0 になる高レート(>=1800)で検証する
	var my_rating := 2000
	var hunter_count := 4
	var survival := 90.0  # 途中で捕獲された想定（逃げ切りではない）

	var runner_delta := RankingManager.calculate_rating_delta(
		true, false, survival, hunter_count, false, my_rating, my_rating)

	var tagger_delta := RankingManager.calculate_rating_delta(
		false, true, survival, hunter_count, true, my_rating, my_rating)
	var cooperators_delta := 0
	for i in range(hunter_count - 1):
		cooperators_delta += RankingManager.calculate_rating_delta(
			false, true, survival, hunter_count, false, my_rating, my_rating)

	var net := runner_delta + tagger_delta + cooperators_delta
	print("   Runner: %+d, トドメ役: %+d, 協力者合計: %+d, 陣営合計(Net): %+d"
		% [runner_delta, tagger_delta, cooperators_delta, net])
	assert(absi(net) <= 3) # 各クライアントで int(round(...)) するため、丸め誤差ぶんのみ許容
	print("   => トドメ役/協力者を別クライアントとして独立計算しても陣営合計がゼロサムに保たれることを確認 [OK]")


## Runner自身の端末とHunter自身の端末とで、同じ「逃げ切り」という結果に対する評価が
## 食い違わないことを検証する（かつては Hunter 側だけ survival_time を MAX_TIME-0.1 に
## ずらしていたため sh≈0.5 となり、Hunter がほとんど減点されない非対称バグがあった）
func test_clean_escape_symmetric_across_clients() -> void:
	print("\n--- [9] 完全な逃げ切りでRunner視点とHunter視点のスコアが食い違わないことの検証 ---")
	# ③のボーナスの影響を排除するため、bonus_weight=0 になる高レート(>=1800)で検証する
	var runner_rating := 2000
	var hunter_rating := 2000
	var hunter_count := 3

	# Runner自身の端末での計算（is_winner=true, is_runner=true）
	var runner_delta := RankingManager.calculate_rating_delta(
		true, true, RankingManager.MAX_TIME, hunter_count, false, runner_rating, hunter_rating)
	# Hunter自身の端末での計算（is_winner=false, is_runner=false）。誰も捕まえていない
	# （完全な逃げ切り）ので is_tagger=false
	var hunter_delta := RankingManager.calculate_rating_delta(
		false, false, RankingManager.MAX_TIME, hunter_count, false, hunter_rating, runner_rating)

	# 単一の calculate_all_rating_changes 呼び出し（calculate_rating_delta 内部と同じ条件）
	# で得られる「正解」の Hunter 変動値と一致するはず
	var hunter_ratings: Array[float] = []
	for i in range(hunter_count):
		hunter_ratings.append(float(hunter_rating))
	var res: Dictionary = RankingManager.calculate_all_rating_changes(
		float(runner_rating), hunter_ratings, RankingManager.MAX_TIME, -1)
	var expected_hunter_delta := int(round(res["hunter_deltas"][0]))

	print("   Runner視点Delta: %+d, Hunter視点Delta: %+d (正解値: %+d)"
		% [runner_delta, hunter_delta, expected_hunter_delta])
	assert(hunter_delta == expected_hunter_delta)
	# 完敗なので、Hunter側は「ほぼ引き分け」に近い小さな値ではなく明確なマイナスになるはず
	# （旧バグでは sh≈0.5003 となり、ここが 0 近辺の小さな値になっていた）
	assert(hunter_delta < -3)
	print("   => Runner/Hunterどちらの端末で計算しても sr=1.0 / sh=0.0 の同じ評価になることを確認 [OK]")


func test_tier_boundaries_match_bonus_thresholds() -> void:
	print("\n--- [7] レート帯（ティア）境界とボーナスしきい値の整合性検証 ---")
	# ②のティア境界と③のしきい値がずれると「ゴールド以下は伸びやすい」の説明が破綻するため、
	# ここが崩れた瞬間にテストが落ちるようにしておく
	assert(RankingManager.tier_id(1399) == &"silver")
	assert(RankingManager.tier_id(1400) == &"gold")
	assert(int(RankingManager.BONUS_FULL_BELOW) == 1400)
	assert(RankingManager.tier_id(1799) == &"platinum")
	assert(RankingManager.tier_id(1800) == &"diamond")
	assert(int(RankingManager.BONUS_ZERO_AT) == 1800)
	print("   => ティア境界(1400/1800)とボーナスしきい値が一致していることを確認 [OK]")
