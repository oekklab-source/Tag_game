extends Node

## GameManager の子ノード。視界(索敵)の判定と共有状態を持つ。
## GameManager.PROTOCOL_VERSION の「RPCのノードパスを変えたら上げる」鉄則により、
## ここに定義した @rpc メソッドは GameManager 本体とは別のノードパスへ配信される
## (v6でのGameManager分割時に切り出した。詳細はgame_manager.gdのバージョン履歴参照)。
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
## 視認が途切れてから spotted を落とすまでの猶予。これが無いと逃走者が柱の陰を
## 横切るだけで 20Hz でばたつき、RPC を撒き散らしバナーも点滅する
const SPOTTED_HOLD := 2.5

## 「今 誰かに見られている」の変化。HUD のバナーはエッジで駆動する
signal spotted_changed(is_spotted: bool)

## 索敵の共有状態（全ピアが持つ）
var spotted := false      # 今この瞬間、誰かが視認している
var spotted_zone := -1    # 最後に目撃されたゾーン。-1 = 情報なし
var intel_left := 0.0

var _sight_timer := 0.0
var _seer_ids := {}       # ホスト専用。視認中の鬼の instance_id
var _no_sight_for := 0.0


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
	var runner := GameManager.get_runner()
	if runner == null:
		return
	_sight_timer -= delta
	if _sight_timer <= 0.0:
		_sight_timer = SIGHT_TICK
		# 鬼を tick 間で分散させない。一括評価の方が spotted_zone が一貫する
		_seer_ids.clear()
		for h in GameManager.hunters():
			if can_see(h, runner):
				_seer_ids[h.get_instance_id()] = true

	# 新しい値はローカルに組み立て、代入と signal は必ず _set_intel に通す。
	# ここで直接 spotted を書き換えると、call_local の _set_intel が
	# 「変化なし」と判断してホスト側だけ spotted_changed が飛ばなくなる
	var new_zone := spotted_zone
	var new_intel := intel_left
	var new_live := spotted
	if not _seer_ids.is_empty():
		new_zone = GameManager.zone_at(runner.global_position)
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
