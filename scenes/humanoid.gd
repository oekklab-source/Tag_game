extends Node3D

## Blender 製の Fall Guys 風ちびキャラ（元データ: tools/blender/fallguy.blend）。
## プレイヤーと CPU 鬼で共用。移動速度・接地・ダイブ状態からアニメを切り替える。
## 役割色（Runner=緑 / Hunter=赤 / 待機=灰）は体色に反映する。

const RUN_SPEED := 10.5   # この速度で走りアニメが等倍になる（＝ダッシュ速度）
const WALK_MIN := 0.6     # これ以下は止まっているとみなす
const BLEND := 0.15       # アニメ切り替えのクロスフェード秒
const LOOPING := ["Idle", "Run", "Jump"]

var _mat_body := StandardMaterial3D.new()
var _diving := false
var _state := ""

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


## 親（player / cpu_hunter）が毎フレーム水平速度と接地状態を渡す
func update_motion(speed: float, on_floor: bool) -> void:
	if _diving:
		_play("Dive")
		return
	if not on_floor:
		_play("Jump")
	elif speed > WALK_MIN:
		_play("Run")
		# 遅いときは足がすべって見えないよう再生速度も落とす
		_anim.speed_scale = clampf(speed / RUN_SPEED, 0.6, 1.6)
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
	_anim.speed_scale = 1.0
	_anim.play(anim_name, BLEND)
