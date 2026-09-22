class_name RespawnBirds
extends Node3D

## 承認済み試作と同じ3羽。演出のみで衝突判定を持たない。
var birds: Array[Node3D] = []


func _ready() -> void:
	var yellow := _material(Color(1.0, 0.77, 0.12))
	var orange := _material(Color(1.0, 0.34, 0.04))
	var black := _material(Color(0.05, 0.035, 0.02))
	for i in 3:
		var bird := Node3D.new()
		add_child(bird)
		birds.append(bird)
		_orb(bird, Vector3.ZERO, Vector3(0.095, 0.085, 0.13), yellow)
		_orb(bird, Vector3(0, 0.065, -0.085), Vector3.ONE * 0.079, yellow)
		_orb(bird, Vector3(0, 0.050, -0.163), Vector3(0.038, 0.024, 0.048), orange)
		for side in [-1.0, 1.0]:
			_orb(bird, Vector3(side * 0.045, 0.088, -0.143), Vector3(0.012, 0.013, 0.014), black)
			_orb(bird, Vector3(side * 0.13, 0.025, 0.018), Vector3(0.10, 0.025, 0.060), yellow)


func show_time(elapsed: float) -> void:
	for i in birds.size():
		var angle := elapsed / 1.2 * TAU + i * TAU / 3.0
		var rise := clampf((elapsed - 2.7) / 0.3, 0.0, 1.0)
		birds[i].position = Vector3(0.72 * cos(angle), 1.48 + rise * 0.5 + 0.04 * sin(angle * 2), 0.72 * sin(angle))
		birds[i].rotation.y = -angle
		birds[i].scale = Vector3.ONE * maxf(0.001, 1.0 - rise)


func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.8
	return mat


func _orb(parent: Node3D, at: Vector3, size: Vector3, mat: Material) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 12
	mesh.rings = 6
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.material_override = mat
	part.position = at
	part.scale = size
	part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(part)
