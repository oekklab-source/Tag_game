extends Area3D

## ダッシュパネル。踏むと一定時間スピードアップし、パネルの向き（-Z）へ蹴り出す。
## 逃走者も鬼も同じように使える対称ギミック。

const BOOST_MULT := 1.6
const BOOST_TIME := 2.5
const KICK := 4.0
const PULSE_MIN := 0.9
const PULSE_MAX := 2.0

var _mat: StandardMaterial3D

@onready var arrow: MeshInstance3D = $Arrow


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	# 脈動は共有リソースを避けてインスタンス固有のマテリアルで行う
	_mat = arrow.mesh.material.duplicate()
	arrow.material_override = _mat


func _process(_delta: float) -> void:
	var t := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.006)
	_mat.emission_energy_multiplier = lerpf(PULSE_MIN, PULSE_MAX, t)


func _on_body_entered(body: Node3D) -> void:
	if not body.has_method("apply_boost") or not body.is_multiplayer_authority():
		return
	var fwd := -global_transform.basis.z
	var kick := Vector3(fwd.x, 0.0, fwd.z).normalized() * KICK
	body.apply_boost(BOOST_MULT, BOOST_TIME, kick)
