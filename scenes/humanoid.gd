extends Node3D

## KayKit Adventurers の Knight（CC0）を使った人型キャラクター表示。
## プレイヤーと CPU 鬼で共用。移動速度に応じて Idle / Walk / Run / 空中 を
## 切り替え、役割色（Runner=緑 / Hunter=赤 / 待機=灰）は material_overlay で反映する。

const WALK_THRESHOLD := 0.5
const RUN_THRESHOLD := 6.5
const LOOP_ANIMS: Array[String] = ["Idle", "Walking_A", "Running_A", "Jump_Idle"]

var _anim: AnimationPlayer
var _overlay := StandardMaterial3D.new()
var _current_anim := ""


func _ready() -> void:
	_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_overlay.albedo_color = Color(1, 1, 1, 0)
	for mesh in find_children("*", "MeshInstance3D", true, false):
		mesh.material_overlay = _overlay
	_anim = find_child("AnimationPlayer", true, false)
	if _anim:
		# glTF 由来のアニメーションはループ設定されていないため実行時に付与する
		for anim_name in LOOP_ANIMS:
			if _anim.has_animation(anim_name):
				_anim.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR
		_play("Idle")


func set_color(color: Color) -> void:
	_overlay.albedo_color = Color(color.r, color.g, color.b, 0.45)


## 親（player / cpu_hunter）が毎フレーム水平速度と接地状態を渡す
func update_motion(speed: float, on_floor: bool) -> void:
	if not on_floor:
		_play("Jump_Idle")
	elif speed >= RUN_THRESHOLD:
		_play("Running_A")
	elif speed >= WALK_THRESHOLD:
		_play("Walking_A")
	else:
		_play("Idle")


func _play(anim_name: String) -> void:
	if _anim == null or anim_name == _current_anim:
		return
	if _anim.has_animation(anim_name):
		_current_anim = anim_name
		_anim.play(anim_name, 0.2)
