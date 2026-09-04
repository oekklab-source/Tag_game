extends Node

## 鬼ごっこゲーム用 非対称 Elo レーティング計算およびランキング管理 Autoload。
## 1人 (Runner) vs 多人数 (Hunter) の非対称対戦に合わせたレート変動を算出する。

signal rating_changed(old_rating: int, new_rating: int, delta: int)

# --- 基本設定定数 ---
const K_BASE: float = 16.0
const MAX_TIME: float = 180.0
const BASE_HUNTER_COUNT: int = 4
const HUNTER_COUNT_WEIGHT: float = 50.0  # 鬼が1人増減するごとの仮想レート補正値
const TOUCH_TRANSFER_RATIO: float = 0.3 # 捕獲成功時に協力者からトドメ役に渡す獲得レート比率

# --- レート帯（ティア）定義 ---
# 境界値は下の BONUS_FULL_BELOW / BONUS_ZERO_AT と意図的に一致させている
# （「ゴールド以下は伸びやすい／ダイヤ以上は真剣勝負」と一言で説明できるように）。
const TIERS: Array[Dictionary] = [
	{"id": &"bronze",   "name": "ブロンズ",  "min": 0,    "color": Color(0.80, 0.50, 0.28)},
	{"id": &"silver",   "name": "シルバー",  "min": 1200, "color": Color(0.78, 0.80, 0.85)},
	{"id": &"gold",     "name": "ゴールド",  "min": 1400, "color": Color(1.00, 0.80, 0.25)},
	{"id": &"platinum", "name": "プラチナ",  "min": 1600, "color": Color(0.55, 0.90, 0.95)},
	{"id": &"diamond",  "name": "ダイヤ",    "min": 1800, "color": Color(0.55, 0.70, 1.00)},
	{"id": &"master",   "name": "マスター",  "min": 2000, "color": Color(0.85, 0.45, 1.00)},
]

# --- 低レート帯ボーナス定義 ---
# 序盤（シルバー以下）は純増寄りに、上位帯（ダイヤ以上）は完全ゼロサムに、
# 1400〜1800 の間を線形に減衰させる。挿入位置は calculate_all_rating_changes() の
# 「7. トドメの貢献度再分配」より後（= 6のゼロサム誤差補正で作った値を保ったまま、
# 参加報酬として純粋に上乗せする。トドメ役に持って行かれるべきものではないため）。
const BONUS_FULL_BELOW: float = 1400.0   # これ以下は満額（シルバー以下）
const BONUS_ZERO_AT: float = 1800.0      # これ以上は完全ゼロサム（ダイヤ以上）
const BONUS_MAX_POINTS: float = 6.0      # 満額時、Runner 1人が受け取る基準ボーナス
const BONUS_LOSS_TILT: float = 0.5       # 負けた側を厚くする係数（連敗で沈むのを防ぐ）


## レート帯（ティア）のインデックスを返す（0=ブロンズ, 5=マスター）
static func tier_index(rating: int) -> int:
	var idx := 0
	for i in range(TIERS.size()):
		if rating >= int(TIERS[i]["min"]):
			idx = i
	return idx


static func tier_id(rating: int) -> StringName:
	return TIERS[tier_index(rating)]["id"]


static func tier_name(rating: int) -> String:
	return TIERS[tier_index(rating)]["name"]


static func tier_color(rating: int) -> Color:
	return TIERS[tier_index(rating)]["color"]


## 指定ティアの表示用レート範囲。上限が無い最上位ティアは y = -1
static func tier_range(idx: int) -> Vector2i:
	var lo: int = TIERS[idx]["min"]
	var hi := -1
	if idx + 1 < TIERS.size():
		hi = int(TIERS[idx + 1]["min"]) - 1
	return Vector2i(lo, hi)


## 2人のレートが同じマッチに参加してよい実力差か（tolerance = 許容ティア差）
static func is_rating_compatible(host_rating: int, my_rating: int, tolerance: int = 0) -> bool:
	return absi(tier_index(host_rating) - tier_index(my_rating)) <= tolerance


## レートに応じたボーナス係数（1.0 = 満額, 0.0 = ゼロサム）。1400→1800 で線形減衰
static func bonus_weight(rating: float) -> float:
	if rating >= BONUS_ZERO_AT:
		return 0.0
	if rating <= BONUS_FULL_BELOW:
		return 1.0
	return (BONUS_ZERO_AT - rating) / (BONUS_ZERO_AT - BONUS_FULL_BELOW)


## 陣営内の1人あたりのボーナス量。side_score はその陣営のスコア(0..1)で、
## 負けた側（スコアが低い側）ほど厚く上乗せする
static func _bonus_for(rating: float, side_score: float, team_size: int) -> float:
	return BONUS_MAX_POINTS * bonus_weight(rating) * (1.0 + BONUS_LOSS_TILT * (1.0 - side_score)) / float(team_size)


## 全員のレートと試合結果を受け取り、全員分のレート変動値を一括計算する
## @param runner_rating: Runner のレート
## @param hunter_ratings: Hunter 全員のレート配列
## @param survival_time: 生存時間（秒、最大180.0）
## @param toucher_index: タッチした Hunter のインデックス（未捕獲または CPU の場合は -1）
## @param apply_bonus: false にすると低レート帯ボーナスを適用しない従来の厳密ゼロサム計算になる
## @return: {"runner_delta": float, "hunter_deltas": Array[float], "bonus_runner": float,
##           "bonus_hunters": Array[float], "bonus_total": float}
static func calculate_all_rating_changes(
	runner_rating: float,
	hunter_ratings: Array[float],
	survival_time: float,
	toucher_index: int = -1,
	apply_bonus: bool = true
) -> Dictionary:
	var n: int = hunter_ratings.size()
	if n == 0:
		return {"runner_delta": 0.0, "hunter_deltas": [], "bonus_runner": 0.0, "bonus_hunters": [], "bonus_total": 0.0}
	
	survival_time = clampf(survival_time, 0.0, MAX_TIME)
	
	# 1. 試合時間によるスコア算出 (0.0 〜 1.0)
	# 逃げ切り: 1.0 / 捕獲時: 生存時間に応じた部分点 (最大0.5)
	var sr: float = 1.0
	if survival_time < MAX_TIME:
		sr = 0.5 * (survival_time / MAX_TIME)
	var sh: float = 1.0 - sr
	
	# 2. 非対称Kファクターの設定（ゼロサムを担保: K_R = N * K_H）
	var k_runner: float = K_BASE * sqrt(float(n))
	var k_hunter: float = K_BASE / sqrt(float(n))
	
	# 3. 人数補正（N=4を基準とし、鬼が多いほど鬼の仮想レートが上がる）
	var sum_hunter_rating: float = 0.0
	for r in hunter_ratings:
		sum_hunter_rating += r
	var avg_hunter_rating: float = sum_hunter_rating / float(n)
	var n_offset: float = HUNTER_COUNT_WEIGHT * float(n - BASE_HUNTER_COUNT)
	var effective_hunter_team_rating: float = avg_hunter_rating + n_offset
	
	# 4. Runner の期待勝率とレート変動
	var er: float = 1.0 / (1.0 + pow(10.0, (effective_hunter_team_rating - runner_rating) / 400.0))
	var runner_delta: float = k_runner * (sr - er)
	
	# 5. 各 Hunter のベースレート変動計算
	var hunter_deltas: Array[float] = []
	var sum_hunter_deltas: float = 0.0
	for i in range(n):
		var effective_hi: float = hunter_ratings[i] + n_offset
		var e_hi: float = 1.0 / (1.0 + pow(10.0, (runner_rating - effective_hi) / 400.0))
		var d_hi: float = k_hunter * (sh - e_hi)
		hunter_deltas.append(d_hi)
		sum_hunter_deltas += d_hi
		
	# 6. 完全ゼロサム誤差補正（ロジスティック曲線の非線形性によるインフレ/デフレを完全防止）
	var error_pool: float = (-runner_delta) - sum_hunter_deltas
	var correction_per_hunter: float = error_pool / float(n)
	for i in range(n):
		hunter_deltas[i] += correction_per_hunter
		
	# 7. トドメの貢献度再分配（捕獲時 ＆ Hunter陣営がプラスの場合のみ）
	if survival_time < MAX_TIME and toucher_index >= 0 and toucher_index < n:
		var total_transfer: float = 0.0
		for i in range(n):
			if i != toucher_index and hunter_deltas[i] > 0.0:
				var transfer: float = hunter_deltas[i] * TOUCH_TRANSFER_RATIO
				hunter_deltas[i] -= transfer
				total_transfer += transfer
		hunter_deltas[toucher_index] += total_transfer

	# 8. 低レート帯ボーナス（序盤は純増、上位帯はゼロサムのまま）。
	# ここより前（6のゼロサム誤差補正・7のトドメ再分配）は一切変更しない。
	# ボーナスは「参加報酬」であり、error_pool の誤差補正に吸われても
	# トドメ役に持って行かれてもいけないため、必ず最後に加算する
	var bonus_runner := 0.0
	var bonus_hunters: Array[float] = []
	for i in range(n):
		bonus_hunters.append(0.0)
	if apply_bonus:
		bonus_runner = _bonus_for(runner_rating, sr, 1)
		runner_delta += bonus_runner
		for i in range(n):
			var b_h := _bonus_for(hunter_ratings[i], sh, n)
			bonus_hunters[i] = b_h
			hunter_deltas[i] += b_h
	var bonus_total := bonus_runner
	for b in bonus_hunters:
		bonus_total += b

	return {
		"runner_delta": runner_delta,
		"hunter_deltas": hunter_deltas,
		"bonus_runner": bonus_runner,
		"bonus_hunters": bonus_hunters,
		"bonus_total": bonus_total
	}


## 単一プレイヤー向けのレート変動量計算（HUD / クライアント用ラッパー）
## - is_runner: 自身が Runner だったか
## - is_winner: 自身が勝利したか
## - survival_time: 試合継続時間（秒、最大180.0）
## - hunter_count: 参加していた Hunter の人数
## - is_tagger: (Hunter の場合) 自身が実際に Runner をタッチしたか
## - my_rating: 自身の現在のレート
## - opponent_avg_rating: 相手陣営の平均レート
func calculate_rating_delta(
	is_runner: bool,
	is_winner: bool,
	survival_time: float,
	hunter_count: int,
	is_tagger: bool = false,
	my_rating: int = 1500,
	opponent_avg_rating: int = 1500
) -> int:
	hunter_count = maxi(1, hunter_count)
	survival_time = clampf(survival_time, 0.0, MAX_TIME)
	
	# 逃げ切り（Runnerが最後まで生き残った試合）は survival_time を必ず満額(MAX_TIME)に
	# 正規化する。is_runner == is_winner は「Runner勝利」または「Hunter敗北」の
	# 両方を一つの条件で拾う（Hunterが敗者になるのはRunnerの逃げ切り(TIME_UP)しか
	# あり得ない。Runner離脱(RUNNER_LEFT)はレート非対象として hud.gd 側でそもそも
	# ここに来ない）。Runner自身の端末とHunter自身の端末とで、同じ「逃げ切り」という
	# 結果に対し必ず同じ sr=1.0 / sh=0.0 が使われるようにするのが目的。かつては
	# Hunter側だけ `MAX_TIME - 0.1` にずらしていたため sh≈0.5（ほぼ引き分け扱い）になり、
	# Runnerが満額の勝利ボーナスを得る一方Hunterはほとんど減点されないという
	# 非対称が生じていた
	if is_runner == is_winner:
		survival_time = MAX_TIME

	# トドメ再分配（calculate_all_rating_changes 内の 7.）は「捕獲されたかどうか」で
	# 発生要否が決まる。ここを is_tagger で分岐すると、レートは各クライアントが
	# 自分の分だけ独立計算するため、トドメ役の端末では再分配後の値（ボーナス込み）を
	# 返す一方、協力者の端末では再分配自体が起きない未調整の満額を返してしまい、
	# 陣営合計が過大（ゼロサム崩れ）になる。捕獲があった試合では全員が同じ
	# toucher_idx=0 で計算し、target_idx の方でトドメ役か協力者かを読み分ける。
	#
	# 「捕獲されたか」は survival_time では判定しない（上の正規化で逃げ切り時は
	# 常に MAX_TIME になるため、`survival_time < MAX_TIME` では判定できない）。
	# is_runner と is_winner の食い違いは正規化の影響を受けない直接の捕獲判定
	var captured := is_runner != is_winner
	var toucher_idx := 0 if captured else -1

	if is_runner:
		var hunter_ratings: Array[float] = []
		for i in range(hunter_count):
			hunter_ratings.append(float(opponent_avg_rating))
		var res := calculate_all_rating_changes(float(my_rating), hunter_ratings, survival_time, toucher_idx)
		return int(round(res["runner_delta"]))
	else:
		var hunter_ratings: Array[float] = []
		for i in range(hunter_count):
			hunter_ratings.append(float(my_rating))
		var res := calculate_all_rating_changes(float(opponent_avg_rating), hunter_ratings, survival_time, toucher_idx)
		var h_deltas: Array = res["hunter_deltas"]
		var target_idx := 0 if is_tagger else mini(1, hunter_count - 1)
		if target_idx < h_deltas.size():
			return int(round(h_deltas[target_idx]))
		return int(round(h_deltas[0]))


## 試合終了時に呼び出し、ProfileManager および SteamManager に反映する
func apply_match_end(
	is_runner: bool,
	is_winner: bool,
	survival_time: float,
	hunter_count: int,
	is_tagger: bool = false
) -> int:
	# ①CPU戦（round_is_ranked==false）は呼び出し漏れがあってもここで二重に防ぐ
	if not GameManager.round_is_ranked:
		var r := ProfileManager.rating
		rating_changed.emit(r, r, 0)
		return 0
	var old_r := ProfileManager.rating
	var delta := calculate_rating_delta(
		is_runner,
		is_winner,
		survival_time,
		hunter_count,
		is_tagger,
		old_r,
		1500 # 簡易平均
	)
	
	ProfileManager.apply_match_result(delta, is_winner, is_runner)
	var new_r := ProfileManager.rating
	
	# EOS Leaderboard にも更新を送信
	EosManager.upload_rating(new_r)
	
	rating_changed.emit(old_r, new_r, delta)
	return delta
