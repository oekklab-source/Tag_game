class_name HunterSquad
extends RefCounted

## 鬼（CPU + 人間）の連携を一元管理する。ホスト（サーバ）専用。
##
## CPU に互いを直接参照させると「誰が何を担当しているか」が個体ごとにばらつき、
## 同じゾーンへ重なって進む・全員が同じ側から追う といった動きになる。
## 共有の割り当てをここへ集約し、各 CPU は「自分の担当」を問い合わせるだけにする。
##
##   探索: 長く見ていないゾーンを1体に1つずつ排他で配る -> 全体に広がって探す
##   通報: いちばん近い1体が現地へ、残りは隣のゾーン（逃げ道）を塞ぐ
##   包囲: 逃走者の逃走方向を基準に持ち場の角度を配る   -> 挟み込む
##
## 人間の鬼に目標は強制できないが、位置は数に入れる。人間が立っているゾーンは
## 探索済みになり、人間が塞いでいる側は CPU の持ち場から外れるので、
## 結果として人間も含めた全員が連動する。
##
## 辞書のキーはすべて Object.get_instance_id()。ノードを保持しないので、
## 途中で消えた鬼の担当は tick() の掃除で落ちるだけで済む。

## --- 探索の分担 ---------------------------------------------------------
## 「最後にそのゾーンへ鬼が居てから何秒経ったか」に比例して行きたくなる。
## 距離とのつり合いで決めるので、係数は「1秒の古さ = 何メートル分の価値か」の意味
const HEAT_PER_METER := 2.5
## 割り当てたゾーンへ着けないまま這っている場合の見切り。
## ナビが繋がらない場所を掴んだ鬼が永久に無駄足を踏むのを防ぐ
const CLAIM_TIMEOUT := 22.0

## --- 包囲の分担 ---------------------------------------------------------
## 逃走者の逃走方向を 0° として、追跡役以外へ配る持ち場の角度。
## 先頭の ±45° が「正面をふさぐ2枚」で、鬼3体なら 追う1 + 挟む2 になる
const PINCER_ANGLES: Array[float] = [45.0, -45.0, 20.0, -20.0, 90.0, -90.0]
## 持ち場は逃走者からこの距離に置く。鬼が遠いほど大きく回り込み、
## 近づいたら締める（遠いうちから真横へ流れると永久に追いつけない）
const PINCER_MIN := 4.0
const PINCER_MAX := 14.0
const PINCER_SPREAD := 0.55
## 持ち場が歩けない場所だった時に、方角を保ったまま逃走者へ寄せていく倍率。
## 縮めるほど逃走者に近づくので、最後は必ずどこかで歩ける床に当たる
const PINCER_SHRINK: Array[float] = [1.0, 0.6, 0.35, 0.15]
## 吸着でこれ以上ずらされたら「その持ち場は使えない」と見なして次を試す
const PINCER_SNAP_TOLERANCE := 2.5
## 逃走者の何秒先を読んで持ち場を置くか。
## 大きすぎると曲がられた瞬間に全員が明後日の方向へ流れる
const LEAD_TIME := 1.4
## 割り当ては毎フレーム組み直すと鬼が左右に震える。この間隔でだけ組み直す
const REASSIGN_INTERVAL := 0.5
## 逃走者の速度は位置の差分から推定する。リモートのプレイヤーはサーバ上で
## _physics_process を回さないため、ノードの velocity は 0 のまま当てにならない
const VEL_SMOOTH := 6.0
## ワープ・滑り台の瞬間移動を「猛烈な速度」として拾わないための足切り（m/frame）
const VEL_JUMP_CUT := 4.0

## --- 見失った後の予測 ---------------------------------------------------
## 通報が切れた瞬間に盲目の巡回へ戻ると、逃走者は「一度撒けば安全」になる。
## 最後の目撃地点を進行方向へ流しながら「この辺にいるはず」を持ち続け、
## 逃げた先のゾーンを優先的に配ることで先回りの網になる
const PREDICT_TIME := 45.0
## 逃走者の持続平均速度（約8.65 m/s）にほぼ一致させ、予測中心が
## 逃走者と同じ速さで流れるようにする（＝先読みが実際の逃走から遅れない）
const PREDICT_DRIFT := 8.5     # 予測中心が進行方向へ流れる速さ m/s
## 半径はゾーン間隔(53.5m)より少し大きく取る。ここを間隔より小さくすると
## 予測ゾーン以外に一切ボーナスが乗らず、「隣も怪しい」を表現できない
const PREDICT_RADIUS := 55.0
const PREDICT_GROWTH := 4.0    # 半径の広がり m/s。時間が経つほど確信が薄れ広く散る
## スコアはメートル換算。隣のゾーンへ動く距離ペナルティ(53.5m)を明確に
## 上回るようにする。参考: HEAT_PER_METER 2.5 なので 20秒の古さ ≒ 50m 相当
const PREDICT_WEIGHT := 95.0

var _zone_heat := PackedFloat32Array()
var _zone_owner := {}   # zone -> instance_id
var _claim := {}        # instance_id -> {"zone": int, "left": float}
var _slot := {}         # instance_id -> 持ち場の角度(rad)。追跡役は 0
var _watch := {}        # instance_id -> 通報時に張り込むゾーン
var _prime_id := 0
var _reassign_left := 0.0
var _runner_vel := Vector3.ZERO
var _runner_prev := Vector3.ZERO
var _has_prev := false
var _belief_center := Vector3.ZERO
var _belief_dir := Vector3.ZERO
var _belief_left := 0.0


func _init() -> void:
	begin_round()


## ラウンドの区切りで呼ぶ。前のラウンドの担当を持ち越さない
func begin_round() -> void:
	_zone_heat.resize(WorldData.ZONE_COUNT)
	_zone_heat.fill(0.0)
	_zone_owner.clear()
	_claim.clear()
	_slot.clear()
	_watch.clear()
	_prime_id = 0
	_reassign_left = 0.0
	_runner_vel = Vector3.ZERO
	_has_prev = false
	_belief_left = 0.0


## ホストが毎物理フレーム呼ぶ。hunters には人間の鬼と CPU 鬼の両方を渡すこと
func tick(delta: float, hunters: Array[Node3D], runner: Node3D, reported_zone: int) -> void:
	if delta <= 0.0:
		return
	var live := {}
	for h in hunters:
		live[h.get_instance_id()] = true
	_forget_missing(live)

	for z in WorldData.ZONE_COUNT:
		_zone_heat[z] += delta
	# 鬼が立っているゾーンは「今 見た」ことにする。人間の鬼の分も消えるので、
	# CPU は人間が歩いた側を避けて反対側から探し始める
	for h in hunters:
		_zone_heat[WorldData.zone_index(h.global_position)] = 0.0

	for id in _claim:
		_claim[id]["left"] -= delta

	_track_runner(delta, runner)
	_update_belief(delta, runner, reported_zone)
	_reassign_left -= delta
	if _reassign_left <= 0.0:
		_reassign_left = REASSIGN_INTERVAL
		_assign_slots(hunters, runner)
		_assign_watch(hunters, reported_zone)


## --- 問い合わせ（CPU 側から呼ぶ） ---------------------------------------

## 自分が「追跡役」か。追跡役だけは回り込まずに逃走者へまっすぐ向かう
func is_prime(h: Node) -> bool:
	return _prime_id == h.get_instance_id()


## 追う先。追跡役は逃走者の少し先、それ以外は逃走方向を塞ぐ持ち場
func pincer_goal(h: Node3D, runner: Node3D) -> Vector3:
	var r := runner.global_position
	var lead := _runner_vel * LEAD_TIME
	var id := h.get_instance_id()
	if id == _prime_id or not _slot.has(id):
		return r + lead
	var radius := clampf(_flat(h.global_position - r) * PINCER_SPREAD, PINCER_MIN, PINCER_MAX)
	var a: float = _slot[id]
	var side := Vector3(cos(a), 0.0, sin(a))
	var base := r + lead
	# 持ち場は幾何で決めるので壁の中や崖下を指すことがある。そのまま渡すと
	# NavigationAgent3D が「一番近いポリゴン」へ経路を引き、壁の反対側へ
	# 回り込むといった破綻を起こす。
	#
	# ただし無条件に吸着させると、押し出された先が反対の挟み役と同じ側になり
	# 挟み込みそのものが潰れる。担当の方角は保ったまま逃走者へ近づける形で
	# 半径を縮め、歩ける場所が見つかった時点で採用する
	var world := h.get_world_3d()
	if world == null:
		return base + side * radius
	var last := base + side * radius
	for scale in PINCER_SHRINK:
		var raw := base + side * (radius * scale)
		var fit := NavigationServer3D.map_get_closest_point(world.navigation_map, raw)
		# ナビマップが空（ベイク前）だと原点が返る。その時は素の値を使う
		if fit == Vector3.ZERO and raw.length_squared() > 1.0:
			return raw
		if _flat(fit - raw) <= PINCER_SNAP_TOLERANCE:
			return fit
		last = fit
	return last


## 通報を受けた時の行き先ゾーン。割り当てが無ければ通報ゾーンそのもの
func watch_zone(h: Node, fallback: int) -> int:
	return _watch.get(h.get_instance_id(), fallback)


## 探索の担当ゾーン。持っていなければその場で配る。
## 他の鬼が持っているゾーンは選ばれないので、担当が自然に散る
func search_zone(h: Node3D) -> int:
	var id := h.get_instance_id()
	if _claim.has(id) and _claim[id]["left"] > 0.0:
		return _claim[id]["zone"]
	return _take_zone(h, -1)


## 掃き終わったので次を貰う。直前のゾーンは選び直さない
func next_search_zone(h: Node3D) -> int:
	var id := h.get_instance_id()
	var avoid := -1
	if _claim.has(id):
		avoid = _claim[id]["zone"]
	return _take_zone(h, avoid)


## --- 内部 ---------------------------------------------------------------

func _take_zone(h: Node3D, avoid: int) -> int:
	var id := h.get_instance_id()
	_release(id)
	var pos := h.global_position
	var best := -1
	var best_score := -INF
	for z in WorldData.ZONE_COUNT:
		if z == avoid or (_zone_owner.has(z) and _zone_owner[z] != id):
			continue
		# 古いゾーンほど行く価値が高く、遠いゾーンほど下がる。
		# 「逃げた先」の予測が乗っているゾーンはさらに強く引く
		var score := _zone_heat[z] * HEAT_PER_METER 			- _flat(WorldData.zone_center(z) - pos) 			+ _belief_score(z)
		if score > best_score:
			best_score = score
			best = z
	if best < 0:
		best = WorldData.zone_index(pos)  # 鬼がゾーン数を超えた時の逃げ道
	_zone_owner[best] = id
	_claim[id] = {"zone": best, "left": CLAIM_TIMEOUT}
	return best


func _release(id: int) -> void:
	if not _claim.has(id):
		return
	var zone: int = _claim[id]["zone"]
	if _zone_owner.get(zone, 0) == id:
		_zone_owner.erase(zone)
	_claim.erase(id)


func _forget_missing(live: Dictionary) -> void:
	for id in _claim.keys():
		if not live.has(id):
			_release(id)
	for id in _slot.keys():
		if not live.has(id):
			_slot.erase(id)


func _track_runner(delta: float, runner: Node3D) -> void:
	if runner == null:
		_has_prev = false
		_runner_vel = Vector3.ZERO
		return
	var pos := runner.global_position
	if not _has_prev:
		_runner_prev = pos
		_has_prev = true
		return
	var step := pos - _runner_prev
	_runner_prev = pos
	if step.length() > VEL_JUMP_CUT:
		return  # ワープ・落下復帰。速度として拾うと持ち場が飛ぶ
	_runner_vel = _runner_vel.lerp(step / delta, 1.0 - exp(-delta * VEL_SMOOTH))
	_runner_vel.y = 0.0


## 「見失った後、どこにいるはずか」を持ち続ける。
##
## 視認中は予測を張り直し続け、切れた瞬間の位置と向きを種にする。
## 以後は中心を進行方向へ流し、半径を広げて確信を薄めていく。
## これが無いと通報が切れた瞬間に盲目の巡回へ戻り、「一度撒けば安全」になる
func _update_belief(delta: float, runner: Node3D, reported_zone: int) -> void:
	if runner == null:
		_belief_left = 0.0
		return
	if reported_zone >= 0:
		# 今まさに情報がある間は予測を最新に保つ。切れた瞬間これが種になる
		_belief_center = runner.global_position
		_belief_dir = _runner_vel.normalized() if _runner_vel.length() > 1.0 else Vector3.ZERO
		_belief_left = PREDICT_TIME
		return
	if _belief_left <= 0.0:
		return
	_belief_left = maxf(_belief_left - delta, 0.0)
	_belief_center += _belief_dir * PREDICT_DRIFT * delta


## 予測がそのゾーンにどれだけ乗っているか（メートル換算のボーナス）。
## 時間で薄れ、半径が広がるほど1ゾーンあたりの寄与も薄くなる
func _belief_score(zone: int) -> float:
	if _belief_left <= 0.0:
		return 0.0
	var age := PREDICT_TIME - _belief_left
	var radius := PREDICT_RADIUS + PREDICT_GROWTH * age
	# 予測円の中心に近いゾーンほど強く、円の外はゼロ
	var d := _flat(WorldData.zone_center(zone) - _belief_center)
	var near := clampf(1.0 - d / radius, 0.0, 1.0)
	return PREDICT_WEIGHT * near * (_belief_left / PREDICT_TIME)


## 逃走者にいちばん近い1体を「追跡役」、残りを逃走方向の左右の持ち場へ配る。
## 持ち場は「今いる方角にいちばん近いもの」から埋めるので、
## 組み直しても鬼同士が交差せず、進路が左右に振れない
func _assign_slots(hunters: Array[Node3D], runner: Node3D) -> void:
	_slot.clear()
	_prime_id = 0
	if runner == null or hunters.is_empty():
		return
	var r := runner.global_position
	var order: Array[Node3D] = hunters.duplicate()
	order.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return _flat(a.global_position - r) < _flat(b.global_position - r))
	_prime_id = order[0].get_instance_id()
	_slot[_prime_id] = 0.0

	# 逃走方向。止まっている時は「追跡役から見て逃走者の向こう側」をこれから
	# 逃げる先とみなす。こうすると挟む2体は必ず追跡役の反対側へ回り込む
	var flee := Vector2(_runner_vel.x, _runner_vel.z)
	if flee.length() < 1.5:
		var away := r - order[0].global_position
		flee = Vector2(away.x, away.z)
	if flee.length_squared() < 1e-6:
		flee = Vector2.RIGHT
	var base := flee.angle()

	var free: Array[float] = []
	for i in mini(order.size() - 1, PINCER_ANGLES.size()):
		free.append(base + deg_to_rad(PINCER_ANGLES[i]))
	for i in range(1, order.size()):
		var id: int = order[i].get_instance_id()
		if free.is_empty():
			_slot[id] = base
			continue
		var d := order[i].global_position - r
		var here := atan2(d.z, d.x)
		var best := 0
		for k in free.size():
			if absf(angle_difference(free[k], here)) < absf(angle_difference(free[best], here)):
				best = k
		_slot[id] = free[best]
		free.remove_at(best)


## 通報ゾーンの張り込み。いちばん近い1体が現地へ入り、
## 残りは隣接ゾーン（＝逃げ出す先）を1つずつ塞ぐ
func _assign_watch(hunters: Array[Node3D], zone: int) -> void:
	_watch.clear()
	if zone < 0 or hunters.is_empty():
		return
	var c := WorldData.zone_center(zone)
	var order: Array[Node3D] = hunters.duplicate()
	order.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return _flat(a.global_position - c) < _flat(b.global_position - c))
	_watch[order[0].get_instance_id()] = zone
	var exits := WorldData.zone_neighbors(zone)
	for i in range(1, order.size()):
		var id: int = order[i].get_instance_id()
		if exits.is_empty():
			_watch[id] = zone
			continue
		# 自分がいちばん早く着ける出口から埋める
		var p := order[i].global_position
		var best := 0
		for k in exits.size():
			if _flat(WorldData.zone_center(exits[k]) - p) \
					< _flat(WorldData.zone_center(exits[best]) - p):
				best = k
		_watch[id] = exits[best]
		exits.remove_at(best)


static func _flat(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()
