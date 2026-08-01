extends Node3D

## かわいいシンプルなちびキャラ（プリミティブ製・全長約0.9m）。
## プレイヤーと CPU 鬼で共用。移動速度に応じて腕と脚を滑らかに振る。
## 役割色（Runner=緑 / Hunter=赤 / 待機=灰）は体色に反映する。

const SWING_FREQ := 2.6   # 速度に対する振りサイクルの係数
const SWING_MAX := 1.0    # 最大振り幅（rad）
const RUN_SPEED := 10.5   # この速度で振り幅が最大になる（＝ダッシュ速度）

var _speed := 0.0
var _on_floor := true
var _phase := 0.0
var _amp := 0.0

var _mat_body := StandardMaterial3D.new()
var _mat_head := StandardMaterial3D.new()

@onready var arm_l: Node3D = $ArmL
@onready var arm_r: Node3D = $ArmR
@onready var leg_l: Node3D = $LegL
@onready var leg_r: Node3D = $LegR


func _ready() -> void:
	$Head.material_override = _mat_head
	$Body.material_override = _mat_body
	for pivot in [arm_l, arm_r, leg_l, leg_r]:
		pivot.get_node("Mesh").material_override = _mat_body
	set_color(Color(0.5, 0.55, 0.6))


## 広くてカラフルなマップで床に埋もれないよう、体色は弱く自己発光させる
func set_color(color: Color) -> void:
	_tint(_mat_body, color)
	_tint(_mat_head, color.lightened(0.35))


func _tint(mat: StandardMaterial3D, color: Color) -> void:
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.35


## 親（player / cpu_hunter）が毎フレーム水平速度と接地状態を渡す
func update_motion(speed: float, on_floor: bool) -> void:
	_speed = speed
	_on_floor = on_floor


func _process(delta: float) -> void:
	# 振り幅は速度に比例させ、補間で滑らかに変化させる
	var target_amp := clampf(_speed / RUN_SPEED, 0.0, 1.0) * SWING_MAX
	if not _on_floor:
		target_amp = 0.25
	_amp = lerpf(_amp, target_amp, minf(delta * 10.0, 1.0))
	_phase += _speed * delta * SWING_FREQ
	var swing := sin(_phase) * _amp
	arm_l.rotation.x = swing
	arm_r.rotation.x = -swing
	leg_l.rotation.x = -swing * 0.9
	leg_r.rotation.x = swing * 0.9
