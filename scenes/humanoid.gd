extends Node3D

## ブロック調の人型モデル。プレイヤーと CPU 鬼で共用し、
## 役割色（Runner=緑 / Hunter=赤 / 待機=灰）を set_color で一括反映する。

var _mat := StandardMaterial3D.new()


func _ready() -> void:
	for part in [$Head, $Torso, $ArmL, $ArmR, $LegL, $LegR]:
		part.material_override = _mat


func set_color(color: Color) -> void:
	_mat.albedo_color = color
