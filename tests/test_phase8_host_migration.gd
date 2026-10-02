extends Node

## Phase 8: ホストマイグレーション + 切断側ペナルティ拡張の検証スクリプト
##
## 実ネットワーク・実EOSロビーは張らず、GameManager/EosManagerのAPIを直接叩いて
## 検証する(tests/test_phase6_network_edge.gdと同じ流儀)。
## RatingBackendClient.report_disconnect_penalty()(C-03 R-5)はUSE_LIVE_RATING_BACKEND
## 有効時に実バックエンドへ通信してしまうため、このテストではpuidを空文字にして早期
## returnさせ、実際にその関数を呼ばせない構成に統一する
## (tests/test_eos_lobby_mock.gdが実EOSバックエンドへの副作用を避ける方針と同じ)。

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
	print("【TEST】Phase 8: ホストマイグレーション + 切断側ペナルティ拡張")
	print("==================================================")
	await get_tree().process_frame

	_test_hunter_disconnect_no_longer_free()
	_test_hunter_disconnect_does_not_end_round()
	_test_disconnect_penalty_gated_by_live_backend_flag()
	_test_snapshot_for_host_disconnect_penalty()
	_test_handoff_candidate_selection()

	print("==================================================")
	print("Phase 8 結果: PASS=%d, FAIL=%d" % [passed_count, failed_count])
	print("==================================================")
	if failed_count == 0:
		print("=> Phase 8: ALL PASSED")
	else:
		printerr("=> Phase 8: SOME TESTS FAILED")
	get_tree().quit()


## 1. 鬼役がランク戦PLAYING中に切断した場合、on_player_leftのcpu_took_over=false分岐で
## _report_participant_disconnect_penalty()に到達すること(puidが空なのでRatingBackendClientへの
## 実通信は起きない。到達したかどうかは「例外なく完走する」ことと2で見る副作用で確認する)
func _test_hunter_disconnect_no_longer_free() -> void:
	print("\n--- [1] 鬼役がランク戦中に切断してもクラッシュせず処理が完走する ---")
	var spawns: Dictionary = {99: Vector3.ZERO}
	GameManager._start_round(99, 1.0, 1, spawns, true)
	GameManager.round_is_ranked = true
	# puidを設定しない(空文字) -> _report_participant_disconnect_penaltyが早期returnし、
	# RatingBackendClient.report_disconnect_penalty()(実バックエンド通信)を呼ばせない
	GameManager.peer_profiles[7] = {"name": "Hunter7", "rating": 1500}

	GameManager.on_player_left(7, false)

	_assert(not GameManager.peer_profiles.has(7), "切断した鬼のprofileが削除される")


## 2. 鬼役の切断は逃走者の切断と違い、ラウンドを強制終了させない(試合は続行できる)
func _test_hunter_disconnect_does_not_end_round() -> void:
	print("\n--- [2] 鬼役の切断はRUNNER_LEFT等でラウンドを終了させない ---")
	var spawns: Dictionary = {99: Vector3.ZERO}
	GameManager._start_round(99, 1.0, 1, spawns, true)
	GameManager.round_is_ranked = true
	GameManager.peer_profiles[7] = {"name": "Hunter7", "rating": 1500}

	GameManager.on_player_left(7, false)

	_assert(GameManager.state == GameManager.State.PLAYING, "鬼切断後も試合は継続してPLAYINGのまま")


## C-03 R-5: puidが非空でも、USE_LIVE_RATING_BACKENDがfalseの間はRatingBackendClientへの
## 実通信に到達する前にゲートで止まり、例外なく完走すること(#1がpuid空文字での早期returnを
## 検証しているのに対し、こちらは「puidがあってもフラグで止まる」経路を検証する)
func _test_disconnect_penalty_gated_by_live_backend_flag() -> void:
	print("\n--- [2.5] 切断ペナルティ報告はUSE_LIVE_RATING_BACKENDがfalseの間は実通信に到達しない ---")
	_assert(not BackendConfig.USE_LIVE_RATING_BACKEND,
		"前提: このテストはUSE_LIVE_RATING_BACKEND=falseを前提にしている")

	var spawns: Dictionary = {99: Vector3.ZERO}
	GameManager._start_round(99, 1.0, 1, spawns, true)
	GameManager.round_is_ranked = true
	GameManager.peer_profiles[7] = {"name": "Hunter7", "rating": 1500, "puid": "hunter7-puid"}

	GameManager.on_player_left(7, false)

	_assert(not GameManager.peer_profiles.has(7),
		"puidがあってもUSE_LIVE_RATING_BACKENDのゲートで止まり、例外なく完走する")


## 3. snapshot_for_host_disconnect_penalty(): ホスト(peer_id==1)自身の役割・生存時間を
## 正しく読み取れること、対象外の状況では空辞書を返すこと
func _test_snapshot_for_host_disconnect_penalty() -> void:
	print("\n--- [3] snapshot_for_host_disconnect_penalty() ---")

	# 3-1: 非ランク戦では空辞書
	var spawns: Dictionary = {1: Vector3.ZERO}
	GameManager._start_round(1, 1.0, 1, spawns, true)
	GameManager.round_is_ranked = false
	_assert(GameManager.snapshot_for_host_disconnect_penalty().is_empty(),
		"非ランク戦のPLAYING中は空辞書")

	# 3-2: ランク戦・ホストが逃走者役
	GameManager.round_is_ranked = true
	GameManager.peer_profiles[1] = {"name": "Host", "rating": 1600, "puid": "host-puid-1"}
	GameManager.time_left = GameManager.ROUND_TIME - 30.0
	var snap: Dictionary = GameManager.snapshot_for_host_disconnect_penalty()
	_assert(snap.get("puid") == "host-puid-1", "ホストのpuidを取得できる")
	_assert(snap.get("was_runner") == true, "ホストが逃走者役なら was_runner=true")
	_assert(is_equal_approx(snap.get("survival"), 30.0), "survivalが経過時間と一致する")

	# 3-3: ランク戦・ホストが鬼役(runner_idが別ID)
	GameManager.runner_id = 2
	var snap2: Dictionary = GameManager.snapshot_for_host_disconnect_penalty()
	_assert(snap2.get("was_runner") == false, "ホストが鬼役なら was_runner=false")

	# 3-4: puid未設定(EOS無効等)なら空辞書
	GameManager.peer_profiles[1] = {"name": "Host", "rating": 1600}
	_assert(GameManager.snapshot_for_host_disconnect_penalty().is_empty(),
		"puidが無ければ報告しようがないので空辞書")

	# 3-5: WAITING中なら空辞書
	GameManager.state = GameManager.State.WAITING
	_assert(GameManager.snapshot_for_host_disconnect_penalty().is_empty(),
		"WAITING中は空辞書")

	GameManager.reset()


## 4. EosManager._pick_handoff_target(): can_host=1の候補から決定的な順序(puid辞書順)で
## 選ばれること、候補が無ければ空文字を返すこと。EOS呼び出しを含まない純粋関数なので
## 実バックエンドに触れずにfake HLobby/HLobbyMemberで検証できる
func _test_handoff_candidate_selection() -> void:
	print("\n--- [4] EosManager._pick_handoff_target() / can_host_of() ---")

	var saved_lobby: HLobby = EosManager._current_lobby
	var saved_is_host: bool = EosManager.is_host
	var saved_puid: String = EosManager.product_user_id

	var lobby := HLobby.new()
	lobby.lobby_id = "fake-lobby"
	lobby.owner_product_user_id = "self-puid"
	lobby.members = [
		_make_fake_member(lobby, "self-puid", false),
		_make_fake_member(lobby, "zzz-capable", true),
		_make_fake_member(lobby, "aaa-capable", true),
		_make_fake_member(lobby, "web-incapable", false),
	]

	EosManager._current_lobby = lobby
	EosManager.is_host = true
	EosManager.product_user_id = "self-puid"

	_assert(EosManager.can_host_of("self-puid") == false, "can_host=0のメンバーはfalse")
	_assert(EosManager.can_host_of("zzz-capable") == true, "can_host=1のメンバーはtrue")
	_assert(EosManager.can_host_of("not-a-member") == false, "存在しないメンバーはfalse")
	_assert(EosManager._pick_handoff_target() == "aaa-capable",
		"can_host=1の候補のうちpuid辞書順で最小のものが選ばれる")

	lobby.members = [
		_make_fake_member(lobby, "self-puid", false),
		_make_fake_member(lobby, "other-incapable", false),
	]
	_assert(EosManager._pick_handoff_target() == "",
		"ホスト可能な候補が誰もいなければ空文字(呼び出し側でマイグレーション断念と判断)")

	EosManager._current_lobby = saved_lobby
	EosManager.is_host = saved_is_host
	EosManager.product_user_id = saved_puid


func _make_fake_member(lobby: HLobby, puid: String, can_host: bool) -> HLobbyMember:
	var member := HLobbyMember.new(lobby)
	member.product_user_id = puid
	member.attributes = [HLobby.make_attribute("can_host", "1" if can_host else "0")]
	return member


# --- Phase 3 L-12: 実セーブ(user://profile.json / settings.json)の保護 ---
# このテストはラウンドを回す/プロフィールを触るため、通常のゲーム終了経路
# (GameManager._end_round() -> hud.gd -> ProfileManager.record_casual_match())から
# 間接的に save_profile() を踏み、開発機の実セーブを書き換えてしまう。
# _enter_tree/_exit_tree で挟むので、テスト本体のコードには一切触れていない。
# 詳細と実測値は tests/save_guard.gd のヘッダを参照。
const _SaveGuard := preload("res://tests/save_guard.gd")
var _save_backup := {}


func _enter_tree() -> void:
	_save_backup = _SaveGuard.backup()


func _exit_tree() -> void:
	_SaveGuard.restore(_save_backup)
