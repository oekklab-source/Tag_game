extends Area3D

## ジャンプ台。触れたキャラを真上に打ち上げる。
## 頂点はおよそ 13^2 / (2 * 9.8) = 8.6m。高いゾーンへ登る主要ルートになる。
##
## Area3D の body_entered は全ピアで発火するため、
## 効果の適用は必ず「そのボディの権威ピア」に限定する（演出は全ピアで再生）。

const LAUNCH := 13.0

@onready var mesh: MeshInstance3D = $Mesh


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	_squash()
	if body.has_method("launch") and body.is_multiplayer_authority():
		body.launch(Vector3(0, LAUNCH, 0))


func _squash() -> void:
	var t := create_tween()
	t.tween_property(mesh, "scale", Vector3(1.3, 0.3, 1.3), 0.07)
	t.tween_property(mesh, "scale", Vector3.ONE, 0.35) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
