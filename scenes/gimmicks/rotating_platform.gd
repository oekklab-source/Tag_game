extends AnimatableBody3D

## 回転床。GARDEN GREEN の飛び石。
##
## Godot は回転する床に乗った CharacterBody3D を一緒には回さない
## （プラットフォーム速度として拾われるのは並進のみ）。そのため上面の Area3D で
## 乗客を拾い、回転による接線速度を add_carry() で毎フレーム渡している。
## 結果として「円周上を運ばれるが自分の向きは変わらない」挙動になる。

@export var spin := 0.6  # rad/s


func _physics_process(_delta: float) -> void:
	rotation.y = GameManager.world_time * spin
	var omega := Vector3(0, spin, 0)
	for b in $Rider.get_overlapping_bodies():
		if b.has_method("add_carry"):
			var r: Vector3 = b.global_position - global_position
			b.add_carry(omega.cross(Vector3(r.x, 0.0, r.z)))
