extends Node3D

## Blender 製の Fall Guys 風ちびキャラ（元データ: tools/blender/fallguy.blend）。
## プレイヤーと CPU 鬼で共用。移動速度・接地・ダイブ状態からアニメを切り替える。
## 役割色（Runner=緑 / Hunter=赤 / 待機=灰）は体色に反映する。

## Run アニメを等倍で再生したとき、キャラが実際に歩く速度。
## 1周期 0.8秒で 1周期ぶんの歩幅を進むので、この値で割った倍率で再生すれば
## 「足が地面を蹴った距離」と「実際に進んだ距離」が一致する（＝足がすべらない）。
##
## この値は手計算せず tests/anim_stride.tscn で実測する。
## ボーンのローカル軸は Blender と glTF で向きが変わるため、
## ポーズの角度から求めようとすると必ず間違える
const NATURAL_SPEED := 2.42

## 再生倍率の上限。歩幅は脚の長さで頭打ちになる（このキャラは全高1.74mで
## 脚は0.56mしかない）ので、10.5m/s のダッシュに完全に比例させると
## 毎秒11歩になって脚がブレる。ここで頭打ちにした分だけ足はすべる。
##
## 通常速度 7.0m/s に必要な倍率は 2.90 なので、歩き・走りでは足はすべらない。
## すべるのはダッシュ中だけ（必要 4.35 に対して 3.6 = 約2割）
const SCALE_MAX := 3.6
const SCALE_MIN := 0.55

## Idle と Run を行き来する閾値。行きと戻りで差を付けないと、
## 閾値ぎわで毎フレーム切り替わってガタガタになる
const WALK_ENTER := 0.9
const WALK_EXIT := 0.45

## 速度の平滑化 /秒。ネットワーク越しの推定値は到着間隔のばらつきで跳ねるので、
## そのまま再生倍率にすると脚の回転が痙攣する。exp 減衰なのでフレームレート非依存
const SPEED_SMOOTH := 14.0

const BLEND := 0.15  # アニメ切り替えのクロスフェード秒
const LOOPING := ["Idle", "Run", "Jump"]

var _mat_body := StandardMaterial3D.new()
var _diving := false
var _state := ""
var _speed := 0.0

@onready var _anim: AnimationPlayer = $Model.find_child("AnimationPlayer", true, false)
@onready var _body: MeshInstance3D = $Model.find_child("Body", true, false)


func _ready() -> void:
	# glTF のアニメは既定でワンショット扱いなので、ループするものだけ設定し直す
	for anim_name in LOOPING:
		var anim := _anim.get_animation(anim_name)
		if anim:
			anim.loop_mode = Animation.LOOP_LINEAR
	_body.material_override = _mat_body
	set_color(Color(0.5, 0.55, 0.6))
	_play("Idle")


## 色を変えるのは体だけ。ニット帽とビブは元の配色のまま残して衣装らしさを保つ
## （体が最大面積なので役割色はこれだけで十分読み取れる）。
## 広くてカラフルなマップで床に埋もれないよう、体色は弱く自己発光させる
func set_color(color: Color) -> void:
	_mat_body.albedo_color = color
	_mat_body.emission_enabled = true
	_mat_body.emission = color
	_mat_body.emission_energy_multiplier = 0.35


## 親（player / cpu_hunter）が毎フレーム水平速度と接地状態を渡す。
##
## speed は「実際の velocity（権威ピア）」か「同期値の変化から求めた推定（他ピア）」。
## 描画フレームごとの位置差分から出してはいけない。描画が物理より速いと
## 差分ゼロのフレームが混ざり、Idle と Run が交互に出てガタガタになる
func update_motion(speed: float, on_floor: bool, delta: float) -> void:
	_speed = lerpf(_speed, speed, 1.0 - exp(-delta * SPEED_SMOOTH))
	if _diving:
		_play("Dive")
		return
	if not on_floor:
		_play("Jump")
		return
	# 立ち止まる閾値だけ低くして、境目での往復を防ぐ
	if _speed > (WALK_EXIT if _state == "Run" else WALK_ENTER):
		_play("Run")
		_anim.speed_scale = clampf(_speed / NATURAL_SPEED, SCALE_MIN, SCALE_MAX)
	else:
		_play("Idle")


## ダイブ中は速度・接地に関係なくダイブ姿勢を優先する。
## 体の前傾そのものは親が Humanoid ごと rotation.x を倒して作る
func set_diving(value: bool) -> void:
	_diving = value


func _play(anim_name: String) -> void:
	if _state == anim_name:
		return
	_state = anim_name
	# speed_scale は AnimationPlayer 全体に効くので、Run 以外へ移る時に必ず戻す
	_anim.speed_scale = 1.0
	_anim.play(anim_name, BLEND)
