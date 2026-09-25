extends Node

## C-03 R-3 / R-11 / R-12: rating_report.gd の純粋関数
## (should_report / build_hunter_puids / cpu_hunter_count / is_plausible_correction)を
## ネットワーク無しで直接検証するスクリプト

const RatingReportScript := preload("res://autoload/game/rating_report.gd")

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
	print("【TEST】C-03 R-3: rating_report.gd 純粋関数検証")
	print("==================================================")

	_test_should_report()
	_test_build_hunter_puids()
	_test_cpu_hunter_count()
	_test_is_plausible_correction()

	print("==================================================")
	print("test_rating_report 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> test_rating_report: ALL PASSED")
	else:
		printerr("=> test_rating_report: SOME TESTS FAILED")
	get_tree().quit()


func _test_should_report() -> void:
	print("\n--- should_report() ---")
	var TIME_UP := GameManager.EndReason.TIME_UP
	var TAGGED := GameManager.EndReason.TAGGED
	var RUNNER_LEFT := GameManager.EndReason.RUNNER_LEFT

	_assert(RatingReportScript.should_report(false, TAGGED, 5) == false,
		"非ランク(round_is_ranked=false) -> false")
	_assert(RatingReportScript.should_report(true, RUNNER_LEFT, 5) == false,
		"RUNNER_LEFT -> false(切断ペナルティ経路と二重処理を避ける)")
	# C-03 R-11: R-3では「有効なtoucher_puidが作れない」という理由で報告自体を
	# スキップしていた(小規模ランクマッチでは普通に起こるため、負けてもレートが
	# 動かない試合が発生していた)。R-11からは toucher_puid=null で報告する
	_assert(RatingReportScript.should_report(true, TAGGED, -1) == true,
		"TAGGED + tagger_id=-1(CPU鬼タッチ) -> true(R-11でトドメ無しとして報告)")
	_assert(RatingReportScript.should_report(true, TAGGED, 5) == true,
		"TAGGED + 有効なtagger_id -> true")
	_assert(RatingReportScript.should_report(true, TIME_UP, -1) == true,
		"TIME_UP(タッチ判定不要) -> true")


func _test_build_hunter_puids() -> void:
	print("\n--- build_hunter_puids() ---")
	var profiles_missing_puid := {2: {"puid": "p2"}, 3: {}}
	_assert(RatingReportScript.build_hunter_puids(profiles_missing_puid, [2, 3]) == null,
		"参加者にpuid空(EOS未接続)がいる -> null")

	var profiles_ok := {2: {"puid": "p2"}, 3: {"puid": "p3"}}
	var result: Array = RatingReportScript.build_hunter_puids(profiles_ok, [3, 2])
	_assert(result == ["p2", "p3"], "peer_id昇順で整列される([3,2]入力 -> [p2,p3])")

	var empty_result: Array = RatingReportScript.build_hunter_puids({}, [])
	_assert(empty_result == [], "鬼が0人でも空配列を返す(nullにしない)")


## C-03 R-11(RV-04): CPUが埋めた鬼の人数。これを送らないとサーバーの N が
## 人間数になり、クライアントの楽観計算(CPU込みのround_hunter_count)と食い違う
func _test_cpu_hunter_count() -> void:
	print("\n--- cpu_hunter_count() ---")
	_assert(RatingReportScript.cpu_hunter_count(3, 1) == 2,
		"1v1ランクマッチ(鬼枠3・人間1) -> CPU2体")
	_assert(RatingReportScript.cpu_hunter_count(3, 3) == 0,
		"人間だけで鬼枠が埋まっている -> 0")
	_assert(RatingReportScript.cpu_hunter_count(0, 0) == 0,
		"ラウンド外(round_hunter_count=0) -> 0")
	_assert(RatingReportScript.cpu_hunter_count(1, 3) == 0,
		"人間の方が多い異常値でも負数を返さない(0にクランプ)")


## C-03 R-12(RV-08): 補正RPCの受信側検証。改造ホストが同席者の表示レートを
## 任意に書き換えられる経路を塞ぐ。rating は tier_lock のマッチング判定と
## ランキング表示に効くため、一時的な書き換えでも実害がある
func _test_is_plausible_correction() -> void:
	print("\n--- is_plausible_correction() ---")
	var f := RatingReportScript.is_plausible_correction

	_assert(f.call(1512, 1500) == true, "通常の1試合ぶんの補正(+12) -> 採用")
	_assert(f.call(1436, 1500) == true, "切断ペナルティ相当(-64) -> 採用")
	_assert(f.call(1500, 1500) == true, "変化なし(delta=0) -> 採用")

	_assert(f.call(2600, 1500) == false, "絶対値域の上限(2500)超え -> 破棄")
	_assert(f.call(99, 150) == false, "絶対値域の下限(100)未満 -> 破棄")
	_assert(f.call(2500, 1500) == false,
		"値域内でも1試合の変化幅(100)を超えていれば破棄")
	_assert(f.call(100, 1500) == false, "極端に下げる改ざんも破棄")

	# 境界(ちょうど100の変化は許す / 101は許さない)
	_assert(f.call(1600, 1500) == true, "変化幅ちょうど100 -> 採用")
	_assert(f.call(1601, 1500) == false, "変化幅101 -> 破棄")

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
