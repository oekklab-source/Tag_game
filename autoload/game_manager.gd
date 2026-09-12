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
## ②④ peer_profiles（他ピアのレート/ティア/コスチューム）が更新された
signal profiles_changed
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
## 特に起きやすいので、接続直後に突き合わせてはっきり知らせる。
## **RPC の引数だけでなく、player.tscn の同期プロパティを足す/減らす場合も上げること。**
## スポーン状態のペイロードが変わり、症状は RPC の食い違いと同じく分かりにくい。
## v2: _start_round / _sync_state に鬼の人数（CPU 込み）を足した
## v3: player.tscn の同期プロパティに sync_emote（エモート）を足した
## v4: ②④ report_profile/_sync_profiles RPC を追加したため
## v5: _start_round に is_eos_matched 引数を追加したため
## (レーティング戦=ランダム鬼/プライベート(DirectConnect)=立候補鬼の区別に必要。
## 各ピアがNetworkManager.matched_via_eos_lobbyを別々にローカル判定すると、
## 「ホストはEOSロビーで部屋作成、招待された側はDirectConnectで参加」のような
## 既存の招待フロー(friend_screen.gdのinvite_to_lobby)でピア間の判定が食い違いうる。
## ホストが一度だけ決めてRPC引数として全ピアへ配ることで、この不整合を防ぐ)
## v6: game_manager.gd の構造分割で 索敵(_set_intel/_sync_intel)・バージョン確認
## (check_version/ack_version)・ホストマイグレーション(_set_runner_cpu)のRPCを
## GameManager本体から子ノード(autoload/game/*.gd)へ移した。ペイロード形式自体は
## 変わっていないが、RPCの宛先ノードパスが変わるため上げる
## v7: tier_lock不一致で拒否する際、disconnect_peer()の前に理由を伝える
## notify_rejected RPCを追加したため
const PROTOCOL_VERSION := 7

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
## 定数・判定ロジックの実体は autoload/game/sight_system.gd(子ノード _sight)に
## 集約してある。INTEL_TIME だけは外部(テスト等)から GameManager.INTEL_TIME で
## 参照されているため、単一の定数を分裂させずにそのまま再エクスポートする。
## class_name(SightSystem等)ではなくpreloadで参照するのは、class_nameのグローバル
## 登録がheadless単体実行だと更新されておらず"not declared in the current scope"に
## なるケースがあったため(エディタでプロジェクトを開いた後は問題にならないはずだが、
## CIやheadlessテストでの再現性を優先してpreloadに統一する)
const _SightSystemScript := preload("res://autoload/game/sight_system.gd")
const _VersionGateScript := preload("res://autoload/game/version_gate.gd")
const _HostMigrationScript := preload("res://autoload/game/host_migration.gd")

const INTEL_TIME := _SightSystemScript.INTEL_TIME

const HUNTER_STAMINA_DEFAULT := 100.0
const HUNTER_STAMINA_THREE_PLAYER := 120.0
const HUNTER_STAMINA_TWO_PLAYER := 150.0

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
var tagger_peer_id := -1
var result_left := 0.0  # リザルト表示の残り秒（HUD の "Next round in N" 用）
## このラウンドがレート対象か。_start_round() で全ピアが各自ローカルに計算する
## （RPC引数を増やすと PROTOCOL_VERSION を上げる必要が出るため、意図的に同期しない）。
## 人間が2人以上（自分以外に少なくとも1人）いれば true。CPU戦（自分1人）は常に false
var round_is_ranked := false
## このラウンドの鬼の人数（CPU含む）。hud.gd 側での再計算をやめて一本化するために持つ
var round_hunter_count := 0
## 動く床・回転床の位相に使う全ピア共通の時計。
## 物理 delta は全ピアで固定値なので、ラウンド開始（reliable RPC）で
## 揃えれば以後もずれない。
var world_time := 0.0

## 索敵の共有状態（全ピアが持つ）。実体は子ノード _sight(SightSystem)が持ち、
## ここは外部の呼び出し規約(GameManager.spotted 等)を変えないための薄い転送
var spotted: bool:
	get: return _sight.spotted
	set(v): _sight.spotted = v
var spotted_zone: int:    # 最後に目撃されたゾーン。-1 = 情報なし
	get: return _sight.spotted_zone
	set(v): _sight.spotted_zone = v
var intel_left: float:
	get: return _sight.intel_left
	set(v): _sight.intel_left = v

## ホストのロビーに出す警告（参加者のビルドが違う等）
var peer_notice := ""
var _peer_notice_left := 0.0

## ②④ 他ピアのレート/ティア/コスチューム。peer_id -> {"name","rating","tier","costume","colors"}
var peer_profiles := {}
## ②ホストが「同じレート帯のみ参加可」を選んでいるか。room_match_dialog がホスト開始前に設定する
var tier_lock_enabled := false
## 待機中に着せ替え/ショップ/フレンドをオーバーレイ表示している間はtrue。
## hud.gd が開閉のたびに設定する。world.gd はこれを見て、オーバーレイ操作中に
## R/Tab/Enterのロビーショートカットが誤爆しないようガードする
var lobby_overlay_open := false

## 視認中の鬼の instance_id。tests/test_phase3_cpu.gd が直接 .clear() するため、
## コピーではなく _sight が持つ実体の参照をそのまま返す
var _seer_ids: Dictionary:
	get: return _sight._seer_ids

## 子ノードとして分割したサブシステム(視界/バージョン確認/ホストマイグレーション)。
## HunterSquad と同じ流儀でここでインスタンス化し、_ready() で add_child する
## (@rpc を含むためNode派生。ノードパスを全ピアで一致させるためadd_child自体は
## _ready()で行う必要があるが、インスタンス自体はここで作ってよい)
var _sight := _SightSystemScript.new()
var _version_gate := _VersionGateScript.new()
var _host_migration := _HostMigrationScript.new()

## 鬼の連携（分担探索・張り込み・挟み込み）の共有状態。ホスト専用。
## CPU 鬼はここへ「自分の担当」を問い合わせるだけで、互いを直接見に行かない
var squad := HunterSquad.new()


func _ready() -> void:
	# 子ノードの name を明示することで、全ピアで同一の NodePath
	# (/root/GameManager/SightSystem 等)になることを保証する
	_sight.name = "SightSystem"
	add_child(_sight)
	_sight.spotted_changed.connect(func(is_spotted: bool): spotted_changed.emit(is_spotted))
	_version_gate.name = "VersionGate"
	add_child(_version_gate)
	_host_migration.name = "HostMigration"
	add_child(_host_migration)
	# ロビー中にプロフィール設定（④コスチューム変更等）が変わったら、繋がっている
	# 相手にも即座に反映する
	ProfileManager.profile_updated.connect(_on_profile_updated)


func _on_profile_updated() -> void:
	if NetworkManager.mode != NetworkManager.Mode.NONE and multiplayer.has_multiplayer_peer():
		broadcast_my_profile()


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
	tagger_peer_id = -1
	peer_notice = ""
	_peer_notice_left = 0.0
	_version_gate._awaiting_version.clear()
	round_is_ranked = false
	round_hunter_count = 0
	lobby_overlay_open = false
	peer_profiles.clear()
	tier_lock_enabled = false
	_clear_intel()


func _clear_intel() -> void:
	_sight._clear_intel()


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
	# ②EOSロビー経由(見知らぬ相手とのレーティング戦)では公平性のため鬼を必ずランダムに
	# 選ぶ。DirectConnect(フレンドのみのプライベート対戦)は従来通り立候補を優先する
	var is_eos_matched := NetworkManager.matched_via_eos_lobby
	if solo_debug_runner:
		new_runner = CPU_RUNNER_ID
	elif solo:
		new_runner = ids[0]
	elif is_eos_matched:
		new_runner = ids.pick_random()
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
	_start_round.rpc(new_runner, mult, total_hunters, spawns, is_eos_matched)
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
	_sight._update_sight(delta)
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
## 実装は autoload/game/sight_system.gd(子ノード _sight)に集約。GameManager は
## 呼び出し側(cpu_hunter.gd / hud.gd / player.gd 等)の呼び出し規約を変えないための
## 薄い委譲のみ持つ

func can_see(hunter: Node3D, target: Node3D) -> bool:
	return _sight.can_see(hunter, target)


## CPU が「自分は見えているか」を問い合わせる窓口。
func hunter_sees_runner(h: Node) -> bool:
	return _sight.hunter_sees_runner(h)


## tests/test_phase1_rules.gd 等が RPC 経由ではなく直接呼んでいるため、
## 呼び出し規約を変えない薄い委譲として残す(実際の@rpcは_sight側にある)
func _set_intel(zone: int, left: float, live: bool) -> void:
	_sight._set_intel(zone, left, live)


func _sync_intel(left: float) -> void:
	_sight._sync_intel(left)


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
	var hunter_node: Node3D = b if a == runner else a
	var tagger_id := -1
	if hunter_node.is_in_group("players"):
		tagger_id = String(hunter_node.name).to_int()
	_end_round.rpc(false, EndReason.TAGGED, tagger_id)


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
	if multiplayer.is_server() and not _version_gate._awaiting_version.is_empty():
		_version_gate._tick_version_checks(delta)
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


## ホストのみ。接続直後に版数を送り、返事が来るまで見張る。実装は
## autoload/game/version_gate.gd(子ノード _version_gate)に集約
## (PROTOCOL_VERSION定数のみ、単一の定数を分裂させないためGameManagerに残す)
func begin_version_check(peer_id: int) -> void:
	_version_gate.begin_version_check(peer_id)


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


## ②④ 自分のレート/ティア/コスチュームを相手に知らせる。
## ホストは全ピアへ即座に配信、参加者はホストへ報告する（ホストが集約して配り直す）
func broadcast_my_profile() -> void:
	var payload := _my_profile_payload()
	if multiplayer.is_server():
		peer_profiles[1] = payload
		_sync_profiles.rpc(peer_profiles)
	else:
		report_profile.rpc_id(1, payload)


func _my_profile_payload() -> Dictionary:
	return {
		"name": ProfileManager.player_name,
		"rating": ProfileManager.rating,
		"tier": String(RankingManager.tier_id(ProfileManager.rating)),
		"costume": String(ProfileManager.costume_id),
		"colors": ProfileManager.colors_to_html(ProfileManager.costume_colors),
		"hat": String(ProfileManager.hat_id),
		# ⑦切断時のCPU代行(レーティング戦のみ)で、本人不在のまま敗北精算を
		# サーバー側に記録するのに必要。EOS無効時は空文字(その場合はround_is_ranked
		# 自体が発生しないケースが大半だが、念のため空でも安全に無視されるようにする)
		"puid": EosManager.product_user_id,
	}


## 参加者 -> ホスト
@rpc("any_peer", "reliable")
func report_profile(payload: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	# ②「同じレート帯のみ参加可」ロビーでは、ティアが一致しない参加者を切る。
	# payload の "tier" 文字列はクライアントの自己申告なので信用せず、同じ payload に
	# 含まれる "rating" からホスト側で改めてティアを算出する（is_rating_compatible と
	# 判定基準を共有し、レートは自己申告のままでもティア詐称だけは防ぐ）
	if tier_lock_enabled and id != 1:
		var peer_rating := int(payload.get("rating", 1500))
		if not RankingManager.is_rating_compatible(ProfileManager.rating, peer_rating, 0):
			notify_host("レート帯が違う参加者の接続を許可しませんでした（このロビーは同じレート帯のみ）。")
			# ⑤disconnect_peer()の前に理由を伝える。何も伝えずに切ると、EOSロビー経由の
			# 参加者側は_on_server_disconnected()がただの拒否をホストロスト扱いしてしまい、
			# 実際には存在しないホストマイグレーション探索UIが誤って出る
			notify_rejected.rpc_id(id, "このロビーは同じレート帯のみ参加できます（レート帯が一致しません）。")
			multiplayer.multiplayer_peer.disconnect_peer(id)
			return
	peer_profiles[id] = payload
	_sync_profiles.rpc(peer_profiles)


## ホスト -> 拒否した参加者。disconnect_peer()より前に呼ぶことで、切断理由を本人にも伝える。
## 受け取った参加者は自発的にleave()し、_on_server_disconnected()のホストマイグレーション
## 判定(_should_attempt_migration())を経由させない
## (autoload/game/version_gate.gdのcheck_versionと同じ狙い・同じパターン)
@rpc("authority", "reliable")
func notify_rejected(reason: String) -> void:
	NetworkManager.last_error = reason
	NetworkManager.leave()


## ホスト -> 全ピア
@rpc("authority", "call_local", "reliable")
func _sync_profiles(all: Dictionary) -> void:
	peer_profiles = all
	profiles_changed.emit()


## ⑦対戦中に切断した逃げる役をレーティング戦でだけCPU代行に切り替えるかどうか。
## world.gd._on_peer_disconnected()がノードを実際に破棄する前に判定するために公開している。
## 実装は autoload/game/host_migration.gd(子ノード _host_migration)に集約
func should_cpu_takeover_runner(peer_id: int) -> bool:
	return _host_migration.should_cpu_takeover_runner(peer_id)


## バージョン確認・役割(wanted_runner)・プロフィール・汎用RPCと横断的に絡む
## オーケストレータのため、無理に子ノードへは切り出さずここに残す
func on_player_left(peer_id: int, cpu_took_over: bool = false) -> void:
	if not multiplayer.is_server():
		return
	# ⑦⑧敗北精算の報告はプロフィール消去より前に行う(puidが必要なため)。
	# 逃走者のCPU代行(cpu_took_over)に加え、対戦中に切断した鬼役にも同様にペナルティを課す
	# (通信切断による不正な勝敗回避を防ぐため。鬼が抜けても試合継続に支障はないので
	# CPU代行等の救済措置は不要で、ペナルティ記録のみ行う)
	if cpu_took_over:
		_host_migration._report_participant_disconnect_penalty(peer_id, true)
	elif round_is_ranked and state == State.PLAYING and peer_id != runner_id:
		_host_migration._report_participant_disconnect_penalty(peer_id, false)
	_version_gate._awaiting_version.erase(peer_id)
	if peer_profiles.has(peer_id):
		peer_profiles.erase(peer_id)
		_sync_profiles.rpc(peer_profiles)
	# 抜けた人が指名されたままだと、次のラウンドで誰も逃走者にならない
	if wanted_runner == peer_id:
		_set_wanted_runner.rpc(-1)
	if cpu_took_over:
		_host_migration._set_runner_cpu.rpc()
	elif state == State.PLAYING and peer_id == runner_id:
		_end_round.rpc(false, EndReason.RUNNER_LEFT)


## ⑨ホスト(peer_id==1)自身がPLAYING中に切断した場合の敗北精算に使うスナップショットを取る。
## 実装は autoload/game/host_migration.gd(子ノード _host_migration)に集約
func snapshot_for_host_disconnect_penalty() -> Dictionary:
	return _host_migration.snapshot_for_host_disconnect_penalty()


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
func _start_round(new_runner: int, mult: float, hunters_n: int, spawns: Dictionary, is_eos_matched: bool) -> void:
	runner_id = new_runner
	hunter_mult = mult
	hunter_count = hunters_n
	squad.begin_round()  # 前ラウンドの担当を持ち越さない（ホスト以外では空回り）
	time_left = ROUND_TIME
	head_start_left = HEAD_START
	tagger_peer_id = -1
	state = State.PLAYING
	# ①レートは人間の対戦相手が2人以上、かつ②EOSロビー経由(見知らぬ相手との
	# レーティング戦)のときだけ。is_eos_matchedはホストが一度だけ判定してRPC引数として
	# 配る(NetworkManager.matched_via_eos_lobbyは接続方法によりピアごとに違いうるため、
	# 各ピアが別々にローカル判定すると不整合になりうる。詳細はPROTOCOL_VERSIONの説明参照)
	var humans := player_ids().size()
	round_is_ranked = humans >= 2 and is_eos_matched
	round_hunter_count = hunters_n
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
func _end_round(runner_won: bool, reason: int, tagger_id: int = -1) -> void:
	state = State.RESULT
	head_start_left = 0.0
	result_runner_won = runner_won
	result_reason = reason
	tagger_peer_id = tagger_id
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
	tagger_peer_id = -1
	head_start_left = 0.0
	result_left = 0.0
	round_is_ranked = false
	round_hunter_count = 0
	_clear_intel()
	squad.begin_round()
	state_changed.emit(state)
	if multiplayer.is_server():
		_clear_cpu_characters()


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
