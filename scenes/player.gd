class_name Player
extends CharacterBody3D

## プレイヤーキャラクター。
## 自分が権威を持つインスタンスのみ入力・物理を処理し、
## 位置と回転は MultiplayerSynchronizer が他ピアへ配信する。

## トースト表示用の出来事 ID（hud.gd と共有）
enum Effect { BOOST, WARP, STUN }

## 持ち物アイテム（question_block.gd / hud.gd と共有）。1個だけ持てる
enum Item { NONE, ROCKET, BANANA, BLOCK }

signal effect_gained(effect: int)
signal item_changed(held: int)

const BASE_SPEED := 7.0       # 160m四方のマップで「歩きゲー」にしないための下限
const DASH_MULT := 1.5        # ダッシュ時 10.5 m/s
const AIR_ACCEL := 14.0       # 空中での方向転換の効き（慣性を残すため小さめ）

## --- ダイブ -------------------------------------------------------------
## この世界に「跳ぶ」手段は無い。段差はスロープ・ジャンプ台・滑り台でしか越えられず、
## 柵を跳び越える抜け道も存在しない。代わりに Space は前方へのダイブになる。
## 鬼が逃走者との距離を一気に詰めて捕まえるための手段（当たり判定は体ごと前へ出る）。
const DIVE_SPEED := 12.0      # ダッシュ(10.5)より速く、滑走(18)より遅い
## わずかに浮くだけ。到達高度は 0.46m で、これで越えられる段差は作っていない
const DIVE_UP := 3.0
const DIVE_RECOVER := 0.55    # 着地後の起き上がり。空振りしたときのリスクがこれ
const DIVE_COOLDOWN := 0.9    # 連打してただの移動手段にさせない
## 見た目の前傾（rad）。前方は -Z なので、X軸まわりは負回転が前倒しになる
const DIVE_PITCH := -1.2

## 通常速度を超えた分の減速 /秒。接地した瞬間に velocity を上書きせず、
## この率で通常速度まで落とす。滑り台の出口・ダッシュパネルの蹴り出し・
## ロケットの着地で得た勢いが「着地の1フレームで消える」のを防ぐ
const GROUND_DRAG := 10.0
const STEER_WHILE_FAST := 3.0 # 通常速度超過中の向き変更の効き

## --- 滑り台 -------------------------------------------------------------
const SLIDE_STEER := 9.0      # 滑走中の左右の寄せ
## 走路上で維持される最低前進速度。毎フレーム強制するので、
## 前フレームの入力で上りに転じても必ず下りへ押し戻される（＝登れない保証）
const SLIDE_MIN_SPEED := 3.5
const SLIDE_SNAP := 0.6       # 滑走中の床スナップ距離。高速降下で床から浮いて跳ねるのを防ぐ
const SLIDE_GRACE := 0.12     # Area を出た直後の1〜2フレームの取りこぼしを吸収する猶予
## warp_to() で位置を直接動かした直後、is_on_floor() が1フレーム古い値
## （ワープ前の接地状態）を返す。それを信じて地上の移動制御に入ると、
## 無入力時は目標速度＝ゼロへ即座に上書きされ、出口の水平速度が消える。
## その間は空中と同じ扱いにして、is_on_floor() の値を無視する
const WARP_GRACE := 0.2
const MOUSE_SENSITIVITY := 0.003
const PITCH_MIN := -60.0
const PITCH_MAX := 30.0

const STAMINA_MAX := 100.0
const STAMINA_DRAIN := 20.0   # ダッシュ中の消費 /秒（連続5秒ダッシュできる）
const STAMINA_REGEN := 18.0   # 非ダッシュ時の回復 /秒（ダッシュ稼働率 約47%）
const STAMINA_RECOVER := 30.0 # 枯渇後、この値まで回復するとダッシュ再可

## ロケット: 前方へ大きく飛ぶ。ジャンプ(1.38m)では届かない距離を一気に詰める/離す
const ROCKET_FORWARD := 12.0
const ROCKET_UP := 9.0
const BANANA_BEHIND := 2.0    # 足元の後ろこの距離に置く
const BLOCK_AHEAD := 3.5      # 目の前この距離に立てる

const COLOR_WAITING := Color(0.62, 0.66, 0.72)
const COLOR_RUNNER := Color(0.2, 1.0, 0.45)
const COLOR_HUNTER := Color(1.0, 0.18, 0.22)

## --- リモートピアの補間 -------------------------------------------------
## インターネット越しでは到着間隔がばらつくので、同期値を直接 position に入れると
## その揺らぎがそのまま見える。exp 減衰なのでフレームレートには依存しない。
## 25 は MultiplayerSynchronizer の replication_interval(0.05) と釣り合う値
## （定常的な遅れ ≒ 速度/25 ≒ 同期1回分の移動量）。上げるほど追従が速く、荒くなる
const NET_SMOOTH := 25.0
## これ以上離れていたら補間せず飛ばす。teleport・土管ワープ・落下復帰で
## 画面を横切って滑っていくのを防ぐ
const NET_SNAP_DIST := 5.0

var stamina := STAMINA_MAX
var exhausted := false
var is_dashing := false
var buffs := BuffSet.new()
var carry_velocity := Vector3.ZERO  # 動く床から毎フレーム渡される搬送速度
var slide_dir := Vector3.ZERO       # 滑り台から毎フレーム渡される最急降下方向
var slide_accel := 0.0
var slide_cap := 0.0
var slide_left := 0.0               # >0 の間だけ滑走状態
## 滞空から起き上がりまでの全体。見た目の前傾に使うのでレプリケートする
var diving := false
var dive_recover := 0.0
var dive_cooldown := 0.0
var warp_lock := 0.0                # 土管の往復ワープ防止
var warp_grace := 0.0               # ワープ直後、is_on_floor() の古い値を無視する猶予
var item: int = Item.NONE
var stun_left := 0.0                # バナナを踏んだ時の操作不能時間

## MultiplayerSynchronizer が配る位置と向き。権威が毎物理フレーム書き、
## 他ピアは position / rotation.y をここへ補間する。
## ボディごと補間するので、視界判定とタッチ判定（どちらもボディ基準）と
## 見た目がずれない。向きはヨーだけ: ボディの x/z 回転は誰も触らないし、
## Euler をそのまま lerp すると ±PI をまたぐ瞬間に一回転する
@export var sync_position := Vector3.ZERO
@export var sync_yaw := 0.0
## 歩行モーション用の水平速度と滞空。権威ピアが実測して配る。
##
## 受け取る側で「同期位置が前回からどれだけ動いたか」から割り出してはいけない。
## それは移動時間ではなく**パケットの到着間隔**を測っていることになり、
## インターネット越し（トンネル経由の Web クライアント）だと到着が
## まとまったり途切れたりするだけで速度が乱高下し、脚が止まったり痙攣したりする。
## 速度は権威ピアだけが正確に知っているので、素直に配るのが一番確実で安い
@export var sync_speed := 0.0
@export var sync_air := false

var _current_color := Color.TRANSPARENT

@onready var spring_arm: SpringArm3D = $SpringArm3D
@onready var camera: Camera3D = $SpringArm3D/Camera3D
@onready var humanoid: Node3D = $Humanoid


func _enter_tree() -> void:
	# ノード名 = peer_id。生成時（ホスト側/レプリケート側とも）に権威を設定する
	set_multiplayer_authority(String(name).to_int())


func _ready() -> void:
	add_to_group("players")
	$TagArea.body_entered.connect(_on_tag_area_body_entered)
	if is_multiplayer_authority():
		sync_position = position
		sync_yaw = rotation.y
		camera.current = true
		spring_arm.add_excluded_object(get_rid())
		# ④自分のコスチュームを反映する。他ピア分は GameManager.peer_profiles の
		# 同期（RPC）で受け取ってから反映するため、ここでは自分の分のみ
		humanoid.apply_costume(ProfileManager.costume_id, ProfileManager.costume_colors)
	else:
		# スポーン時の同期値へ即座に合わせる。補間に任せると原点から滑って来る
		position = sync_position
		rotation.y = sync_yaw
		# ②④ 相手のコスチュームは GameManager.peer_profiles の同期を待って反映する。
		# 既に届いている場合に備えて即座にも試す（順序はどちらが先でも良い）
		GameManager.profiles_changed.connect(_apply_peer_costume)
		_apply_peer_costume()


## 接触判定はホストが一元的に行う（全ピアで発火するので必ずサーバ判定を挟む）
func _on_tag_area_body_entered(body: Node3D) -> void:
	if multiplayer.is_server():
		GameManager.report_touch(self, body)


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	if not is_multiplayer_authority():
		_follow_sync(delta)
	humanoid.set_diving(diving)
	humanoid.update_motion(sync_speed, not sync_air, delta)
	# ダイブ中は前へ倒れ込む。diving はレプリケートされるので他ピアからも見える
	humanoid.rotation.x = lerpf(humanoid.rotation.x,
		DIVE_PITCH if diving else 0.0, minf(delta * 12.0, 1.0))


## 非権威ピアのみ。同期された位置・向きへ滑らかに寄せる。
## 遠ければ補間せず飛ばす（ワープやラウンド開始のテレポート）
func _follow_sync(delta: float) -> void:
	if position.distance_squared_to(sync_position) > NET_SNAP_DIST * NET_SNAP_DIST:
		position = sync_position
		rotation.y = sync_yaw
		return
	var w := 1.0 - exp(-delta * NET_SMOOTH)
	position = position.lerp(sync_position, w)
	rotation.y = lerp_angle(rotation.y, sync_yaw, w)


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if event is InputEventMouseButton and event.pressed:
		# ブラウザのポインタロックはユーザー操作起点が必須のため、クリックで取得する
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		spring_arm.rotation.x = clampf(
			spring_arm.rotation.x - event.relative.y * MOUSE_SENSITIVITY,
			deg_to_rad(PITCH_MIN), deg_to_rad(PITCH_MAX))


func _physics_process(delta: float) -> void:
	_update_role_visuals()
	if not is_multiplayer_authority():
		return

	buffs.tick(delta)
	warp_lock = maxf(warp_lock - delta, 0.0)
	stun_left = maxf(stun_left - delta, 0.0)
	dive_cooldown = maxf(dive_cooldown - delta, 0.0)
	_tick_dive(delta)

	var my_id := String(name).to_int()
	# 他キャラの頭の上は床として扱わない。ここを接地扱いすると重力が止まり、
	# 相手に乗ったまま空中で静止して落ちてこなくなる（横の押し出しで滑り落とす）
	var grounded := is_on_floor() and not CharacterSeparation.on_character(self)
	# 結果表示中・ヘッドスタート中の鬼・バナナで転倒中・ダイブ中は移動不可
	# （カメラ操作は可能）。ダイブは踏み切った後に軌道を変えられない＝空振りしうる
	var frozen := (GameManager.state == GameManager.State.RESULT
		or stun_left > 0.0 or diving)
	if (GameManager.state == GameManager.State.PLAYING
			and my_id != GameManager.runner_id
			and GameManager.head_start_left > 0.0):
		frozen = true
	if not frozen and Input.is_action_just_pressed("use_item"):
		_use_item()

	if warp_grace > 0.0 or not grounded:
		velocity += get_gravity() * delta
	elif not frozen and dive_cooldown <= 0.0 and Input.is_action_just_pressed("dive"):
		_start_dive()

	var input_dir := Vector2.ZERO
	if not frozen:
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()

	_update_stamina(delta, direction != Vector3.ZERO, frozen)

	var speed := BASE_SPEED * GameManager.get_speed_mult(my_id) * buffs.get_mult(&"speed")
	if is_dashing:
		speed *= DASH_MULT

	# 接地中は即座に目標速度へ。空中では慣性を保ったまま弱く操作する。
	# ジャンプ台やブーストで得た初速が次フレームで消えないようにするため、
	# 空中で入力が無い場合は水平速度に一切手を加えない。
	var target := Vector2(direction.x, direction.z) * speed
	if slide_left > 0.0:
		velocity = SlideMotion.step(velocity, delta, slide_dir, slide_accel, slide_cap,
			SLIDE_STEER, direction, SLIDE_MIN_SPEED)
		floor_snap_length = SLIDE_SNAP
		slide_left = maxf(slide_left - delta, 0.0)
	elif warp_grace > 0.0:
		warp_grace = maxf(warp_grace - delta, 0.0)
		if direction != Vector3.ZERO:
			velocity.x = move_toward(velocity.x, target.x, AIR_ACCEL * delta)
			velocity.z = move_toward(velocity.z, target.y, AIR_ACCEL * delta)
	elif grounded:
		floor_snap_length = 0.1
		var hv := Vector2(velocity.x, velocity.z)
		if hv.length() > speed + 0.5:
			# 通常速度を超えている間は目標速度で上書きせず、摩擦で落とす。
			# ここが無いと滑り台の出口やブーストの勢いが着地の1フレームで消える
			var keep := hv.normalized() * maxf(hv.length() - GROUND_DRAG * delta, speed)
			if target != Vector2.ZERO:
				keep = keep.lerp(target.normalized() * keep.length(),
					minf(STEER_WHILE_FAST * delta, 1.0))
			velocity.x = keep.x
			velocity.z = keep.y
		else:
			velocity.x = target.x
			velocity.z = target.y
	elif direction != Vector3.ZERO:
		velocity.x = move_toward(velocity.x, target.x, AIR_ACCEL * delta)
		velocity.z = move_toward(velocity.z, target.y, AIR_ACCEL * delta)

	# 重なりをほどく速度は carry_velocity と同じく一時的に足すだけにする。
	# velocity に残すと毎フレーム蓄積して吹き飛ぶ
	var separate := CharacterSeparation.push(self)
	velocity += carry_velocity + separate
	move_and_slide()
	velocity -= carry_velocity + separate
	carry_velocity = Vector3.ZERO

	# 歩行モーションは物理の実測値で駆動する。_process 側で位置差分を取ると、
	# 描画が物理より速いフレームで差分が 0 になり Idle と Run がばたつく
	sync_speed = Vector2(velocity.x, velocity.z).length()
	sync_air = not grounded

	if global_position.y < WorldData.FALL_LIMIT:
		teleport(WorldData.zone_center(WorldData.zone_index(global_position)) + Vector3(0, 3, 0))

	# 移動が確定した後に配る。position を直接同期していないので、ここを消すと
	# 他ピアからこのプレイヤーが完全に静止して見える
	sync_position = position
	sync_yaw = rotation.y


## ダイブは「滞空 -> 着地 -> 起き上がり」の3段階。
## diving は最後まで true のままにして、見た目の前傾を起き上がりまで続ける
func _tick_dive(delta: float) -> void:
	if not diving:
		return
	if dive_recover > 0.0:
		dive_recover = maxf(dive_recover - delta, 0.0)
		if dive_recover <= 0.0:
			diving = false
	elif is_on_floor():
		dive_recover = DIVE_RECOVER


## 前方へ低く飛び込む。踏み切った後は操作できない（frozen 扱い）ので、
## 着地までの軌道が読まれると空振りする
func _start_dive() -> void:
	var fwd := -global_transform.basis.z
	velocity = Vector3(fwd.x, 0.0, fwd.z).normalized() * DIVE_SPEED
	velocity.y = DIVE_UP
	diving = true
	dive_recover = 0.0
	dive_cooldown = DIVE_COOLDOWN


func _update_stamina(delta: float, moving: bool, frozen: bool) -> void:
	var wants_dash := Input.is_action_pressed("dash") and moving and not frozen
	is_dashing = wants_dash and not exhausted and stamina > 0.0
	if is_dashing:
		stamina = maxf(stamina - STAMINA_DRAIN * delta, 0.0)
		if stamina <= 0.0:
			exhausted = true
			is_dashing = false
	else:
		stamina = minf(stamina + STAMINA_REGEN * delta, STAMINA_MAX)
		if exhausted and stamina >= STAMINA_RECOVER:
			exhausted = false


## ラウンド開始時に GameManager（RPC 内）から呼ばれる。権威ピア上でのみ有効。
func teleport(pos: Vector3) -> void:
	if not is_multiplayer_authority():
		return
	global_position = pos
	sync_position = position  # 他ピアが次の物理フレームを待たずスナップできるように
	velocity = Vector3.ZERO
	stamina = STAMINA_MAX
	exhausted = false
	buffs.clear()
	warp_lock = 0.0
	warp_grace = 0.0
	slide_left = 0.0
	diving = false
	dive_recover = 0.0
	dive_cooldown = 0.0
	stun_left = 0.0
	item = Item.NONE
	item_changed.emit(item)


## --- 持ち物アイテム -----------------------------------------------------

## ？ブロックから受け取る。1個だけ持てるので、新しく取ると上書きされる
func give_item(id: int) -> void:
	if not is_multiplayer_authority():
		return
	item = id
	item_changed.emit(item)


func _use_item() -> void:
	match item:
		Item.ROCKET:
			var fwd := -global_transform.basis.z
			launch(Vector3(fwd.x, 0.0, fwd.z).normalized() * ROCKET_FORWARD
				+ Vector3(0, ROCKET_UP, 0))
		Item.BANANA:
			var back := global_transform.basis.z
			_request_drop(Item.BANANA,
				global_position + Vector3(back.x, 0.0, back.z).normalized() * BANANA_BEHIND)
		Item.BLOCK:
			var ahead := -global_transform.basis.z
			_request_drop(Item.BLOCK,
				global_position + Vector3(ahead.x, 0.0, ahead.z).normalized() * BLOCK_AHEAD)
		_:
			return
	item = Item.NONE
	item_changed.emit(item)


## 置き物の生成はサーバに一任する。クライアントが自前で生成しても
## MultiplayerSpawner を通らず他ピアへ同期されないため。
## 自分がサーバなら rpc_id(1) のセルフ配信に頼らず直接呼ぶ
func _request_drop(kind: int, pos: Vector3) -> void:
	if multiplayer.is_server():
		GameManager.request_drop(kind, pos, rotation.y)
	else:
		GameManager.request_drop.rpc_id(1, kind, pos, rotation.y)


## --- ギミックから呼ばれる API ------------------------------------------
## いずれも「そのボディの権威ピア」でのみ適用する。
## 移動結果は既存の位置レプリケーションで他ピアへ伝わるため RPC は不要。

## ジャンプ台などの打ち上げ。y は上書き、水平は加算
func launch(v: Vector3) -> void:
	if not is_multiplayer_authority():
		return
	if v.y != 0.0:
		velocity.y = v.y
	velocity.x += v.x
	velocity.z += v.z


## 土管ワープ。着地先の土管で即座に再ワープしないよう warp_lock を張る。
## exit_kick は水平方向の勢い（warp_pipe.gd 側で「進行方向」から作る）。
## これが無いと無操作時に真上へ飛んで同じ場所へ落ち、口に戻って再突入する
func warp_to(pos: Vector3, up_vel: float, exit_kick := Vector3.ZERO) -> void:
	if not is_multiplayer_authority():
		return
	global_position = pos
	velocity = Vector3(exit_kick.x, up_vel, exit_kick.z)
	warp_lock = 0.9
	warp_grace = WARP_GRACE
	slide_left = 0.0  # 滑走状態のまま飛ぶと出口で明後日の方向へ加速する
	effect_gained.emit(Effect.WARP)


func apply_boost(mult: float, dur: float, kick: Vector3) -> void:
	if not is_multiplayer_authority():
		return
	buffs.add(&"speed", mult, dur)
	velocity.x += kick.x
	velocity.z += kick.z
	effect_gained.emit(Effect.BOOST)


## 動く床・回転床が毎フレーム乗客に渡す搬送速度
func add_carry(v: Vector3) -> void:
	carry_velocity += v


## 滑り台が毎フレーム呼ぶ。呼ばれている間だけ滑走状態になり、
## 接地していても通常の移動制御（目標速度への上書き）を止める。
## 権威チェックは add_carry() と同じく呼び出し側（Area）が行う
func apply_slide(dir: Vector3, accel: float, cap: float) -> void:
	slide_dir = dir
	slide_accel = accel
	slide_cap = cap
	slide_left = SLIDE_GRACE


## バナナを踏んだ時の転倒
func apply_stun(seconds: float) -> void:
	if not is_multiplayer_authority():
		return
	stun_left = maxf(stun_left, seconds)
	velocity.x = 0.0
	velocity.z = 0.0
	effect_gained.emit(Effect.STUN)


## 役割に応じた体色の反映（全ピアで実行）
func _update_role_visuals() -> void:
	var my_id := String(name).to_int()
	var color := COLOR_WAITING
	if GameManager.state == GameManager.State.WAITING:
		# 準備中も立候補者だけ緑にして、誰が逃げる役かゲーム内で分かるようにする
		if my_id == GameManager.wanted_runner:
			color = COLOR_RUNNER
	else:
		color = COLOR_RUNNER if my_id == GameManager.runner_id else COLOR_HUNTER
	if color != _current_color:
		_current_color = color
		humanoid.set_role_color(color)


## ②④ 他ピア（自分以外）のコスチュームを GameManager.peer_profiles から反映する
func _apply_peer_costume() -> void:
	var peer_id := String(name).to_int()
	if not GameManager.peer_profiles.has(peer_id):
		return
	var info: Dictionary = GameManager.peer_profiles[peer_id]
	var colors := ProfileManager.colors_from_html(info.get("colors", []))
	humanoid.apply_costume(StringName(info.get("costume", "default")), colors)
