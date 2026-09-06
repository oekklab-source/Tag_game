class_name Player
extends CharacterBody3D

const STUCK_ESCAPE := preload("res://scenes/stuck_escape.gd")

## プレイヤーキャラクター。
## 自分が権威を持つインスタンスのみ入力・物理を処理し、
## 位置と回転は MultiplayerSynchronizer が他ピアへ配信する。

## トースト表示用の出来事 ID（hud.gd と共有）
enum Effect { BOOST, WARP, STUN }

## 持ち物アイテム（question_block.gd / hud.gd と共有）。1個だけ持てる
enum Item { NONE, ROCKET, BANANA, BLOCK }

## エモート（hud.gd / humanoid.gd と共有）。文言は固定で、状況で自動的に決まる。
## humanoid.gd の EMOTE_ANIM がこの数値をクリップ名に対応させているので、
## 値を並べ替えたら向こうも直すこと
enum Emote { NONE, NICE, COME }

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
## 転倒中の減速 /秒。通常速度 7.0 m/s なら約0.8秒・約2.7m 尻で滑ってから止まる
const SLIP_DRAG := 9.0

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
const BANANA_BEHIND := 3.0    # 足元の後ろこの距離に置く
const BLOCK_BEHIND := 3.0     # バナナと同じ距離。カメラ干渉は壁側を除外して防ぐ
const BANANA_THROW_SPAWN := 1.2
const BANANA_THROW_FORWARD := 8.55  # 以前の5.7m/sの1.5倍
const BANANA_THROW_UP := 7.47       # 投げバナナ用重力と合わせて最高点を約4mにする
const BANANA_CARRY_RATIO := 0.5     # 投げた瞬間の自キャラ速度を全方向とも半分加える
## 取得直後のルーレット時間。この間は中身が確定しておらず使えない（HUD が回して見せる）
const ITEM_ROULETTE := 1.2

## --- エモート -----------------------------------------------------------
## 唯一の意思疎通の手段。文言は固定で、待機中は「ナイス！」、ラウンド中は「カモン！」に
## 自動で決まるので操作は F の1キーだけ。移動は止めない（凍結中の鬼も出せる）
const EMOTE_TIME := 2.4      # 吹き出し・モーション・マップの光が出ている長さ
const EMOTE_COOLDOWN := 3.0  # 連打で撒き散らせないようにする
const EMOTE_TEXT := {
	Emote.NICE: "ナイス！",
	Emote.COME: "カモン！",
}
const EMOTE_COLOR := {
	Emote.NICE: Color(0.45, 1.0, 0.65),
	Emote.COME: Color(1.0, 0.85, 0.3),
}

const COLOR_WAITING := Color(0.62, 0.66, 0.72)
const COLOR_RUNNER := Color(0.2, 1.0, 0.45)
const COLOR_HUNTER := Color(1.0, 0.18, 0.22)

## --- リモートピアの補間 -------------------------------------------------
## インターネット越しでは到着間隔がばらつくので、同期値を直接 position に入れると
## その揺らぎがそのまま見える。exp 減衰なのでフレームレートには依存しない。
## 25 は MultiplayerSynchronizer の replication_interval(0.05) と釣り合う値
## （定常的な遅れ ≒ 速度/25 ≒ 同期1回分の移動量）。上げるほど追従が速く、荒くなる
const NET_SMOOTH := 25.0
## これ以上離れていたら補間せず飛ばす。teleport・マンホールワープ・落下復帰で
## 画面を横切って滑っていくのを防ぐ
const NET_SNAP_DIST := 5.0

var stamina := STAMINA_MAX
var exhausted := false
var is_dashing := false
var buffs := BuffSet.new()
var carry_velocity := Vector3.ZERO  # 動く床から毎フレーム渡される搬送速度
var bumper_bounce_velocity := Vector3.ZERO
var bumper_bounce_left := 0.0
var slide_dir := Vector3.ZERO       # 滑り台から毎フレーム渡される最急降下方向
var slide_accel := 0.0
var slide_cap := 0.0
var slide_left := 0.0               # >0 の間だけ滑走状態
## 滞空から起き上がりまでの全体。見た目の前傾に使うのでレプリケートする
var diving := false
var dive_recover := 0.0
var dive_cooldown := 0.0
var warp_lock := 0.0                # マンホールの往復ワープ防止
var warp_grace := 0.0               # ワープ直後、is_on_floor() の古い値を無視する猶予
var item: int = Item.NONE
var item_lock := 0.0                # >0 の間はルーレット中で、まだ使えない
var stun_left := 0.0                # バナナを踏んだ時の操作不能時間
## 転んでいる最中か。見た目の Slip モーションに使うのでレプリケートする
## （stun_left は権威ピアしか持っていないので、そのままでは他ピアで棒立ちになる）
var stunned := false
var emote_left := 0.0               # 権威ピアのみ。0 になったら sync_emote を戻す
var emote_cooldown := 0.0           # 権威ピアのみ

## 壁の角に押し付けられて動けなくなった時の検知・脱出用。
## cpu_hunter.gd / cpu_runner.gd と同じ stuck_escape.gd を共有する
var _stuck_timer := 0.0
var _stuck_from := Vector3.ZERO
var _stuck_kick := Vector3.ZERO
var _stuck_kick_left := 0.0

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
## 味方ハンターの頭上ラベルに使うニックネーム。権威ピアが PlayerPrefs から一度だけ書く
@export var sync_nickname := ""
## 出しているエモート（Emote の値）。0 = 出していない。
## 終わるたび必ず 0 を挟むので、同じエモートを繰り返しても ON_CHANGE の同期が発火する
@export var sync_emote: int = Emote.NONE

var _current_color := Color.TRANSPARENT
var _camera_block_rids := {}

@onready var spring_arm: SpringArm3D = $SpringArm3D
@onready var camera: Camera3D = $SpringArm3D/Camera3D
@onready var humanoid: Node3D = $Humanoid
@onready var name_label: Label3D = $NameLabel
@onready var emote_label: Label3D = $EmoteLabel


func _enter_tree() -> void:
	# ノード名 = peer_id。生成時（ホスト側/レプリケート側とも）に権威を設定する
	set_multiplayer_authority(String(name).to_int())


func _ready() -> void:
	add_to_group("players")
	$TagArea.body_entered.connect(_on_tag_area_body_entered)
	if is_multiplayer_authority():
		sync_position = position
		sync_yaw = rotation.y
		sync_nickname = PlayerPrefs.nickname
		camera.current = true
		spring_arm.add_excluded_object(get_rid())
	else:
		# スポーン時の同期値へ即座に合わせる。補間に任せると原点から滑って来る
		position = sync_position
		rotation.y = sync_yaw


## 接触判定はホストが一元的に行う（全ピアで発火するので必ずサーバ判定を挟む）
func _on_tag_area_body_entered(body: Node3D) -> void:
	if multiplayer.is_server():
		GameManager.report_touch(self, body)


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	if not is_multiplayer_authority():
		_follow_sync(delta)
	else:
		_update_placed_block_camera()
	humanoid.set_diving(diving)
	humanoid.set_stunned(stunned)
	humanoid.set_emote(sync_emote)
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
	_update_name_label()
	_update_emote_label()
	if not is_multiplayer_authority():
		return

	# エモートは frozen の判定より前。凍っている鬼も、転んでいる最中も出せる。
	# dive / use_item と同じく _unhandled_input ではなくここで拾うのは、
	# 「押しっぱなしの間だけ有効」ではないものを物理フレームの粒度で揃えるため
	_tick_emote(delta)
	if Input.is_action_just_pressed("emote"):
		_start_emote()
	buffs.tick(delta)
	warp_lock = maxf(warp_lock - delta, 0.0)
	stun_left = maxf(stun_left - delta, 0.0)
	# 終わるたび必ず false を挟むので、続けて2回転んでも ON_CHANGE の同期が発火する
	stunned = stun_left > 0.0
	dive_cooldown = maxf(dive_cooldown - delta, 0.0)
	item_lock = maxf(item_lock - delta, 0.0)
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

	_update_stuck(delta, direction, grounded, frozen)
	_update_stamina(delta, direction != Vector3.ZERO, frozen)
	var holding_bumper_bounce := bumper_bounce_left > 0.0
	bumper_bounce_left = maxf(bumper_bounce_left - delta, 0.0)

	var speed := BASE_SPEED * GameManager.get_speed_mult(my_id) * buffs.get_mult(&"speed")
	if is_dashing:
		speed *= DASH_MULT

	# 接地中は即座に目標速度へ。空中では慣性を保ったまま弱く操作する。
	# ジャンプ台やブーストで得た初速が次フレームで消えないようにするため、
	# 空中で入力が無い場合は水平速度に一切手を加えない。
	var target := Vector2(direction.x, direction.z) * speed
	if holding_bumper_bounce:
		velocity.x = bumper_bounce_velocity.x
		velocity.z = bumper_bounce_velocity.z
	elif slide_left > 0.0:
		velocity = SlideMotion.step(velocity, delta, slide_dir, slide_accel, slide_cap,
			SLIDE_STEER, direction, SLIDE_MIN_SPEED)
		floor_snap_length = SLIDE_SNAP
		slide_left = maxf(slide_left - delta, 0.0)
	elif warp_grace > 0.0:
		warp_grace = maxf(warp_grace - delta, 0.0)
		if direction != Vector3.ZERO:
			velocity.x = move_toward(velocity.x, target.x, AIR_ACCEL * delta)
			velocity.z = move_toward(velocity.z, target.y, AIR_ACCEL * delta)
	elif stun_left > 0.0 and grounded:
		# 転倒中は入力が無いので、通常の接地処理だと目標速度ゼロで即座に止まる。
		# 摩擦だけで落として「足をすくわれて尻で滑る」勢いを残す
		floor_snap_length = 0.1
		var slip := Vector2(velocity.x, velocity.z).move_toward(Vector2.ZERO, SLIP_DRAG * delta)
		velocity.x = slip.x
		velocity.z = slip.y
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


## --- エモート -----------------------------------------------------------

## F キー。文言は状況で決まるので選ぶ操作は無い。
## 出している最中とクールダウン中は受け付けない
func _start_emote() -> void:
	if emote_left > 0.0 or emote_cooldown > 0.0:
		return
	sync_emote = _emote_for_state()
	emote_left = EMOTE_TIME
	emote_cooldown = EMOTE_COOLDOWN


## ラウンド中は仲間を呼ぶ「カモン」、それ以外（待機中・リザルト）は「ナイス」
func _emote_for_state() -> int:
	return Emote.COME if GameManager.state == GameManager.State.PLAYING else Emote.NICE


func _tick_emote(delta: float) -> void:
	emote_cooldown = maxf(emote_cooldown - delta, 0.0)
	if emote_left <= 0.0:
		return
	emote_left = maxf(emote_left - delta, 0.0)
	if emote_left <= 0.0:
		sync_emote = Emote.NONE


## 頭上の吹き出し（全ピアで実行）。
##
## ラウンド中は**見る側と出す側が同じ側のときだけ**表示する。
## ここを緩めると逃走者のエモートが鬼の画面に出て、視認していないのに位置が割れる。
## 待機中とリザルト中はまだ／もう陣営が無いので全員に見せる
func _update_emote_label() -> void:
	if sync_emote == Emote.NONE:
		emote_label.visible = false
		return
	var visible_to_me := true
	if GameManager.state == GameManager.State.PLAYING:
		var my_id := String(name).to_int()
		var local_id := multiplayer.get_unique_id()
		visible_to_me = (my_id != GameManager.runner_id) == (local_id != GameManager.runner_id)
	emote_label.visible = visible_to_me
	if not visible_to_me:
		return
	emote_label.text = EMOTE_TEXT[sync_emote]
	emote_label.modulate = EMOTE_COLOR[sync_emote]


## 壁の角に押し付けられて move_and_slide() が動けなくなった時の脱出。
## 移動しようとしている(direction != ZERO)のにほとんど動けていない状態を検知し、
## 直前の衝突法線から離れる向きへ一時的にキックする。cpu_hunter.gd の
## _avoid_stuck と同じ判断だが、逃走者にはナビ目標が無いので入力方向で見る
func _update_stuck(delta: float, direction: Vector3, grounded: bool, frozen: bool) -> void:
	if _stuck_kick_left > 0.0:
		add_carry(_stuck_kick)
		_stuck_kick_left -= delta
	if frozen or not grounded or direction == Vector3.ZERO \
			or slide_left > 0.0 or warp_grace > 0.0:
		_stuck_timer = 0.0
		_stuck_from = global_position
		return
	_stuck_timer += delta
	if _stuck_timer < STUCK_ESCAPE.STUCK_TIME:
		return
	var moved := Vector2(global_position.x - _stuck_from.x,
		global_position.z - _stuck_from.z).length()
	_stuck_timer = 0.0
	_stuck_from = global_position
	if moved >= STUCK_ESCAPE.STUCK_DIST:
		return
	var kick := STUCK_ESCAPE.normal_kick(self, BASE_SPEED)
	if kick != Vector3.ZERO:
		_stuck_kick = kick
		_stuck_kick_left = STUCK_ESCAPE.KICK_TIME


func _update_stamina(delta: float, moving: bool, frozen: bool) -> void:
	var stamina_max := GameManager.stamina_max_for(String(name).to_int())
	var wants_dash := Input.is_action_pressed("dash") and moving and not frozen
	is_dashing = wants_dash and not exhausted and stamina > 0.0
	if is_dashing:
		stamina = maxf(stamina - STAMINA_DRAIN * delta, 0.0)
		if stamina <= 0.0:
			exhausted = true
			is_dashing = false
	else:
		stamina = minf(stamina + STAMINA_REGEN * delta, stamina_max)
		if exhausted and stamina >= STAMINA_RECOVER:
			exhausted = false


func stamina_max() -> float:
	return GameManager.stamina_max_for(String(name).to_int())


## ラウンド開始時に GameManager（RPC 内）から呼ばれる。権威ピア上でのみ有効。
func teleport(pos: Vector3) -> void:
	if not is_multiplayer_authority():
		return
	global_position = pos
	sync_position = position  # 他ピアが次の物理フレームを待たずスナップできるように
	velocity = Vector3.ZERO
	bumper_bounce_left = 0.0
	stamina = stamina_max()
	exhausted = false
	buffs.clear()
	warp_lock = 0.0
	warp_grace = 0.0
	slide_left = 0.0
	diving = false
	dive_recover = 0.0
	dive_cooldown = 0.0
	stun_left = 0.0
	stunned = false
	item = Item.NONE
	item_lock = 0.0
	item_changed.emit(item)
	sync_emote = Emote.NONE  # ラウンドをまたいで吹き出しを残さない
	emote_left = 0.0
	emote_cooldown = 0.0
	_stuck_from = global_position
	_stuck_kick_left = 0.0


## --- 持ち物アイテム -----------------------------------------------------

## ？ブロックから受け取る。1個だけ持てるので、新しく取ると上書きされる。
## 中身は ITEM_ROULETTE 秒かけて確定する演出にするため、その間は使用も止める
## （見た目だけ回して裏では即使える、という食い違いを作らない）
func give_item(id: int) -> void:
	if not is_multiplayer_authority():
		return
	item = id
	item_lock = ITEM_ROULETTE
	item_changed.emit(item)


func _use_item() -> void:
	if item_lock > 0.0:
		return  # ルーレットが回りきるまでは中身が確定していない
	match item:
		Item.ROCKET:
			var fwd := -global_transform.basis.z
			launch(Vector3(fwd.x, 0.0, fwd.z).normalized() * ROCKET_FORWARD
				+ Vector3(0, ROCKET_UP, 0))
		Item.BANANA:
			if _is_hunter_for_items():
				var fwd := -global_transform.basis.z
				fwd = Vector3(fwd.x, 0.0, fwd.z).normalized()
				_request_drop(Item.BANANA,
					global_position + fwd * BANANA_THROW_SPAWN + Vector3.UP,
					fwd * BANANA_THROW_FORWARD + Vector3.UP * BANANA_THROW_UP
						+ velocity * BANANA_CARRY_RATIO)
			else:
				var back := global_transform.basis.z
				_request_drop(Item.BANANA,
					global_position + Vector3(back.x, 0.0, back.z).normalized() * BANANA_BEHIND)
		Item.BLOCK:
			var back := global_transform.basis.z
			_request_drop(Item.BLOCK,
				global_position + Vector3(back.x, 0.0, back.z).normalized() * BLOCK_BEHIND)
		_:
			return
	item = Item.NONE
	item_changed.emit(item)


## 置き物の生成はサーバに一任する。クライアントが自前で生成しても
## MultiplayerSpawner を通らず他ピアへ同期されないため。
## 自分がサーバなら rpc_id(1) のセルフ配信に頼らず直接呼ぶ
func _request_drop(kind: int, pos: Vector3, launch_velocity := Vector3.ZERO) -> void:
	if multiplayer.is_server():
		GameManager.request_drop(kind, pos, rotation.y, launch_velocity)
	else:
		GameManager.request_drop.rpc_id(1, kind, pos, rotation.y, launch_velocity)


func _is_hunter_for_items() -> bool:
	var my_id := String(name).to_int()
	if GameManager.state == GameManager.State.WAITING:
		return my_id != GameManager.wanted_runner
	return my_id != GameManager.runner_id


## 置き壁は通行と視線判定には残し、ローカルの三人称カメラだけ通過させる。
## 壁自身がカメラと注視点の間にあるかを判定し、必要な間だけ半透明にする。
func _update_placed_block_camera() -> void:
	var live := {}
	for node in get_tree().get_nodes_in_group("placed_blocks"):
		if not node is CollisionObject3D:
			continue
		var block := node as CollisionObject3D
		var id := block.get_instance_id()
		live[id] = true
		register_placed_block_camera(block)

	for id in _camera_block_rids.keys():
		if not live.has(id):
			spring_arm.remove_excluded_object(_camera_block_rids[id])
			_camera_block_rids.erase(id)


func register_placed_block_camera(block: CollisionObject3D) -> void:
	if not is_multiplayer_authority():
		return
	var id := block.get_instance_id()
	if not _camera_block_rids.has(id):
		var rid := block.get_rid()
		spring_arm.add_excluded_object(rid)
		_camera_block_rids[id] = rid
	if block.has_method("update_camera_obscured"):
		# Camera3D の位置は SpringArm の内部更新より前だと前フレームの値になる。
		# アームの向きから本来の4m位置を直接作り、更新順に依存させない。
		var target := spring_arm.global_position
		var desired_camera := target \
			+ spring_arm.global_transform.basis.z.normalized() * spring_arm.spring_length
		block.update_camera_obscured(target, desired_camera)


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
	_stuck_from = global_position
	_stuck_kick_left = 0.0


## バンパー反動の間だけ、ダッシュ・ブースト由来の目標速度で押し戻されないようにする。
## 視点操作や上方向の物理は止めず、操作不能状態は作らない。
func hold_bumper_bounce(horizontal: Vector3, duration: float) -> void:
	if not is_multiplayer_authority():
		return
	bumper_bounce_velocity = horizontal
	bumper_bounce_left = duration


## マンホールのワープ。着地先で即座に再ワープしないよう warp_lock を張る。
## exit_kick は水平方向の勢い（manhole.gd 側で「進行方向」から作る）。
## これが無いと無操作時に真上へ飛んで同じ場所へ落ち、フタへ戻って再突入する
func warp_to(pos: Vector3, up_vel: float, exit_kick := Vector3.ZERO) -> void:
	if not is_multiplayer_authority():
		return
	global_position = pos
	velocity = Vector3(exit_kick.x, up_vel, exit_kick.z)
	bumper_bounce_left = 0.0
	warp_lock = 0.9
	warp_grace = WARP_GRACE
	slide_left = 0.0  # 滑走状態のまま飛ぶと出口で明後日の方向へ加速する
	_stuck_from = global_position
	_stuck_kick_left = 0.0
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
	stunned = true
	# 水平速度はここで殺さない。走っていた勢いのまま尻で滑らせる（SLIP_DRAG で減速する）
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
		humanoid.set_color(color)


## 頭上の名前ラベル。逃走者には見せない（味方ハンター同士にのみ表示する）。
## WAITING 中は runner_id が未確定(-1)なので、PLAYING に限定して誤表示を避ける
func _update_name_label() -> void:
	var my_id := String(name).to_int()
	var local_id := multiplayer.get_unique_id()
	var playing := GameManager.state == GameManager.State.PLAYING
	var viewer_is_hunter := playing and local_id != GameManager.runner_id
	var target_is_hunter := playing and my_id != GameManager.runner_id
	name_label.visible = viewer_is_hunter and target_is_hunter and my_id != local_id
	if not sync_nickname.is_empty() and name_label.text != sync_nickname:
		name_label.text = sync_nickname
