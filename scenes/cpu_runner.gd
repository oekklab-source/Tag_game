extends CharacterBody3D

const CPU_NAV_ASSIST := preload("res://scenes/cpu_nav_assist.gd")
const STUCK_ESCAPE := preload("res://scenes/stuck_escape.gd")

## CPU の逃走者（デバッグ用ソロ: 人間が鬼、CPU が逃げる）。
## ホスト上だけでAIを動かし、位置・回転は MultiplayerSynchronizer が配信する。
##
## cpu_hunter.gd と対になる設計にしてある。鬼が「見つける・読む・詰める」で強いのに対し、
## 逃走者は「どこへ逃げるか・いつ吐くか・角に詰まらないか」の判断だけで強い。
##
## --- 使ってよい情報（人間の逃走者の画面と同じもの） ---------------------
## 鬼 AI が「人間の鬼と同じ情報しか持たない」のと対称に、こちらも人間の逃走者の
## HUD にある情報だけで動く。逃走者の HUD は元々**鬼に対して全知**である:
##   ミニマップ … 鬼が全員映る（hud.gd の _on_map_draw）-> 全鬼の位置を知ってよい
##   赤矢印と距離 … 最寄りの鬼への方向と距離
##   バナー/ヴィネット … GameManager.spotted（見られているか）
## 逆に**使ってはいけない**のは、鬼の視線方向・鬼の目的地・GameManager.squad の割り当て。
## いずれも人間の逃走者の画面には出ていない。
##
## 脚は人間の逃走者とまったく同じにする（SPEED / DASH / スタミナ経済すべて
## player.gd の定数を参照）。鬼側の「脚は逃走者と同一」と対称に保つため。

## --- 脚（すべて player.gd と同一） --------------------------------------
const SPEED := Player.BASE_SPEED
const DASH_SPEED := Player.BASE_SPEED * Player.DASH_MULT
const STAMINA_MAX := Player.STAMINA_MAX
const STAMINA_DRAIN := Player.STAMINA_DRAIN
const STAMINA_REGEN := Player.STAMINA_REGEN
const STAMINA_RECOVER := Player.STAMINA_RECOVER

## --- 脅威の段階 ---------------------------------------------------------
## 最寄りの鬼までの距離で3状態に分ける。鬼の Mind（PATROL/INVESTIGATE/CHASE）と対
enum Mind { ROAM, EVADE, PANIC }

## これより近い鬼がいるか、見られていたら EVADE。ゾーン間隔(53.5m)より少し短く取り、
## 「隣のゾーンに入られたら動き出す」感覚にする
const THREAT_FAR := 45.0
## ここまで詰められたら PANIC。ダイブ(3〜9m)を撃たれる間合いの一歩外
const PANIC_DIST := 12.0

## --- スタミナの配分 -----------------------------------------------------
## ここが逃走側の強さの本体その1。「見えているから全力」ではなく
## 「今吐かないと詰められるか」で決める
const DASH_ENGAGE := 28.0      # これより近い鬼が詰めてきていたら吐く
const DASH_SPOTTED := 40.0     # 見られている間は、この距離までなら吐く
## 鬼が DASH_RESERVE_DIST より遠いうちは、スタミナがこれを下回ったら吐くのをやめる。
## **最後の 35 は「詰められた時」のために必ず残す**。枯渇して巡航速度に落ちた瞬間に
## 追いつかれるのが逃走者の最大の負け筋で、鬼の DASH_ENGAGE(34m) はそこを狙っている
const DASH_RESERVE := 35.0
const DASH_RESERVE_DIST := 20.0
## 最寄りの鬼が近づいているか。ミニマップのドットの動きから読める以上の情報は使わない
const CLOSING_SMOOTH := 4.0

## --- 行き先のスコア（すべてメートル換算） --------------------------------
## ここが逃走側の強さの本体その2。候補点を「9ゾーン x 5点」に散らして採点する
const CAND_OFFSET := 17.0      # ゾーン中心からずらす幅（ゾーン半径 26.5 の内側）
## 2番目に近い鬼までの距離も見る。これが無いと「1体から遠い＝他2体の間」を選んで
## 挟み込みへ自分から入っていく
const SPREAD_WEIGHT := 0.5
## 行き先までの旅費。脚が鬼と同一なので、**この重みが 1.0 のとき
## 「near - travel」はそのまま「自分と鬼のどちらが先にそこへ着くか」**になる。
## ここを小さくすると「遠くて安全に見える点」を選び、鬼の方が先に着く場所へ
## わざわざ走っていく（マップの反対の隅へ突っ込んで捕まった）
const TRAVEL_WEIGHT := 1.0
## 自分から行き先までの線分の近くに鬼がいたら、その分だけ減点する。
## **鬼の前を横切らないための項**。これが無いと「一番遠い＝鬼の向こう側」を選んで
## 自分から突っ込む
const CROSS_PENALTY := 120.0
const CROSS_RADIUS := 18.0
## 減点を測り始める位置（線分の何割から先か）。真後ろに張り付かれている鬼まで
## 「進路上」と数えると、どの候補にも同じ減点が乗ってスコア差が消えるうえ、
## 見直しが毎回発火して行き先が定まらなくなる。**評価するのはこれから進む先だけ**
const CROSS_FROM := 0.2
## 外周壁までの余裕がこれを下回ったら、足りない分だけ減点する。
## **外周の角に自分を追い込まないための項**。上の2つだけだと「鬼から最も遠い＝
## マップの角」に必ず収束して詰む。
## 逃げ道の広さを**加点**にしてはいけない。それだとマップ中央が常に最高得点になり、
## 中央から離れられずにその場で包囲される。あくまで「狭い所を避ける」減点にする
const CORNER_MARGIN := 30.0
const CORNER_WEIGHT := 3.0
## 今の行き先を続けたい分の下駄。見直しは 0.4 秒ごとに回るので、これが無いと
## 僅差の候補の間で行き先が入れ替わり続けて左右に震える。
## 逆に大きすぎると状況が変わっても切り替えられず、鬼の待つ側へ走り込む
const STICKY_BONUS := 25.0
## これより近い候補は選ばない。短い行き先を選ぶと到着 -> 選び直しを繰り返して
## 同じ場所に留まってしまう。**逃げる時は必ず遠くへ向かう**
const MIN_TRAVEL := 30.0

const ARRIVE_DIST := 8.0
const GOAL_TIMEOUT := 10.0
## 行き先へ実際に近づけているかの見張り。
## 壁の角やスロープの側面に押し付けられていると「動いてはいるが目的地には
## まったく近づいていない」状態になり、_avoid_stuck の「その場から動いていない」
## 判定には引っかからない（横に滑り続けるため）。近づけていない行き先は
## **ナビ上つながっていても実際には入れない**とみなして諦め、しばらく避ける。
## これが無いと、入れないスロープの側面を押し続けたまま鬼に追いつかれる
const PROGRESS_TIME := 1.2
const PROGRESS_DIST := 2.0
const GIVEUP_TIME := 8.0
const GIVEUP_RADIUS := 22.0
const GIVEUP_PENALTY := 200.0
## 行き先を見直す間隔（hunter_squad の REASSIGN_INTERVAL と同じ考え方）。
## 毎フレーム組み直すと NavigationAgent3D の経路が落ち着かずその場で震えるが、
## 見直さないと**選んだ時点の状況のまま**走り続け、後から回り込まれた側へ
## そのまま突っ込む（実際に鬼2体が張っている隅へ走り込んで捕まった）
const REPICK_INTERVAL := 0.4
## 全鬼の位置を取り直す間隔。squad.tick が毎フレーム同じ集合を作っているので
## こちらは間引く（判断の粒度としては十分細かい）
const HUNTER_CACHE := 0.1

## --- アイテム -----------------------------------------------------------
## 置き物は「自分の背後」に出る（player.gd の BANANA_BEHIND / BLOCK_BEHIND）。
## 逃走者にとってはそこが**追ってくる鬼の進路**そのものなので、鬼側の
## 「先回りできている時だけ」より条件が素直になる
const ITEM_BEHIND_DOT := -0.3   # 鬼がこれより後ろにいれば置く価値がある
const BANANA_RANGE := 12.0
const BLOCK_RANGE_MIN := 8.0
const BLOCK_RANGE_MAX := 18.0
## ロケットは正面へ飛ぶので、正面が退路になっている時だけ使う
const ROCKET_ESCAPE := 18.0     # 最寄りの鬼がこの距離まで来たら一気に離す
const ROCKET_AHEAD_DOT := 0.5   # 正面この角度内に鬼がいたら撃たない（突っ込むだけ）
const ROCKET_AHEAD_RANGE := 25.0

## ダイブは使わない。DIVE_SPEED(12) は DASH_SPEED(10.5) より速いが、踏み切ると
## 操作不能になり着地後 DIVE_RECOVER(0.55s) の起き上がりが付く。背後3mの鬼に対しては
## 差し引きで必ず負けるので、逃走側の手にはしない（鬼だけが持つ「詰める技」のまま）

const SIDESTEP_TIME := 1.0
const SIDESTEP_DIST := 5.0
const AIR_STEER := 6.0
const REPATH_INTERVAL := 0.3
## 経路上の次の点がこれより近くなったら、その点ではなく最終目標を直接向く。
## **ダッシュ1フレーム分の移動（10.5/60 = 0.18m）より十分大きく取ること。**
## 小さいと「近いので最終目標を向く -> 少し進んで経路点から離れる -> また経路点を
## 向く」を毎フレーム繰り返し、その場で前後に振動して1歩も進めなくなる
## （実際にこれでマップ中央に固まったまま鬼3体に囲まれた）
const WAYPOINT_SKIP := 1.0
const TURN_SPEED := 8.0
const RUNNER_COLOR := Player.COLOR_RUNNER
const GROUND_DRAG := Player.GROUND_DRAG
const STEER_WHILE_FAST := Player.STEER_WHILE_FAST
const SLIP_DRAG := Player.SLIP_DRAG
const SLIDE_STEER := Player.SLIDE_STEER
const SLIDE_MIN_SPEED := Player.SLIDE_MIN_SPEED
const SLIDE_SNAP := Player.SLIDE_SNAP
const SLIDE_GRACE := Player.SLIDE_GRACE
const WARP_GRACE := Player.WARP_GRACE
const NET_SMOOTH := Player.NET_SMOOTH
const NET_SNAP_DIST := Player.NET_SNAP_DIST

var buffs := BuffSet.new()
var carry_velocity := Vector3.ZERO
var bumper_bounce_velocity := Vector3.ZERO
var bumper_bounce_left := 0.0
var slide_dir := Vector3.ZERO
var slide_accel := 0.0
var slide_cap := 0.0
var slide_left := 0.0
var warp_lock := 0.0
var warp_grace := 0.0
var stun_left := 0.0
## 転んでいる最中か。見た目の Slip モーションに使うのでレプリケートする
## （stun_left はサーバしか持っていないので、そのままでは他ピアで棒立ちになる）
var stunned := false
var diving := false

var stamina := STAMINA_MAX
var exhausted := false
var is_dashing := false
## player.gd と同じ契約。CPU の権威はサーバなのでホスト上だけで進む
var item: int = Player.Item.NONE
var item_lock := 0.0

var _mind: int = Mind.ROAM
var _goal := Vector3.ZERO
var _goal_timer := 0.0
var _repath_timer := 0.0
var _repick_timer := 0.0
var _progress_timer := 0.0
var _progress_from := INF
var _giveup_at := Vector3.ZERO
var _giveup_left := 0.0
var _hunters: Array[Node3D] = []
var _hunter_timer := 0.0
var _threat_dist := INF     # 最寄りの鬼までの距離
var _threat_prev := INF
var _threat_id := 0         # 最寄りの鬼の instance_id（入れ替わりの検知用）
var _closing := 0.0         # >0 なら詰められている（m/s）
var _stuck_timer := 0.0
var _stuck_from := Vector3.ZERO
var _sidestep_left := 0.0
var _sidestep_goal := Vector3.ZERO
var _stuck_kick := Vector3.ZERO
var _stuck_kick_left := 0.0
var _rng := RandomNumberGenerator.new()

@export var sync_position := Vector3.ZERO
@export var sync_yaw := 0.0
@export var sync_speed := 0.0
@export var sync_air := false

@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var humanoid: Node3D = $Humanoid


func _ready() -> void:
	add_to_group("cpu_runners")
	humanoid.set_color(RUNNER_COLOR)
	if multiplayer.is_server():
		sync_position = position
		sync_yaw = rotation.y
		_goal = global_position
		_goal_timer = 0.0   # 最初の物理フレームで必ず選び直す
		_stuck_from = global_position
	else:
		position = sync_position
		rotation.y = sync_yaw
	$TagArea.body_entered.connect(_on_tag_area_body_entered)
	_rng.seed = hash(name)


func _on_tag_area_body_entered(body: Node3D) -> void:
	if multiplayer.is_server():
		GameManager.report_touch(self, body)


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	if not multiplayer.is_server():
		_follow_sync(delta)
	humanoid.set_diving(false)
	humanoid.set_stunned(stunned)
	humanoid.update_motion(sync_speed, not sync_air, delta)
	humanoid.rotation.x = lerpf(humanoid.rotation.x, 0.0, minf(delta * 12.0, 1.0))


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	buffs.tick(delta)
	warp_lock = maxf(warp_lock - delta, 0.0)
	stun_left = maxf(stun_left - delta, 0.0)
	var holding_bumper_bounce := bumper_bounce_left > 0.0
	bumper_bounce_left = maxf(bumper_bounce_left - delta, 0.0)
	item_lock = maxf(item_lock - delta, 0.0)
	# 終わるたび必ず false を挟むので、続けて2回転んでも ON_CHANGE の同期が発火する
	stunned = stun_left > 0.0

	var grounded := is_on_floor() and not CharacterSeparation.on_character(self)
	if warp_grace > 0.0 or not grounded:
		velocity += get_gravity() * delta

	var active := (GameManager.state == GameManager.State.PLAYING and stun_left <= 0.0)
	var dir := Vector3.ZERO
	var wants_dash := false
	if active:
		_update_hunters(delta)
		_update_mind()
		_update_goal(delta)
		var assist := CPU_NAV_ASSIST.slide_assist(global_position, _goal)
		if assist["active"]:
			_stuck_timer = 0.0
			_stuck_from = global_position
			_sidestep_left = 0.0
			_stuck_kick_left = 0.0
		else:
			_avoid_stuck(delta)
		if _stuck_kick_left > 0.0:
			add_carry(_stuck_kick)
			_stuck_kick_left -= delta
		var nav_goal: Vector3 = _sidestep_goal if _sidestep_left > 0.0 else assist["target"]
		_repath_timer -= delta
		if _repath_timer <= 0.0:
			_repath_timer = REPATH_INTERVAL
			agent.target_position = nav_goal
		var next: Vector3 = nav_goal if assist["direct"] else agent.get_next_path_position()
		if not assist["direct"] and _xz_dist(global_position, next) < WAYPOINT_SKIP \
				and _xz_dist(global_position, nav_goal) > WAYPOINT_SKIP:
			next = nav_goal
		dir = next - global_position
		dir.y = 0.0
		dir = dir.normalized() if dir.length() > 0.05 else Vector3.ZERO
		dir = CPU_NAV_ASSIST.avoid_bumpers(global_position, dir, get_tree())
		dir = CPU_NAV_ASSIST.boost_assist(global_position, dir, _goal)
		dir = _slide_along_walls(dir)
		# 安全なうちに手ぶらを解消しておく。追われ始めてからでは寄り道できない
		if _mind == Mind.ROAM and item == Player.Item.NONE:
			dir = CPU_NAV_ASSIST.item_assist(global_position, dir, _goal)
		wants_dash = _wants_dash()
		_try_use_item()

	_update_stamina(delta, wants_dash)

	var speed := (DASH_SPEED if is_dashing else SPEED) * buffs.get_mult(&"speed")
	var target := Vector2(dir.x, dir.z) * speed
	if holding_bumper_bounce:
		velocity.x = bumper_bounce_velocity.x
		velocity.z = bumper_bounce_velocity.z
	elif slide_left > 0.0:
		velocity = SlideMotion.step(velocity, delta, slide_dir, slide_accel, slide_cap,
			SLIDE_STEER, dir, SLIDE_MIN_SPEED)
		floor_snap_length = SLIDE_SNAP
		slide_left = maxf(slide_left - delta, 0.0)
		if slide_left <= 0.0:
			_repath_timer = 0.0
			_goal_timer = 0.0
	elif warp_grace > 0.0:
		warp_grace = maxf(warp_grace - delta, 0.0)
		if dir != Vector3.ZERO:
			velocity.x = move_toward(velocity.x, target.x, AIR_STEER * delta)
			velocity.z = move_toward(velocity.z, target.y, AIR_STEER * delta)
	elif stun_left > 0.0 and grounded:
		# 転倒中は目標速度がゼロなので、通常の接地処理だと即座に止まってしまう。
		# player.gd と同じく摩擦だけで落として、尻で滑る勢いを残す
		floor_snap_length = 0.1
		var slip := Vector2(velocity.x, velocity.z).move_toward(Vector2.ZERO, SLIP_DRAG * delta)
		velocity.x = slip.x
		velocity.z = slip.y
	elif grounded:
		floor_snap_length = 0.1
		var hv := Vector2(velocity.x, velocity.z)
		if hv.length() > speed + 0.5:
			var keep := hv.normalized() * maxf(hv.length() - GROUND_DRAG * delta, speed)
			if target != Vector2.ZERO:
				keep = keep.lerp(target.normalized() * keep.length(),
					minf(STEER_WHILE_FAST * delta, 1.0))
			velocity.x = keep.x
			velocity.z = keep.y
		else:
			velocity.x = target.x
			velocity.z = target.y
	elif dir != Vector3.ZERO:
		velocity.x = move_toward(velocity.x, target.x, AIR_STEER * delta)
		velocity.z = move_toward(velocity.z, target.y, AIR_STEER * delta)

	if dir != Vector3.ZERO:
		rotation.y = lerp_angle(rotation.y, atan2(-dir.x, -dir.z), TURN_SPEED * delta)

	var separate := CharacterSeparation.push(self)
	velocity += carry_velocity + separate
	move_and_slide()
	velocity -= carry_velocity + separate
	carry_velocity = Vector3.ZERO

	sync_speed = Vector2(velocity.x, velocity.z).length()
	sync_air = not grounded
	if global_position.y < WorldData.FALL_LIMIT:
		teleport(WorldData.zone_center(WorldData.zone_index(global_position)) + Vector3(0, 3, 0))
	sync_position = position
	sync_yaw = rotation.y


func _follow_sync(delta: float) -> void:
	if position.distance_squared_to(sync_position) > NET_SNAP_DIST * NET_SNAP_DIST:
		position = sync_position
		rotation.y = sync_yaw
		return
	var w := 1.0 - exp(-delta * NET_SMOOTH)
	position = position.lerp(sync_position, w)
	rotation.y = lerp_angle(rotation.y, sync_yaw, w)


## --- 状況の把握 ---------------------------------------------------------

## 全鬼の位置（＝ミニマップ）を取り直し、最寄りの距離と「詰められている速さ」を更新する。
## GameManager.hunters() は毎回ツリーを走査するので HUNTER_CACHE 間隔に間引く
func _update_hunters(delta: float) -> void:
	_hunter_timer -= delta
	if _hunter_timer <= 0.0:
		_hunter_timer = HUNTER_CACHE
		_hunters = GameManager.hunters()
	_threat_dist = INF
	var nearest := 0
	for h in _hunters:
		if not is_instance_valid(h):
			continue
		var d := _xz_dist(global_position, h.global_position)
		if d < _threat_dist:
			_threat_dist = d
			nearest = h.get_instance_id()
	# 最寄りが別の鬼に入れ替わった瞬間は距離が飛ぶ。それを「詰められた」と
	# 読むと、遠い相手にスタミナを吐いてしまう
	if _threat_prev == INF or _threat_dist == INF or nearest != _threat_id:
		_threat_id = nearest
		_threat_prev = _threat_dist
		_closing = 0.0
		return
	# 距離の縮み方をならす。ドットの動きから読める以上の情報は使わない
	_closing = lerpf(_closing, (_threat_prev - _threat_dist) / delta,
		1.0 - exp(-delta * CLOSING_SMOOTH))
	_threat_prev = _threat_dist


func _update_mind() -> void:
	var mind := Mind.ROAM
	if _threat_dist <= PANIC_DIST:
		mind = Mind.PANIC
	elif _threat_dist <= THREAT_FAR or GameManager.spotted:
		mind = Mind.EVADE
	if mind == _mind:
		return
	_mind = mind
	_repath_timer = 0.0   # 状態が変わったら即座に引き直す
	_goal_timer = 0.0


## 行き先は REPICK_INTERVAL ごとに採点し直す。**震えを止めるのは間隔ではなく
## STICKY_BONUS**（今の行き先の近くを優遇する下駄）の側で、こうしておくと
## 「状況が変わったら乗り換えるが、僅差では乗り換えない」になる
func _update_goal(delta: float) -> void:
	_goal_timer -= delta
	_repick_timer -= delta
	_giveup_left = maxf(_giveup_left - delta, 0.0)
	var dist := _xz_dist(global_position, _goal)
	if _sidestep_left <= 0.0 and slide_left <= 0.0:
		_progress_timer -= delta
		if _progress_timer <= 0.0:
			_progress_timer = PROGRESS_TIME
			if dist > _progress_from - PROGRESS_DIST:
				# 近づけていない。この行き先は諦めて、しばらくその周辺を選ばない
				_giveup_at = _goal
				_giveup_left = GIVEUP_TIME
				_goal_timer = 0.0
			_progress_from = dist
	if _goal_timer <= 0.0 or _repick_timer <= 0.0 or dist < ARRIVE_DIST:
		_pick_escape_goal()


## 逃走先の採点。9ゾーン x 5点の候補から、いちばん「安全で・遠回りでなく・
## 鬼の前を横切らず・逃げ道が広い」点を選ぶ
func _pick_escape_goal() -> void:
	var best := _goal
	var best_score := -INF
	for zone in WorldData.ZONE_COUNT:
		for k in 5:
			var dx := 0.0
			var dz := 0.0
			if k > 0:
				dx = CAND_OFFSET if k == 1 or k == 2 else -CAND_OFFSET
				dz = CAND_OFFSET if k == 1 or k == 3 else -CAND_OFFSET
			var p := WorldData.zone_point(zone, dx, dz)
			var travel := _xz_dist(global_position, p)
			if travel < MIN_TRAVEL:
				continue  # 立ち止まらせない。到着＝次の行き先を探す
			var score := _escape_score(p, travel)
			if _xz_dist(p, _goal) < ARRIVE_DIST:
				score += STICKY_BONUS  # 同点の候補の間で左右に震えないように
			if score > best_score:
				best_score = score
				best = p
	var picked := _snap_to_nav(best)
	# 進捗の見張りは**行き先が変わった時だけ**入れ直す。0.4 秒ごとの見直しで
	# 毎回リセットすると PROGRESS_TIME(1.2秒) の窓が永久に閉じず、
	# 入れない場所を押し続けても「諦める」判定に到達しない
	if _xz_dist(picked, _goal) > ARRIVE_DIST:
		_progress_timer = PROGRESS_TIME
		_progress_from = _xz_dist(global_position, picked)
	_goal = picked
	_goal_timer = GOAL_TIMEOUT
	_repath_timer = 0.0
	_repick_timer = REPICK_INTERVAL


func _escape_score(p: Vector3, travel: float) -> float:
	var near := INF
	var second := INF
	for h in _hunters:
		if not is_instance_valid(h):
			continue
		var d := _xz_dist(p, h.global_position)
		if d < near:
			second = near
			near = d
		elif d < second:
			second = d
	if near == INF:
		near = WorldData.WORLD_HALF * 2.0
	if second == INF:
		second = near
	# 外周壁までの余裕。狭い所（角）だけを減点する
	var open := minf(WorldData.WORLD_HALF - absf(p.x), WorldData.WORLD_HALF - absf(p.z))
	var corner := maxf(CORNER_MARGIN - open, 0.0) * CORNER_WEIGHT
	# 入れなかった行き先の周辺は、しばらく選び直さない
	var giveup := 0.0
	if _giveup_left > 0.0 and _xz_dist(p, _giveup_at) < GIVEUP_RADIUS:
		giveup = GIVEUP_PENALTY
	# (near - travel) = 自分が着いた時点で最寄りの鬼がまだ離れている距離
	var lead := travel * TRAVEL_WEIGHT
	var spread := (second - lead) * SPREAD_WEIGHT
	return (near - lead) + spread - corner - giveup - _cross_penalty(p)


## 自分から p へ向かう線分のそばに鬼がいる分の減点。
## 「一番遠い場所＝鬼の向こう側」を選んで自分から突っ込むのを防ぐ
func _cross_penalty(p: Vector3) -> float:
	var a := Vector2(global_position.x, global_position.z)
	var b := Vector2(p.x, p.z)
	var seg := b - a
	var len2 := seg.length_squared()
	var total := 0.0
	for h in _hunters:
		if not is_instance_valid(h):
			continue
		var q := Vector2(h.global_position.x, h.global_position.z)
		var t := CROSS_FROM if len2 < 0.01 else clampf((q - a).dot(seg) / len2, CROSS_FROM, 1.0)
		var d := q.distance_to(a + seg * t)
		total += CROSS_PENALTY * clampf(1.0 - d / CROSS_RADIUS, 0.0, 1.0)
	return total


## 幾何で決めた点は壁の中や崖下を指すことがある。そのまま渡すと
## NavigationAgent3D が「一番近いポリゴン」へ経路を引いて破綻する
## （hunter_squad.pincer_goal と同じ理由）
func _snap_to_nav(p: Vector3) -> Vector3:
	var world := get_world_3d()
	if world == null:
		return p
	var fit := NavigationServer3D.map_get_closest_point(world.navigation_map, p)
	# ナビマップが空（ベイク前）だと原点が返る。その時は素の値を使う
	if fit == Vector3.ZERO and p.length_squared() > 1.0:
		return p
	return fit


## --- スタミナ -----------------------------------------------------------

## 吐く価値があるか。「近いから全力」ではなく「今吐かないと詰められるか」で決める。
## player.gd の _update_stamina と同じ経済（消費20/s・回復18/s・復帰30）
func _wants_dash() -> bool:
	match _mind:
		Mind.PANIC:
			return true
		Mind.EVADE:
			var urgent := _threat_dist <= DASH_ENGAGE and _closing > 0.0
			if GameManager.spotted and _threat_dist <= DASH_SPOTTED:
				urgent = true
			if not urgent:
				return false
			# まだ余裕のある距離なら、最後の DASH_RESERVE は詰められた時のために残す
			return _threat_dist <= DASH_RESERVE_DIST or stamina > DASH_RESERVE
		_:
			return false  # 安全なうちは温存する


func _update_stamina(delta: float, wants: bool) -> void:
	is_dashing = wants and not exhausted and stamina > 0.0 and stun_left <= 0.0
	if is_dashing:
		stamina = maxf(stamina - STAMINA_DRAIN * delta, 0.0)
		if stamina <= 0.0:
			exhausted = true
			is_dashing = false
	else:
		stamina = minf(stamina + STAMINA_REGEN * delta, STAMINA_MAX)
		if exhausted and stamina >= STAMINA_RECOVER:
			exhausted = false


## --- アイテム（？ブロックから渡される） ---------------------------------
## player.gd の give_item と同契約。ルーレットが回りきるまで使えないのも同じ
func give_item(id: int) -> void:
	if not is_multiplayer_authority():
		return
	item = id
	item_lock = Player.ITEM_ROULETTE


## 置き物は自分の背後に出る。逃走者にとってはそこが**追ってくる鬼の進路**なので、
## 鬼側の _try_use_item のような「仲間の視認」条件は要らない（ミニマップで全鬼が見える）
func _try_use_item() -> void:
	if item == Player.Item.NONE or item_lock > 0.0 or _hunters.is_empty():
		return
	var fwd := -global_transform.basis.z
	var f2 := Vector2(fwd.x, fwd.z)
	if f2.length_squared() < 0.01:
		return
	f2 = f2.normalized()
	# 背後にいちばん近い鬼と、正面にいちばん近い鬼を別々に見る
	var behind_dist := INF
	var ahead_dist := INF
	for h in _hunters:
		if not is_instance_valid(h):
			continue
		var flat := Vector2(h.global_position.x - global_position.x,
			h.global_position.z - global_position.z)
		if flat.length_squared() < 0.01:
			continue
		var d := flat.length()
		var dot := f2.dot(flat / d)
		if dot < ITEM_BEHIND_DOT:
			behind_dist = minf(behind_dist, d)
		elif dot > ROCKET_AHEAD_DOT:
			ahead_dist = minf(ahead_dist, d)
	match item:
		Player.Item.BANANA:
			if behind_dist > BANANA_RANGE:
				return
			_drop_behind(Player.Item.BANANA, Player.BANANA_BEHIND)
		Player.Item.BLOCK:
			# 壁は射程が長い分、バナナより遠い間合いで通路を塞ぐのに使う
			if behind_dist < BLOCK_RANGE_MIN or behind_dist > BLOCK_RANGE_MAX:
				return
			_drop_behind(Player.Item.BLOCK, Player.BLOCK_BEHIND)
		Player.Item.ROCKET:
			# 正面へ飛ぶので、正面が退路になっている時だけ意味がある
			if _threat_dist > ROCKET_ESCAPE or ahead_dist < ROCKET_AHEAD_RANGE:
				return
			launch(Vector3(fwd.x, 0.0, fwd.z).normalized() * Player.ROCKET_FORWARD
				+ Vector3(0, Player.ROCKET_UP, 0))
		_:
			return
	item = Player.Item.NONE


## CPU はサーバ上でしか動かないので、player.gd の rpc 分岐は要らず直接呼べる
func _drop_behind(kind: int, back_dist: float) -> void:
	var back := global_transform.basis.z
	GameManager.request_drop(kind,
		global_position + Vector3(back.x, 0.0, back.z).normalized() * back_dist,
		rotation.y)


## --- 詰まりからの脱出（cpu_hunter.gd の _avoid_stuck と同じ判断） --------

func _avoid_stuck(delta: float) -> void:
	if _sidestep_left > 0.0:
		_sidestep_left -= delta
		return
	_stuck_timer += delta
	if _stuck_timer < STUCK_ESCAPE.STUCK_TIME:
		return
	var moved := _xz_dist(global_position, _stuck_from)
	_stuck_timer = 0.0
	_stuck_from = global_position
	if moved >= STUCK_ESCAPE.STUCK_DIST:
		return
	var kick := STUCK_ESCAPE.normal_kick(self, SPEED)
	if kick != Vector3.ZERO:
		_stuck_kick = kick
		_stuck_kick_left = STUCK_ESCAPE.KICK_TIME
		_repath_timer = 0.0
		return
	var to_goal := _goal - global_position
	var side := Vector3(-to_goal.z, 0.0, to_goal.x).normalized()
	if side.length_squared() < 0.01:
		side = Vector3.RIGHT
	if _rng.randf() < 0.5:
		side = -side
	_sidestep_goal = global_position + side * SIDESTEP_DIST
	_sidestep_left = SIDESTEP_TIME
	_repath_timer = 0.0


## 壁に正面から当たっている間は、進みたい向きを壁に沿わせる。
## move_and_slide() も速度は滑らせるが、こちらが毎フレーム「壁へ食い込む向き」を
## 出し続けると実効速度がほぼゼロのまま張り付く。スロープの側面（横から見ると
## ただの垂直な壁）に当たったまま、鬼が来るまで6秒動けなかったのがこれ。
## 床・天井（法線が縦）は無視して、水平な法線だけを見る
func _slide_along_walls(dir: Vector3) -> Vector3:
	if dir == Vector3.ZERO:
		return dir
	var out := dir
	for i in get_slide_collision_count():
		var n := get_slide_collision(i).get_normal()
		if absf(n.y) > 0.5:
			continue
		var flat := Vector3(n.x, 0.0, n.z)
		if flat.length_squared() < 0.01:
			continue
		flat = flat.normalized()
		var into := out.dot(flat)
		if into < 0.0:
			out -= flat * into
	return out.normalized() if out.length() > 0.05 else dir


func _xz_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## ワープ地点が「その近道は自分の役に立つか」を判断するために参照する
func get_ai_goal() -> Vector3:
	return _goal


## --- ギミックから呼ばれる API（player.gd と同じ契約） --------------------

func teleport(pos: Vector3) -> void:
	global_position = pos
	sync_position = position
	velocity = Vector3.ZERO
	bumper_bounce_left = 0.0
	buffs.clear()
	# ラウンド開始のテレポートでも呼ばれる。player.gd と同じく息を整えておく
	stamina = STAMINA_MAX
	exhausted = false
	is_dashing = false
	item = Player.Item.NONE
	item_lock = 0.0
	warp_lock = 0.0
	warp_grace = 0.0
	slide_left = 0.0
	stun_left = 0.0
	stunned = false
	_repath_timer = 0.0
	_goal_timer = 0.0
	_repick_timer = 0.0
	_threat_prev = INF
	_threat_id = 0
	_closing = 0.0
	_stuck_from = global_position
	_stuck_kick_left = 0.0


func launch(v: Vector3) -> void:
	if v.y != 0.0:
		velocity.y = v.y
	velocity.x += v.x
	velocity.z += v.z
	_repath_timer = 0.0
	_stuck_from = global_position
	_stuck_kick_left = 0.0


func hold_bumper_bounce(horizontal: Vector3, duration: float) -> void:
	bumper_bounce_velocity = horizontal
	bumper_bounce_left = duration


func warp_to(pos: Vector3, up_vel: float, exit_kick := Vector3.ZERO) -> void:
	global_position = pos
	velocity = Vector3(exit_kick.x, up_vel, exit_kick.z)
	bumper_bounce_left = 0.0
	warp_lock = 0.9
	warp_grace = WARP_GRACE
	slide_left = 0.0
	_repath_timer = 0.0
	_goal_timer = 0.0
	_threat_prev = INF
	_threat_id = 0
	_closing = 0.0
	_stuck_from = global_position
	_stuck_kick_left = 0.0


func apply_boost(mult: float, dur: float, kick: Vector3) -> void:
	buffs.add(&"speed", mult, dur)
	velocity.x += kick.x
	velocity.z += kick.z


func add_carry(v: Vector3) -> void:
	carry_velocity += v


func apply_slide(dir: Vector3, accel: float, cap: float) -> void:
	slide_dir = dir
	slide_accel = accel
	slide_cap = cap
	slide_left = SLIDE_GRACE


func apply_stun(seconds: float) -> void:
	stun_left = maxf(stun_left, seconds)
	stunned = true
	# 水平速度は殺さない。走っていた勢いのまま尻で滑らせる（SLIP_DRAG で減速する）
