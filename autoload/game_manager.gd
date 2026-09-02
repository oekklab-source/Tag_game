extends Node

## ゲーム進行を管理する Autoload。
## 役割抽選・鬼の速度補正・タイマー・タッチ判定はすべてホスト側で実行し、
## 結果を RPC で全ピアへ配信する。

## HUD の演出（役割バッジのポップイン等）はエッジ検出が必要なので、
## 毎フレームのポーリングではなく状態遷移を通知する
signal state_changed(new_state: int)
## 「今 誰かに見られている」の変化。HUD のバナーはエッジで駆動する
signal spotted_changed(is_spotted: bool)
## 準備中の役割選択が変わった。HUD は毎フレーム読み直しているので購読不要だが、
## 演出をエッジで駆動したくなったときのために出しておく
signal roles_changed
signal debug_mode_changed(enabled: bool)

enum State { WAITING, PLAYING, RESULT }

## 決着のしかた。HUD の文言はこの値から組み立てる。
## 結果を表示用の文字列で持って `begins_with("RUNNER")` のように判定すると、
## 文言を書き換えた瞬間に勝敗判定が黙って壊れるため、状態と表示を分ける
enum EndReason { TIME_UP, TAGGED, RUNNER_LEFT }

## 通信の取り決めの版数。**RPC の引数を足す/減らす/並べ替えたら必ず上げる。**
##
## Godot の RPC は「メソッド名と引数の個数」が両ピアで一致していることを前提にしており、
## 食い違うと `Method expected N argument(s), but called with M` で黙って落ちる。
## 症状は「つながってはいるのに状態が同期しない・ラウンドが始まらない」で、
## 原因が非常に分かりにくい。Web 版はブラウザが古いビルドをキャッシュするため
## 特に起きやすいので、接続直後に突き合わせてはっきり知らせる
## v2: _start_round / _sync_state に鬼の人数（CPU 込み）を足した
const PROTOCOL_VERSION := 2
## 参加者から版数の返事が来るのを待つ時間。古いビルドには ack_version 自体が
## 無いので、無反応もまた「食い違っている」ことの手がかりになる。
## ただし回線が遅いだけの可能性もあるので、無反応では蹴らず警告に留める
const VERSION_ACK_TIMEOUT := 10.0

const ROUND_TIME := 180.0
const RESULT_TIME := 5.0
## 「見えないこと」自体がヘッドスタートになったので、初期位置を離れる分で足りる。
## 8秒 ≒ 69m（約1.3ゾーン分）
const HEAD_START := 8.0
## 1ラウンドの定員。逃走者1人 + 鬼 MAX_HUNTERS 人 = 4人で遊ぶ。
## 人間が足りない分は CPU 鬼で埋めるので、1人でも4人でも構成は変わらない。
## 鬼を減らした分の圧力は HunterSquad の連携（分担探索・挟み込み）で補っている。
## ぬるいと感じたらまずここを 4 に上げるのが安全（CPU の速度は触らない）
const MAX_HUNTERS := 3
const CPU_RUNNER_ID := 0
## 逃走者は中央ゾーン。座標を直書きすると ZONE_GROUND[4] == 0.0 に暗黙依存し、
## 中央の地面高さを変えた瞬間に宙に浮く（あるいは床に埋まる）
const RUNNER_SPAWN_ZONE := 4
## 鬼のスポーンゾーン。広いマップでは逃走者の周囲に固めるより
## ゾーン中心に散らした方がマップ全体を覆えて機能する。中央(4)は逃走者用。
## 先頭3つ（北・南西・南東）が中央を囲む三角になるよう並べてある。
## 定員が鬼3人なので、ここの並び順がそのまま初期配置の広がりを決める
const HUNTER_SPAWN_ZONES: Array[int] = [1, 6, 8, 3, 5, 0, 2, 7]
# ゾーンごとに地面の高さが違うため、スポーンは高めから落として着地させる
const HUNTER_SPAWN_HEIGHT := 3.0

## --- 視界（索敵） -------------------------------------------------------
## 鬼は逃走者の位置を既定では一切知らない。誰か一人が「視認」した時だけ、
## 逃走者がいる**ゾーン**が全鬼へ共有される。

## ゾーン幅(53〜54m)よりわずかに短い。ゾーン中心からそのゾーンをほぼ覆えるが、
## 160mマップを見通すことは絶対にできない = 「自分のゾーンか隣接でなければ見えない」
const SIGHT_RANGE := 48.0
## 水平の全角。Camera3D は既定の垂直75°で 16:9 なら水平約107°なので、
## 検出コーンを画面より意図的に狭くしてある（見えていないのに通報される方が悪い）
const SIGHT_FOV_DEG := 100.0
## CPU鬼だけの視界。CPUには画面が無く「見えていないのに通報される」不公平が
## 起きないため、人間側(SIGHT_RANGE/SIGHT_FOV_DEG)を広げずにここだけを強くする。
## 75m はゾーン間隔(53.5m)を超えるので隣接ゾーンまで見通せ、180°は
## cpu_hunter.gd の首振り(SCAN_ANGLE 45°)と合わさって実効約270°になる
const CPU_SIGHT_RANGE := 75.0
const CPU_SIGHT_FOV_DEG := 180.0
const SIGHT_EYE := 1.5
## 頭と胴。どちらか通れば視認とする。単一レイだと ？ブロック1個で全身が隠れてしまう
const SIGHT_TARGET_Y: Array[float] = [1.55, 0.85]
## World(1) + Platform(8)。Character(2) を含めないので鬼同士や逃走者自身で自己遮蔽しない。
## player.tscn の SpringArm3D.collision_mask と同じ値 = カメラアームが当たる物は視線も遮る
const SIGHT_MASK := 9
const SIGHT_TICK := 0.05    # 20Hz。発見からCHASE入りまでの遅延を詰める
const INTEL_TIME := 16.0    # 見失ってからゾーン情報が消えるまで
const HUNTER_STAMINA_DEFAULT := 100.0
const HUNTER_STAMINA_THREE_PLAYER := 120.0
const HUNTER_STAMINA_TWO_PLAYER := 150.0
## 視認が途切れてから spotted を落とすまでの猶予。これが無いと逃走者が柱の陰を
## 横切るだけで 20Hz でばたつき、RPC を撒き散らしバナーも点滅する
const SPOTTED_HOLD := 2.5

var state: int = State.WAITING
var runner_id := -1
## 準備中の「逃げる役」の立候補。枠は1つしかないので peer_id 1個で足りる。
## -1 = 未定（ラウンド開始時にランダムで選ぶ）。ホストは Tab で誰にでも付け替えられる
var wanted_runner := -1
var debug_cpu_runner := false
var hunter_mult := 1.0
## このラウンドの鬼の人数（CPU 鬼を含む）。速度補正とスタミナの基準になるので、
## 人間だけを数えていると CPU で埋めた分がバランス計算から漏れる
var hunter_count := 1
var time_left := ROUND_TIME
var head_start_left := 0.0
var result_runner_won := false
var result_reason: int = EndReason.TIME_UP
var result_left := 0.0  # リザルト表示の残り秒（HUD の "Next round in N" 用）
## 動く床・回転床の位相に使う全ピア共通の時計。
## 物理 delta は全ピアで固定値なので、ラウンド開始（reliable RPC）で
## 揃えれば以後もずれない。
var world_time := 0.0

## 索敵の共有状態（全ピアが持つ）
var spotted := false      # 今この瞬間、誰かが視認している
var spotted_zone := -1    # 最後に目撃されたゾーン。-1 = 情報なし
var intel_left := 0.0

## ホストのロビーに出す警告（参加者のビルドが違う等）
var peer_notice := ""
var _peer_notice_left := 0.0
var _awaiting_version := {}   # ホスト専用。peer_id -> 返事待ちの経過秒

var _sight_timer := 0.0
var _seer_ids := {}       # ホスト専用。視認中の鬼の instance_id
var _no_sight_for := 0.0

## 鬼の連携（分担探索・張り込み・挟み込み）の共有状態。ホスト専用。
## CPU 鬼はここへ「自分の担当」を問い合わせるだけで、互いを直接見に行かない
var squad := HunterSquad.new()


func reset() -> void:
	state = State.WAITING
	runner_id = -1
	wanted_runner = -1
	hunter_mult = 1.0
	hunter_count = 1
	squad.begin_round()
	time_left = ROUND_TIME
	head_start_left = 0.0
	result_runner_won = false
	result_reason = EndReason.TIME_UP
	peer_notice = ""
	_peer_notice_left = 0.0
	_awaiting_version.clear()
	_clear_intel()


func _clear_intel() -> void:
	var was := spotted
	spotted = false
	spotted_zone = -1
	intel_left = 0.0
	_seer_ids.clear()
	_no_sight_for = 0.0
	_sight_timer = 0.0
	if was:
		spotted_changed.emit(false)


## マップの色分けエリア判定（レイアウト定義は WorldData に一本化してある）
func zone_at(pos: Vector3) -> int:
	return WorldData.zone_index(pos)


## 鬼の人数に応じた速度補正。広いマップでは鬼が分散するので、
## 以前の 80% のような強い減速は逆効果になる
func hunter_mult_for(count: int) -> float:
	if count >= 5:
		return 0.90
	if count >= 3:
		return 0.95
	return 1.0


## 鬼のブースト時間は人数が少ないほど長くする。
## 1人の逃走者に対して鬼が 1 / 2 / 3人以上のとき、150 / 120 / 100。
func hunter_stamina_max_for(count: int) -> float:
	if count <= 1:
		return HUNTER_STAMINA_TWO_PLAYER
	if count == 2:
		return HUNTER_STAMINA_THREE_PLAYER
	return HUNTER_STAMINA_DEFAULT


func stamina_max_for(peer_id: int) -> float:
	if state != State.PLAYING or peer_id == runner_id:
		return HUNTER_STAMINA_DEFAULT
	# hunter_count は CPU 鬼を含む実数で、ラウンド開始時に全ピアへ配ってある
	return hunter_stamina_max_for(maxi(hunter_count, 1))


func get_speed_mult(peer_id: int) -> float:
	if state == State.PLAYING and peer_id != runner_id:
		return hunter_mult
	return 1.0


func get_runner() -> Node:
	if runner_id == CPU_RUNNER_ID:
		for cpu in get_tree().get_nodes_in_group("cpu_runners"):
			return cpu
		return null
	return _find_player(runner_id)


## 今ラウンドの鬼すべて（人間 + CPU）。視界の走査と連携の割り当てが同じ集合を
## 見るように一本化してある。人間の鬼を数え漏らすと CPU が人間の担当を重複して取る
func hunters() -> Array[Node3D]:
	var out: Array[Node3D] = []
	var runner := get_runner()
	for p in get_tree().get_nodes_in_group("players"):
		if p != runner:
			out.append(p)
	for c in get_tree().get_nodes_in_group("cpu_hunters"):
		out.append(c)
	return out


func _find_player(peer_id: int) -> Node:
	for p in get_tree().get_nodes_in_group("players"):
		if p.name == str(peer_id):
			return p
	return null


## 表示名。sync_nickname が未到着/未設定ならフォールバックの仮表記を返す
func nickname_for(peer_id: int) -> String:
	var p := _find_player(peer_id)
	if p and "sync_nickname" in p and not p.sync_nickname.is_empty():
		return p.sync_nickname
	return "プレイヤー %d" % peer_id


## --- ホスト側ロジック -------------------------------------------------

## 全ピア共通のプレイヤーの並び順。
## HUD の一覧・Tab の順送り・鬼のスポーン割り当てが食い違わないよう、
## グループの取得順（不定）ではなく peer_id 順に揃える
func player_ids() -> Array[int]:
	var ids: Array[int] = []
	for p in get_tree().get_nodes_in_group("players"):
		ids.append(String(p.name).to_int())
	ids.sort()
	return ids


## --- 準備中の役割選択 ---------------------------------------------------
## 「逃げる役」は常に1人。誰が立候補しているかを wanted_runner 1個で持ち、
## 新しく立候補した人が枠を奪う（前の立候補者は自動的に鬼に戻る）。
## ホストは cycle_wanted_runner() で誰にでも付け替えられる。

## 自分の立候補をトグルする。全ピアが押せる。
## ホストは rpc_id(1) の自己配信に頼らず直接呼ぶ（player.gd の _request_drop と同じ）
func toggle_my_role() -> void:
	if state != State.WAITING or debug_cpu_runner:
		return
	var me := multiplayer.get_unique_id()
	var want := wanted_runner != me
	if multiplayer.is_server():
		_apply_wanted(me, want)
	else:
		request_runner.rpc_id(1, want)


## クライアントからの「逃げる役をやりたい / やめる」
@rpc("any_peer", "reliable")
func request_runner(want: bool) -> void:
	if not multiplayer.is_server():
		return
	_apply_wanted(multiplayer.get_remote_sender_id(), want)


func _apply_wanted(peer_id: int, want: bool) -> void:
	if not multiplayer.is_server() or state != State.WAITING:
		return
	var next := wanted_runner
	if want:
		next = peer_id
	elif wanted_runner == peer_id:
		next = -1
	if next != wanted_runner:
		_set_wanted_runner.rpc(next)


## ホスト専用。特定のプレイヤーを逃走者に指名する（ロビーの一覧のクリック）。
## 既にその人なら未定へ戻す（同じ行をもう一度押したら取り消せる）
func set_wanted_runner_to(peer_id: int) -> void:
	if not multiplayer.is_server() or state != State.WAITING:
		return
	var next := -1 if wanted_runner == peer_id else peer_id
	if next != wanted_runner:
		_set_wanted_runner.rpc(next)


## ホスト専用。プレイヤーを順送りして逃走者を指名する（準備中の入れ替え）。
## 一巡に「未定(-1)」も含めるので、全員鬼＝ランダムに戻すこともできる
func set_debug_cpu_runner(enabled: bool) -> void:
	if not multiplayer.is_server() or state != State.WAITING:
		return
	_set_debug_cpu_runner.rpc(enabled)


func cycle_wanted_runner() -> void:
	if not multiplayer.is_server() or state != State.WAITING:
		return
	var order: Array = player_ids()
	if order.is_empty():
		return
	order.append(-1)
	var i := order.find(wanted_runner)
	_set_wanted_runner.rpc(order[(i + 1) % order.size()])


func request_start_round() -> void:
	if not multiplayer.is_server() or state == State.PLAYING:
		return
	var ids := player_ids()
	if ids.is_empty():
		return
	_clear_cpu_characters()
	var solo := ids.size() == 1
	var solo_debug_runner := solo and debug_cpu_runner
	# 1人だけなら通常ソロ: 自分が Runner になり CPU 鬼が追う。
	# デバッグONのときだけ逆にして、自分が Hunter、CPU が Runner になる。
	var new_runner: int
	if solo_debug_runner:
		new_runner = CPU_RUNNER_ID
	elif solo:
		new_runner = ids[0]
	else:
		# 準備中に選ばれた人がいればその人。誰も立候補していなければランダム
		new_runner = wanted_runner if ids.has(wanted_runner) else ids.pick_random()

	# 鬼は「逃走者以外の人間」が務め、足りない分を CPU で埋めて必ず定員にする。
	# 人間が定員を超えたら全員が鬼（あぶれた人の受け皿が無いため上限は掛けない）。
	# デバッグ（CPU逃走者）だけは1対1の検証用なので CPU 鬼を足さない
	var human_hunters := ids.size() if solo_debug_runner else ids.size() - 1
	var cpu_hunters := 0 if solo_debug_runner else maxi(MAX_HUNTERS - human_hunters, 0)
	var total_hunters := maxi(human_hunters + cpu_hunters, 1)
	var mult := hunter_mult_for(total_hunters)

	# スポーン位置: Runner は中央ゾーン、Hunter は外周ゾーンの中心に散らす。
	# CPU は人間の続き番号を使い、同じゾーンに重ねない
	var spawns := {}
	if not solo_debug_runner:
		spawns[new_runner] = _runner_spawn()
	var i := 0
	for id in ids:
		if id == new_runner:
			continue
		spawns[id] = _hunter_spawn(i)
		i += 1
	_start_round.rpc(new_runner, mult, total_hunters, spawns)
	var world := get_tree().current_scene
	if solo_debug_runner:
		_sync_head.rpc(0.0)
		if world.has_method("spawn_cpu_runner"):
			world.spawn_cpu_runner(_runner_spawn())
	elif world.has_method("spawn_cpu_hunter"):
		for n in cpu_hunters:
			world.spawn_cpu_hunter(_hunter_spawn(i + n))


func _runner_spawn() -> Vector3:
	return WorldData.zone_center(RUNNER_SPAWN_ZONE) + Vector3(0, HUNTER_SPAWN_HEIGHT, 0)


func _hunter_spawn(i: int) -> Vector3:
	var zones := HUNTER_SPAWN_ZONES.size()
	var zone: int = HUNTER_SPAWN_ZONES[i % zones]
	var lap := i / zones
	if lap == 0:
		return WorldData.zone_center(zone) + Vector3(0, HUNTER_SPAWN_HEIGHT, 0)
	# 9人目以降は同じゾーンの2周目。中心に重ねると出た瞬間に固まる/頭に乗るので、
	# 黄金角で中心からずらす
	var a := float(lap) * 2.39996
	var r := 4.0 * float(lap)
	var p := WorldData.zone_point(zone, cos(a) * r, sin(a) * r)
	return p + Vector3(0, HUNTER_SPAWN_HEIGHT, 0)


func _clear_cpu_characters() -> void:
	_clear_cpu_hunters()
	_clear_cpu_runners()


func _clear_cpu_hunters() -> void:
	for cpu in get_tree().get_nodes_in_group("cpu_hunters"):
		# queue_free() だけではこのフレーム中グループに残る。残っていると
		# 同フレームにテレポートしたプレイヤーが消滅予定の CPU に乗ってしまい、
		# squad の担当ゾーンも消滅予定の個体に押さえられたままになる
		cpu.remove_from_group("cpu_hunters")
		cpu.queue_free()


func _clear_cpu_runners() -> void:
	for cpu in get_tree().get_nodes_in_group("cpu_runners"):
		cpu.remove_from_group("cpu_runners")
		cpu.queue_free()


func _physics_process(delta: float) -> void:
	world_time += delta  # ギミックの位相用。全ピアで進める
	if not multiplayer.is_server() or state != State.PLAYING:
		return
	# ヘッドスタート中も視認は成立させる（凍っていても目はある）。
	# 検出が視界のみになった分の埋め合わせにもなる
	_update_sight(delta)
	# 連携の割り当てもヘッドスタート中から更新する。凍結が明けた瞬間に
	# 全員が担当ゾーンを持って散り始めるので、出だしの数秒を無駄にしない
	squad.tick(delta, hunters(), get_runner(), spotted_zone)
	# ヘッドスタート中は鬼が凍結され、本タイマーとタッチ判定は動かない
	if head_start_left > 0.0:
		var prev_head := ceili(head_start_left)
		head_start_left = maxf(head_start_left - delta, 0.0)
		if head_start_left == 0.0 or ceili(head_start_left) != prev_head:
			_sync_head.rpc(head_start_left)
		if head_start_left == 0.0:
			_sweep_tag_overlaps()
		return
	var prev_sec := ceili(time_left)
	time_left -= delta
	if time_left <= 0.0:
		_end_round.rpc(true, EndReason.TIME_UP)
		return
	if ceili(time_left) != prev_sec:
		_sync_time.rpc(time_left)


## --- 視界判定 -----------------------------------------------------------

## hunter が target を「今」見ているか。
##
## 向きは**カメラではなくボディの -Z** を使う。player.gd は rotate_y() でボディ自体を
## 回してピッチだけ SpringArm に渡すため、ボディの -Z が水平の視線方向になる。
## 決定的なのはレプリケーションで、player.tscn は position と rotation だけを同期するので
## サーバは各リモート鬼のヨーを持っている（カメラは同期されない）。
## ヨーをボディから外すとこの仕組みは静かに壊れるので注意。
##
## 上下方向の判定は入れない。段丘マップは高低差が8mあり、垂直コーンや3D距離だと
## CLOUD DECK(地面8m) から CASTLE COURT(0m) を見下ろす時に不可解な false negative が出る。
##
## CPU鬼だけ CPU_SIGHT_RANGE / CPU_SIGHT_FOV_DEG を使う。人間の鬼は自分の画面で
## 判断できるので検出コーンを画面より狭く保つ必要があるが、CPUにはその制約が無い
func can_see(hunter: Node3D, target: Node3D) -> bool:
	if hunter == null or target == null:
		return false
	var is_cpu := hunter.is_in_group("cpu_hunters")
	var sight_range := CPU_SIGHT_RANGE if is_cpu else SIGHT_RANGE
	var sight_fov_deg := CPU_SIGHT_FOV_DEG if is_cpu else SIGHT_FOV_DEG
	var to_target := target.global_position - hunter.global_position
	var t2 := Vector2(to_target.x, to_target.z)
	if t2.length() > sight_range:
		return false
	var fwd := -hunter.global_transform.basis.z
	var f2 := Vector2(fwd.x, fwd.z)
	if f2.length_squared() < 1e-6 or t2.length_squared() < 1e-6:
		return false
	if f2.normalized().dot(t2.normalized()) < cos(deg_to_rad(sight_fov_deg * 0.5)):
		return false
	# GameManager は Node なので get_world_3d() を持たない。空間は対象ノード側から取る。
	# また intersect_ray は物理フレーム内から呼ぶこと（_process だと flushing エラー）
	var space := hunter.get_world_3d().direct_space_state
	var from := hunter.global_position + Vector3(0, SIGHT_EYE, 0)
	for y in SIGHT_TARGET_Y:
		var q := PhysicsRayQueryParameters3D.create(
			from, target.global_position + Vector3(0, y, 0), SIGHT_MASK)
		if space.intersect_ray(q).is_empty():
			return true
	return false


## CPU が「自分は見えているか」を問い合わせる窓口。
## CPU 側で個別にレイを飛ばさせず、判定はここに一本化する
func hunter_sees_runner(h: Node) -> bool:
	return _seer_ids.has(h.get_instance_id())


## ホストのみ。全鬼を走査して共有情報を更新する
func _update_sight(delta: float) -> void:
	var runner := get_runner()
	if runner == null:
		return
	_sight_timer -= delta
	if _sight_timer <= 0.0:
		_sight_timer = SIGHT_TICK
		# 鬼を tick 間で分散させない。一括評価の方が spotted_zone が一貫する
		_seer_ids.clear()
		for h in hunters():
			if can_see(h, runner):
				_seer_ids[h.get_instance_id()] = true

	# 新しい値はローカルに組み立て、代入と signal は必ず _set_intel に通す。
	# ここで直接 spotted を書き換えると、call_local の _set_intel が
	# 「変化なし」と判断してホスト側だけ spotted_changed が飛ばなくなる
	var new_zone := spotted_zone
	var new_intel := intel_left
	var new_live := spotted
	if not _seer_ids.is_empty():
		new_zone = zone_at(runner.global_position)
		new_intel = INTEL_TIME
		new_live = true
		_no_sight_for = 0.0
	else:
		_no_sight_for += delta
		new_live = spotted and _no_sight_for < SPOTTED_HOLD
		new_intel = maxf(intel_left - delta, 0.0)
		if new_intel == 0.0:
			new_zone = -1

	if new_zone != spotted_zone or new_live != spotted:
		_set_intel.rpc(new_zone, new_intel, new_live)
	else:
		var prev_sec := ceili(intel_left)
		intel_left = new_intel
		if new_intel > 0.0 and ceili(new_intel) != prev_sec:
			_sync_intel.rpc(new_intel)  # 1Hz の補正だけ


## --- 置き物アイテム -----------------------------------------------------

## クライアントから「ここに置きたい」と要求する。生成はサーバだけが行う
## （クライアントが自前で生成しても MultiplayerSpawner を通らず他ピアへ同期されない）。
## Autoload なのでノードパスが全ピアで一致し、RPC の宛先として安定している
## 条件は player.gd の frozen（アイテムを使える条件）と必ず一致させること。
## ここだけ PLAYING 限定にしていたため、ラウンド外で？ブロックを取って使うと
## アイテムだけ消えて何も置かれなかった（？ブロック側にも状態の判定は無い）。
## 「動ける時は必ず使える」に揃えてある
@rpc("any_peer", "reliable")
func request_drop(kind: int, pos: Vector3, yaw: float,
		launch_velocity := Vector3.ZERO) -> void:
	if not multiplayer.is_server() or state == State.RESULT:
		return
	var sender := multiplayer.get_remote_sender_id()
	var thrower_id := multiplayer.get_unique_id() if sender == 0 else sender
	var world := get_tree().current_scene
	if world and world.has_method("spawn_dropped_item"):
		world.spawn_dropped_item(kind, pos, yaw, launch_velocity, thrower_id)


## 接触判定。各キャラの TagArea(Area3D) から body_entered 経由でホスト側のみ呼ばれる。
## サーバはレプリケートされた全ボディのコピーを持つため、ここで重なりを判定できる。
func report_touch(a: Node3D, b: Node3D) -> void:
	if not multiplayer.is_server() or state != State.PLAYING or head_start_left > 0.0:
		return
	var runner := get_runner()
	if runner == null:
		return
	# 片方だけが逃走者のときにだけ成立する（鬼同士の接触は無視）
	if (a == runner) == (b == runner):
		return
	_end_round.rpc(false, EndReason.TAGGED)


## body_entered は「入った瞬間」しか鳴らないため、
## ヘッドスタート終了時に既に重なっている組み合わせを一度だけ拾う。
func _sweep_tag_overlaps() -> void:
	var runner := get_runner()
	if runner == null:
		return
	var area := runner.get_node_or_null("TagArea") as Area3D
	if area == null:
		return
	for body in area.get_overlapping_bodies():
		report_touch(runner, body)
		if state != State.PLAYING:
			return


func _process(delta: float) -> void:
	if state == State.RESULT:
		result_left = maxf(result_left - delta, 0.0)
	if _peer_notice_left > 0.0:
		_peer_notice_left = maxf(_peer_notice_left - delta, 0.0)
		if _peer_notice_left == 0.0:
			peer_notice = ""
	if multiplayer.is_server() and not _awaiting_version.is_empty():
		_tick_version_checks(delta)
	# クライアント側はローカルで滑らかに減算し、毎秒の同期で補正する
	if multiplayer.is_server() or state != State.PLAYING:
		return
	if head_start_left > 0.0:
		head_start_left = maxf(head_start_left - delta, 0.0)
	else:
		time_left = maxf(time_left - delta, 0.0)
	# 情報の残り秒もローカルで滑らかに減らす。1Hz の同期が落ちても自己修復する
	if intel_left > 0.0:
		intel_left = maxf(intel_left - delta, 0.0)
		if intel_left == 0.0:
			spotted_zone = -1


## ホストのみ。接続直後に版数を送り、返事が来るまで見張る
func begin_version_check(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	_awaiting_version[peer_id] = 0.0
	check_version.rpc_id(peer_id, PROTOCOL_VERSION)


## ホスト -> 参加者。**この2つのシグネチャだけは絶対に変えないこと。**
## 変えると照合そのものが食い違って、何も知らせられなくなる
@rpc("authority", "reliable")
func check_version(host_version: int) -> void:
	ack_version.rpc_id(1, PROTOCOL_VERSION)
	if host_version == PROTOCOL_VERSION:
		return
	NetworkManager.last_error = (
		"ゲームのバージョンが違います（ホスト v%d / あなた v%d）。
"
		+ "ブラウザなら再読み込み（Ctrl+Shift+R）、PC なら最新版で起動しなおしてください。"
	) % [host_version, PROTOCOL_VERSION]
	NetworkManager.leave()


## 参加者 -> ホスト
@rpc("any_peer", "reliable")
func ack_version(peer_version: int) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	_awaiting_version.erase(id)
	if peer_version == PROTOCOL_VERSION:
		return
	# 食い違いが確定した場合だけ切る。放っておくと「つながっているのに
	# 状態が同期しない」まま延々と続き、原因が分からない
	notify_host("参加者のビルドが違います（あなた v%d / 相手 v%d）。
Web 版を再デプロイして、ブラウザを再読み込みしてもらってください。"
		% [PROTOCOL_VERSION, peer_version])
	multiplayer.multiplayer_peer.disconnect_peer(id)


## 返事が来ない参加者を見張る。回線が遅いだけのこともあるので蹴らず警告に留める
func _tick_version_checks(delta: float) -> void:
	for id in _awaiting_version.keys():
		_awaiting_version[id] = _awaiting_version[id] + delta
		if _awaiting_version[id] < VERSION_ACK_TIMEOUT:
			continue
		_awaiting_version.erase(id)
		notify_host("参加者 %d から応答がありません。
古いビルドで参加している可能性があります（Web 版の再デプロイと再読み込みを試してください）。" % id)


func notify_host(text: String) -> void:
	peer_notice = text
	_peer_notice_left = 20.0


## 参加した本人へ湧き位置を伝える（ホストのみ呼ぶ）。
##
## 位置の権威は各クライアントにあるので、ラウンド開始と同じく本人に動いてもらう。
## MultiplayerSpawner のスポーン通知より先にこの RPC が着くことがあるため、
## 自分のプレイヤーが現れるまで数フレーム待つ。
@rpc("authority", "reliable")
func place_player(pos: Vector3) -> void:
	var me := _find_player(multiplayer.get_unique_id())
	var waited := 0
	while me == null and waited < 60:
		await get_tree().process_frame
		waited += 1
		me = _find_player(multiplayer.get_unique_id())
	if me:
		me.teleport(pos)


## 途中参加者へ現在の状態を送る（ホストのみ呼ぶ）
func sync_to_peer(peer_id: int) -> void:
	if multiplayer.is_server():
		_sync_state.rpc_id(peer_id, state, runner_id, wanted_runner, hunter_mult,
			hunter_count, time_left, head_start_left, result_runner_won, result_reason,
			spotted_zone, intel_left, spotted)


func on_player_left(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	_awaiting_version.erase(peer_id)
	# 抜けた人が指名されたままだと、次のラウンドで誰も逃走者にならない
	if wanted_runner == peer_id:
		_set_wanted_runner.rpc(-1)
	if state == State.PLAYING and peer_id == runner_id:
		_end_round.rpc(false, EndReason.RUNNER_LEFT)


## リザルトを見せ終えたら WAITING に戻して**止める**。
## ここで次のラウンドを自動で始めてしまうと役割を選び直す時間が無くなるので、
## 次はホストが Enter を押すまで始まらない
func _schedule_next_round() -> void:
	await get_tree().create_timer(RESULT_TIME).timeout
	if state != State.RESULT:
		return
	_back_to_waiting.rpc()


## --- RPC（ホスト -> 全ピア） -------------------------------------------

@rpc("authority", "call_local", "reliable")
func _start_round(new_runner: int, mult: float, hunters_n: int, spawns: Dictionary) -> void:
	runner_id = new_runner
	hunter_mult = mult
	hunter_count = hunters_n
	squad.begin_round()  # 前ラウンドの担当を持ち越さない（ホスト以外では空回り）
	time_left = ROUND_TIME
	head_start_left = HEAD_START
	state = State.PLAYING
	world_time = 0.0  # 全ピアのギミック位相をここで揃える
	_clear_intel()    # 前ラウンドの目撃情報を持ち越さない
	state_changed.emit(state)
	# 位置の権威は各クライアントにあるため、自分のプレイヤーは自分で移動する
	var my_id := multiplayer.get_unique_id()
	if spawns.has(my_id):
		var me := _find_player(my_id)
		if me:
			me.teleport(spawns[my_id])


@rpc("authority", "call_local", "unreliable")
func _sync_time(t: float) -> void:
	time_left = t


@rpc("authority", "call_local", "unreliable")
func _sync_head(t: float) -> void:
	head_start_left = t


@rpc("authority", "call_local", "reliable")
func _end_round(runner_won: bool, reason: int) -> void:
	state = State.RESULT
	head_start_left = 0.0
	result_runner_won = runner_won
	result_reason = reason
	result_left = RESULT_TIME
	_clear_intel()
	state_changed.emit(state)
	if multiplayer.is_server():
		_schedule_next_round()


## 準備中の立候補の配信。WAITING に戻っても値は持ち越すので、
## 変えたい人だけが変えればよい
@rpc("authority", "call_local", "reliable")
func _set_wanted_runner(id: int) -> void:
	wanted_runner = id
	roles_changed.emit()


@rpc("authority", "call_local", "reliable")
func _set_debug_cpu_runner(enabled: bool) -> void:
	debug_cpu_runner = enabled
	debug_mode_changed.emit(enabled)
	roles_changed.emit()


@rpc("authority", "call_local", "reliable")
func _back_to_waiting() -> void:
	state = State.WAITING
	runner_id = -1
	head_start_left = 0.0
	result_left = 0.0
	_clear_intel()
	squad.begin_round()
	state_changed.emit(state)
	if multiplayer.is_server():
		_clear_cpu_characters()


## 目撃ゾーンや「見られている」状態が変わった瞬間だけ送る（毎フレームは送らない）
@rpc("authority", "call_local", "reliable")
func _set_intel(zone: int, left: float, live: bool) -> void:
	spotted_zone = zone
	intel_left = left
	var was := spotted
	spotted = live
	if was != live:
		spotted_changed.emit(live)


## 残り秒の補正。_sync_time / _sync_head と同じ 1Hz unreliable
@rpc("authority", "call_local", "unreliable")
func _sync_intel(left: float) -> void:
	intel_left = left


@rpc("authority", "call_remote", "reliable")
func _sync_state(s: int, r_id: int, wanted: int, mult: float, hunters_n: int,
		t: float, head: float,
		won: bool, reason: int, zone: int, intel: float, live: bool) -> void:
	state = s
	runner_id = r_id
	wanted_runner = wanted
	hunter_mult = mult
	hunter_count = hunters_n
	time_left = t
	head_start_left = head
	result_runner_won = won
	result_reason = reason
	spotted_zone = zone
	intel_left = intel
	var was := spotted
	spotted = live
	state_changed.emit(state)
	roles_changed.emit()
	if was != live:
		spotted_changed.emit(live)
