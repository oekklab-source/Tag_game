extends CharacterBody3D

const CPU_NAV_ASSIST := preload("res://scenes/cpu_nav_assist.gd")
const STUCK_ESCAPE := preload("res://scenes/stuck_escape.gd")

## ソロモード用の CPU 鬼。ロジックはホスト（サーバ）でのみ動作し、
## 位置・回転は MultiplayerSynchronizer で途中参加者にも配信される。
##
## 逃走者の位置は**知らない**。人間の鬼とまったく同じ情報しか持たず、3状態で動く:
##   CHASE       自分が視認している -> 追跡役は直接、他は逃走方向を塞ぐ位置へ
##   INVESTIGATE 誰かが通報したゾーンがある -> 現地か、その隣（逃げ道）を張る
##   PATROL      情報なし -> 長く見ていないゾーンを分担して掃く
## 視認判定は GameManager に一本化してあり、ここでレイは飛ばさない。
##
## 「どのゾーンを誰が担当するか」「包囲のどの角度を持つか」も自分では決めず、
## GameManager.squad（HunterSquad）に問い合わせる。個体が勝手に決めると
## 全員が同じゾーンへ重なり、同じ側から追ってしまう。

## 脚は逃走者とまったく同じにする。鬼が強い理由を「足が速いから」ではなく
## 「見つける・読む・詰めるのが上手いから」に一本化するため。
## この結果、直線で逃げ続ける相手には**原理的に追いつけない**。捕獲力はすべて
## 早期発見・先読み・挟み込み・退路封鎖から来る。
## 弱すぎると感じた時に最初に戻すレバーがここ（Player.BASE_SPEED の定数倍にする）。
## 補足: get_speed_mult() は peer_id 基準で CPU はピアではないため、
## 人数による速度補正の対象外。CPU はこの定数だけで調整する
const SPEED := Player.BASE_SPEED
## 巡航の上に乗せる全力。人間の鬼・逃走者と同じ 10.5 m/s
const DASH_SPEED := Player.BASE_SPEED * Player.DASH_MULT
## 消費・回復・復帰だけでなく総量も player.gd と同じにする。
## 経済が完全に一致するので「どれくらい粘れるか」の読みが両者で食い違わない
const STAMINA_MAX := Player.STAMINA_MAX
const STAMINA_DRAIN := Player.STAMINA_DRAIN
const STAMINA_REGEN := Player.STAMINA_REGEN
const STAMINA_RECOVER := Player.STAMINA_RECOVER
## 見えていてもこの距離より遠ければ吐かない。追いつく前に切れては意味がない
const DASH_ENGAGE := 34.0
## 通報が入った直後のこの秒数だけは、現地へ全力で急行する
const DASH_INTEL_BURST := 6.0

## 進行方向に対して首を振る幅。can_see() はボディの -Z を使うので、
## ここを広げるとそのまま実効視野が広がる（100° -> 約190°）。
## 移動は velocity が別に駆動しているので進路には影響しない
const SCAN_ANGLE := 45.0
const SCAN_RATE := 2.2        # rad/s。速すぎると首がガクガクして見える

## --- アイテムの使用方針 -------------------------------------------------
## 置き物は「自分の背後」に出る（player.gd の BANANA_BEHIND / BLOCK_BEHIND）。
## つまり先回りして逃走者に背を向けて走っている時に置くと、相手の進路に置ける
const ITEM_BEHIND_DOT := -0.3   # 逃走者がこれより後ろにいれば「先回りできている」
const BANANA_RANGE := 12.0
const BLOCK_RANGE_MIN := 8.0
const BLOCK_RANGE_MAX := 18.0
## ロケットは正面へ飛ぶので、逃走者を正面に捉えている時だけ使う
const ROCKET_DOT := 0.87        # 約30°
const ROCKET_RANGE_MIN := 8.0

enum Mind { PATROL, INVESTIGATE, CHASE }

## 捜索中はゾーン中心に立ち止まらず歩き回る。6m壁があると中心からは
## ゾーンの3割程度しか見えず、視野を振って初めて死角が潰れる
const SWEEP_RADIUS := 18.0
const SWEEP_ARRIVE := 4.0
const SWEEP_TIMEOUT := 6.0
## 1つのゾーンを何回掃いたら次へ移るか。多いほど取りこぼしが減るが、
## 鬼3体で9ゾーンを回すため、増やすとマップ一周が目に見えて遅くなる
const SWEEPS_PER_ZONE := 2
## 目的地があるのにほとんど進めていない＝何かに押し付けられている。
## ナビメッシュに焼かれていない設置ブロックが典型だが、壁の角や
## CPU 同士の押し合いでも起きるので汎用の脱出手段として持たせる。
## 検知の閾値は stuck_escape.gd 側で player.gd と共有する
const SIDESTEP_TIME := 1.2
const SIDESTEP_DIST := 6.0
const AIR_STEER := 6.0        # 空中での方向転換（プレイヤーより弱く、慣性を残す）
const REPATH_INTERVAL := 0.15
const TURN_SPEED := 14.0
const DIRECT_CHASE_DIST := 16.0
## 挟み役が持ち場を捨てて直接掴みに行く距離。追跡役(16m)よりずっと短くして、
## 触れる寸前まで逃げ道を塞ぎ続けさせる。長くすると全員が一列に詰まって
## ただの追いかけっこに戻ってしまう
const FLANK_DIRECT_DIST := 7.0
## ダイブで飛びかかる距離。近すぎると走って触った方が速く、
## 遠すぎると空振りして起き上がりの隙を晒すだけになる
const DIVE_MIN := 3.0
const DIVE_MAX := 9.0
const HUNTER_COLOR := Player.COLOR_HUNTER
## 滑走・ブースト・ロケットの勢いは player.gd と同じ値で扱う
## （鬼だけ勢いが残る/残らないの差が出ると追跡バランスが崩れる）
const GROUND_DRAG := Player.GROUND_DRAG
const STEER_WHILE_FAST := Player.STEER_WHILE_FAST
const SLIP_DRAG := Player.SLIP_DRAG
const SLIDE_STEER := Player.SLIDE_STEER
const SLIDE_MIN_SPEED := Player.SLIDE_MIN_SPEED
const SLIDE_SNAP := Player.SLIDE_SNAP
const SLIDE_GRACE := Player.SLIDE_GRACE
const WARP_GRACE := Player.WARP_GRACE
## ダイブもプレイヤーと同じ性能にする。鬼だけ速い/遅いと追跡バランスが崩れる
const DIVE_SPEED := Player.DIVE_SPEED
const DIVE_UP := Player.DIVE_UP
const DIVE_RECOVER := Player.DIVE_RECOVER
const DIVE_COOLDOWN := Player.DIVE_COOLDOWN
const DIVE_PITCH := Player.DIVE_PITCH
const NET_SMOOTH := Player.NET_SMOOTH
const NET_SNAP_DIST := Player.NET_SNAP_DIST

var buffs := BuffSet.new()
var carry_velocity := Vector3.ZERO
var slide_dir := Vector3.ZERO
var slide_accel := 0.0
var slide_cap := 0.0
var slide_left := 0.0
var warp_lock := 0.0
var warp_grace := 0.0

var diving := false
var dive_recover := 0.0
var dive_cooldown := 0.0

var stamina := STAMINA_MAX
var exhausted := false
var is_dashing := false
## player.gd と同じ契約。CPU の権威はサーバなのでホスト上だけで進む
var item: int = Player.Item.NONE
var item_lock := 0.0

var _repath_timer := 0.0
var _scan_phase := 0.0
var _mind: int = Mind.PATROL
var _goal := Vector3.ZERO
var _goal_timer := 0.0
var _sweeps_left := 0
var _rng := RandomNumberGenerator.new()
var stun_left := 0.0
## 転んでいる最中か。見た目の Slip モーションに使うのでレプリケートする
## （stun_left はサーバしか持っていないので、そのままでは他ピアで棒立ちになる）
var stunned := false
var _stuck_timer := 0.0
var _stuck_from := Vector3.ZERO
var _sidestep_left := 0.0
var _sidestep_goal := Vector3.ZERO
var _stuck_kick := Vector3.ZERO
var _stuck_kick_left := 0.0

## ホストが書き、他ピアはここへ補間する。詳細は player.gd の同名変数を参照。
## CPU が他ピアから見えるのはソロ戦の途中に誰かが入って来た場合だけだが、
## 位置の扱いはプレイヤーと揃えておく
@export var sync_position := Vector3.ZERO
@export var sync_yaw := 0.0
## 歩行モーション用。player.gd と同じ理由で、受け取る側で位置の変化から
## 割り出さずサーバが実測した値を配る（あちらのコメントを参照）
@export var sync_speed := 0.0
@export var sync_air := false

@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var humanoid: Node3D = $Humanoid
@onready var name_label: Label3D = $NameLabel


func _ready() -> void:
	add_to_group("cpu_hunters")
	humanoid.set_color(HUNTER_COLOR)
	name_label.text = name
	if multiplayer.is_server():
		sync_position = position
		sync_yaw = rotation.y
	else:
		position = sync_position
		rotation.y = sync_yaw
	$TagArea.body_entered.connect(_on_tag_area_body_entered)
	# 再経路探索のタイミングを個体ごとに散らす（同フレームに固まらせない）
	_repath_timer = randf() * REPATH_INTERVAL
	_rng.seed = hash(name)
	# 3体が同期して首を振ると死角まで揃ってしまう。位相を個体ごとにずらす
	_scan_phase = _rng.randf() * TAU


func _on_tag_area_body_entered(body: Node3D) -> void:
	if multiplayer.is_server():
		GameManager.report_touch(self, body)


func _process(delta: float) -> void:
	_update_name_label()
	if delta <= 0.0:
		return
	if not multiplayer.is_server():
		_follow_sync(delta)
	humanoid.set_diving(diving)
	humanoid.set_stunned(stunned)
	humanoid.update_motion(sync_speed, not sync_air, delta)
	humanoid.rotation.x = lerpf(humanoid.rotation.x,
		DIVE_PITCH if diving else 0.0, minf(delta * 12.0, 1.0))


## 頭上の名前ラベル。player.gd と同じく、味方ハンター（人間）にのみ見せる
func _update_name_label() -> void:
	name_label.visible = (GameManager.state == GameManager.State.PLAYING
		and multiplayer.get_unique_id() != GameManager.runner_id)


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	buffs.tick(delta)
	warp_lock = maxf(warp_lock - delta, 0.0)
	stun_left = maxf(stun_left - delta, 0.0)
	# 終わるたび必ず false を挟むので、続けて2回転んでも ON_CHANGE の同期が発火する
	stunned = stun_left > 0.0

	# player.gd と同じ。他キャラの頭の上を接地扱いすると重力が止まり、
	# 相手に乗ったまま空中で静止する
	var grounded := is_on_floor() and not CharacterSeparation.on_character(self)

	if warp_grace > 0.0 or not grounded:
		velocity += get_gravity() * delta
	dive_cooldown = maxf(dive_cooldown - delta, 0.0)
	_tick_dive(delta)

	var chasing := (GameManager.state == GameManager.State.PLAYING
		and GameManager.head_start_left <= 0.0
		and stun_left <= 0.0 and not diving)
	var dir := Vector3.ZERO
	var rise := 0.0
	var wants_dash := false
	item_lock = maxf(item_lock - delta, 0.0)
	if chasing:
		var runner: Node3D = GameManager.get_runner()
		if runner:
			# 状態を先に決める。自分の視認 > 共有された通報 > 情報なし
			var mind := Mind.PATROL
			if GameManager.hunter_sees_runner(self):
				mind = Mind.CHASE
			elif GameManager.spotted_zone >= 0:
				mind = Mind.INVESTIGATE
			if mind != _mind:
				_mind = mind
				_repath_timer = 0.0  # 状態が変わったら即座に経路を引き直す
				_goal_timer = 0.0
			_goal_timer -= delta
			_update_goal(runner, delta)
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
			if not assist["direct"] and _xz_dist(global_position, next) < 0.2 \
					and _xz_dist(global_position, nav_goal) > 1.0:
				next = nav_goal
			var to_runner := runner.global_position - global_position
			var h_dist := Vector2(to_runner.x, to_runner.z).length()
			# 見えている近距離で高低差が小さい、またはナビで到達不能なら直接追跡へ。
			# 挟み役は触れる寸前まで持ち場を保つので、切り替える距離をずっと短くする
			var direct_dist := (DIRECT_CHASE_DIST if GameManager.squad.is_prime(self)
				else FLANK_DIRECT_DIST)
			if (_mind == Mind.CHASE and h_dist < direct_dist
					and (absf(to_runner.y) < 1.2 or not agent.is_target_reachable())):
				next = runner.global_position
			dir = next - global_position
			rise = dir.y
			dir.y = 0.0
			dir = dir.normalized() if dir.length() > 0.05 else Vector3.ZERO
			dir = CPU_NAV_ASSIST.avoid_bumpers(global_position, dir, get_tree())
			dir = CPU_NAV_ASSIST.boost_assist(global_position, dir, _goal)
			wants_dash = _wants_dash(h_dist)
			_try_use_item(to_runner, h_dist)
			# 見えている逃走者が手頃な距離にいたら飛びかかる。
			# プレイヤーと同じくダイブ中は操作できず、外せば起き上がりの隙を晒す
			if (_mind == Mind.CHASE and grounded and dive_cooldown <= 0.0
					and h_dist > DIVE_MIN and h_dist < DIVE_MAX and absf(to_runner.y) < 2.0):
				_start_dive(Vector3(to_runner.x, 0.0, to_runner.z))

	_update_stamina(delta, wants_dash)

	# プレイヤーと同じく、空中では慣性を保つ（打ち上げ・ブーストが消えないように）
	var speed := (DASH_SPEED if is_dashing else SPEED) * buffs.get_mult(&"speed")
	var target := Vector2(dir.x, dir.z) * speed
	if slide_left > 0.0:
		velocity = SlideMotion.step(velocity, delta, slide_dir, slide_accel, slide_cap,
			SLIDE_STEER, dir, SLIDE_MIN_SPEED)
		floor_snap_length = SLIDE_SNAP
		slide_left = maxf(slide_left - delta, 0.0)
		if slide_left <= 0.0:
			# 降り切った先は経路上の想定外の場所。すぐ引き直す（warp_to と同じ理由）
			_repath_timer = 0.0
			_goal_timer = 0.0
	elif warp_grace > 0.0:
		# player.gd と同じ理由。ワープ直後の is_on_floor() は1フレーム古く、
		# それを信じると地上の速度上書きが出口の水平速度を消してしまう
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
		# 捜索中は進行方向から首を振って死角を潰す。can_see() はボディの -Z を
		# 見るので、ここに足すだけで実効視野が広がる（velocity は別なので進路は不変）
		var face := atan2(-dir.x, -dir.z)
		if _mind != Mind.CHASE:
			_scan_phase += SCAN_RATE * delta
			face += sin(_scan_phase) * deg_to_rad(SCAN_ANGLE)
		rotation.y = lerp_angle(rotation.y, face, TURN_SPEED * delta)

	# 重なりをほどく速度は carry_velocity と同じく一時的に足すだけにする。
	# velocity に残すと毎フレーム蓄積して吹き飛ぶ
	var separate := CharacterSeparation.push(self)
	velocity += carry_velocity + separate
	move_and_slide()
	velocity -= carry_velocity + separate
	carry_velocity = Vector3.ZERO

	# 歩行モーションは物理の実測値で駆動する（player.gd と同じ理由）
	sync_speed = Vector2(velocity.x, velocity.z).length()
	sync_air = not grounded

	if global_position.y < WorldData.FALL_LIMIT:
		teleport(WorldData.zone_center(WorldData.zone_index(global_position)) + Vector3(0, 3, 0))

	sync_position = position
	sync_yaw = rotation.y


## 非権威ピアのみ。詳細は player.gd の同名関数を参照
func _follow_sync(delta: float) -> void:
	if position.distance_squared_to(sync_position) > NET_SNAP_DIST * NET_SNAP_DIST:
		position = sync_position
		rotation.y = sync_yaw
		return
	var w := 1.0 - exp(-delta * NET_SMOOTH)
	position = position.lerp(sync_position, w)
	rotation.y = lerp_angle(rotation.y, sync_yaw, w)


## 状態に応じて目的地を更新する。
## 目的地は「到着したか時間切れの時」だけ差し替え、毎フレーム動かさない
## （動かすと NavigationAgent3D の経路が落ち着かず、その場で震える）
func _update_goal(runner: Node3D, _delta: float) -> void:
	var squad: HunterSquad = GameManager.squad
	match _mind:
		Mind.CHASE:
			# 追跡役は逃走者そのもの、挟み役は逃走方向を塞ぐ持ち場へ。
			# 割り当ては squad が全鬼をまとめて見て決めている
			_goal = squad.pincer_goal(self, runner)
		Mind.INVESTIGATE:
			# 現地へ入るのは1体だけ。残りは隣のゾーン（逃げ出す先）を張る
			_sweep_zone(squad.watch_zone(self, GameManager.spotted_zone))
		_:
			# 掃き終えたら次の担当を貰う。他の鬼が持っているゾーンは来ない
			if _sweep_zone(squad.search_zone(self)):
				squad.next_search_zone(self)


## 担当ゾーンへ入り、中を掃くように歩き回る。掃き終わったら true。
## ゾーン中心に立っているだけでは6m壁に阻まれて3割ほどしか見えないため、
## 到着後も何度か中を歩かせて死角を潰す
func _sweep_zone(zone: int) -> bool:
	if zone < 0:
		return false
	if WorldData.zone_index(global_position) != zone:
		_goal = WorldData.zone_center(zone)  # まず現地へ
		_goal_timer = SWEEP_TIMEOUT
		_sweeps_left = SWEEPS_PER_ZONE
		return false
	if _goal_timer > 0.0 and _xz_dist(global_position, _goal) >= SWEEP_ARRIVE:
		return false
	_sweeps_left -= 1
	_goal = WorldData.zone_point(zone,
		_rng.randf_range(-SWEEP_RADIUS, SWEEP_RADIUS),
		_rng.randf_range(-SWEEP_RADIUS, SWEEP_RADIUS))
	_goal_timer = SWEEP_TIMEOUT
	# 次の一歩は必ず用意した上で報告する。呼び出し側が担当を替えない
	# INVESTIGATE では、掃き終わってもその場に立ち止まらず掃き続けてほしい
	if _sweeps_left <= 0:
		_sweeps_left = SWEEPS_PER_ZONE
		return true
	return false


## スタミナを吐く価値があるか。ここが鬼の強さの本体で、
## 「見えているから全力」ではなく「今吐けば届くか」で決める
func _wants_dash(h_dist: float) -> bool:
	match _mind:
		Mind.CHASE:
			# 遠いうちに吐いても追いつく前に切れて、肝心の詰めで息が上がる
			return h_dist < DASH_ENGAGE
		Mind.INVESTIGATE:
			# 通報が入った直後だけ全力で急行する。古い情報に全力は出さない
			return GameManager.intel_left > GameManager.INTEL_TIME - DASH_INTEL_BURST
		_:
			return false  # 巡回中は温存して、見つけた時に必ず吐けるようにする


## player.gd の _update_stamina と同じ経済（消費20/s・回復18/s・復帰30）。
## スタミナはレプリケートしない。結果である「速く動くこと」は位置同期で伝わる
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
## player.gd の give_item と同契約。ルーレットが回りきるまで使えないのも同じで、
## 「中身が見えていないのに使ってくる」という不自然さを避ける
func give_item(id: int) -> void:
	if not is_multiplayer_authority():
		return
	item = id
	item_lock = Player.ITEM_ROULETTE


## 置き物は自分の背後に出るので、「逃走者に背を向けて走っている＝先回りできている」
## 時にだけ置くと相手の進路に置ける。追いかけながら後ろに撒いても無意味。
##
## 条件を「自分が見ている(_mind == CHASE)」にしてはいけない。視界は前方100°しか
## 無いので、背後に置く条件（dot < -0.3 ＝ 107°以上うしろ）と絶対に両立しない。
## 判断には仲間の誰かが見ている(GameManager.spotted)という共有情報を使う。
## 挟み込みが共有情報で動いているのと同じ筋で、先回り役にも目が回ってくる
func _try_use_item(to_runner: Vector3, h_dist: float) -> void:
	if item == Player.Item.NONE or item_lock > 0.0 or not GameManager.spotted:
		return
	var flat := Vector2(to_runner.x, to_runner.z)
	if flat.length_squared() < 0.01:
		return
	var fwd := -global_transform.basis.z
	var dot := Vector2(fwd.x, fwd.z).normalized().dot(flat.normalized())
	match item:
		Player.Item.ROCKET:
			# 正面へ飛ぶので、逃走者を正面に捉えて追っている時だけ意味がある
			if dot < ROCKET_DOT or h_dist < ROCKET_RANGE_MIN:
				return
			launch(Vector3(fwd.x, 0.0, fwd.z).normalized() * Player.ROCKET_FORWARD
				+ Vector3(0, Player.ROCKET_UP, 0))
		Player.Item.BANANA:
			if dot > ITEM_BEHIND_DOT or h_dist > BANANA_RANGE:
				return
			_drop_behind(Player.Item.BANANA, Player.BANANA_BEHIND)
		Player.Item.BLOCK:
			# 壁は射程が長い分、バナナより遠い間合いで通路を塞ぐのに使う
			if dot > ITEM_BEHIND_DOT or h_dist < BLOCK_RANGE_MIN or h_dist > BLOCK_RANGE_MAX:
				return
			_drop_behind(Player.Item.BLOCK, Player.BLOCK_BEHIND)
		_:
			return
	item = Player.Item.NONE


## CPU はサーバ上でしか動かないので、player.gd の rpc 分岐は要らず直接呼べる
func _drop_behind(kind: int, back_dist: float) -> void:
	var back := global_transform.basis.z
	GameManager.request_drop(kind,
		global_position + Vector3(back.x, 0.0, back.z).normalized() * back_dist,
		rotation.y)


## player.gd の _tick_dive / _start_dive と同じ契約。
## diving の間は chasing を落として経路追従を止めるので、踏み切った軌道が最後まで残る
func _tick_dive(delta: float) -> void:
	if not diving:
		return
	if dive_recover > 0.0:
		dive_recover = maxf(dive_recover - delta, 0.0)
		if dive_recover <= 0.0:
			diving = false
	elif is_on_floor():
		dive_recover = DIVE_RECOVER


func _start_dive(toward: Vector3) -> void:
	velocity = toward.normalized() * DIVE_SPEED
	velocity.y = DIVE_UP
	rotation.y = atan2(-toward.x, -toward.z)
	diving = true
	dive_recover = 0.0
	dive_cooldown = DIVE_COOLDOWN


## 目的地があるのに進めていないとき、まず直前の衝突法線から抜け出す向きへ
## 一時的にキックする（壁の角で2枚の法線に押し返されているケースはこれで
## 対角線方向へ抜ける）。法線が拾えない時（設置ブロックがまだナビに
## 焼かれていない等）だけ、目的地に対して直角のランダムな側へ逃がす旧来の
## サイドステップへフォールバックする
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
	# 目的地の方向に対して直角の、開いている側へ逃がす
	var to_goal := _goal - global_position
	var side := Vector3(-to_goal.z, 0.0, to_goal.x).normalized()
	if _rng.randf() < 0.5:
		side = -side
	_sidestep_goal = global_position + side * SIDESTEP_DIST
	_sidestep_left = SIDESTEP_TIME
	_repath_timer = 0.0


func _xz_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## マンホールが「その近道は自分の役に立つか」を判断するために参照する。
## 逃走者の位置ではなく今向かっている場所で判断させること
func get_ai_goal() -> Vector3:
	return _goal


## --- ギミックから呼ばれる API（player.gd と同じ契約） --------------------
## CPU はサーバ権威なので、これらはサーバ上でのみ実行される

func teleport(pos: Vector3) -> void:
	global_position = pos
	sync_position = position
	velocity = Vector3.ZERO
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
	diving = false
	dive_recover = 0.0
	dive_cooldown = 0.0
	_repath_timer = 0.0
	_goal_timer = 0.0
	_stuck_kick_left = 0.0


func launch(v: Vector3) -> void:
	if v.y != 0.0:
		velocity.y = v.y
	velocity.x += v.x
	velocity.z += v.z
	_repath_timer = 0.0
	_stuck_from = global_position
	_stuck_kick_left = 0.0


## exit_kick は水平方向の勢い。player.gd の warp_to と同じ理由
func warp_to(pos: Vector3, up_vel: float, exit_kick := Vector3.ZERO) -> void:
	global_position = pos
	velocity = Vector3(exit_kick.x, up_vel, exit_kick.z)
	warp_lock = 0.9
	warp_grace = WARP_GRACE
	slide_left = 0.0
	_repath_timer = 0.0  # ワープ直後は経路と目的地を引き直す
	_goal_timer = 0.0
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


## バナナを踏んだ時の転倒。？ブロックは CPU に反応しないので、
## CPU が受け取るアイテム系の効果はこれだけ
func apply_stun(seconds: float) -> void:
	stun_left = maxf(stun_left, seconds)
	stunned = true
	# 水平速度は殺さない。走っていた勢いのまま尻で滑らせる（SLIP_DRAG で減速する）
