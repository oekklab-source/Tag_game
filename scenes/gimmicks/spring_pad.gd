extends Area3D

## ジャンプ台。触れたキャラを真上に打ち上げる。
## 頂点はおよそ 13^2 / (2 * 9.8) = 8.6m。高いゾーンへ登る主要ルートになる。
##
## Area3D の body_entered は全ピアで発火するため、
## 効果の適用は必ず「そのボディの権威ピア」に限定する（演出は全ピアで再生）。

const LAUNCH := 13.0

## バネ本体（Coil+Pad）だけを指す。根元が台座の上面（ローカルy=0）に
## あるので、ここの scale.y を動かせば「台座は動かず上だけ伸び縮みする」動きになる
@onready var spring: Node3D = $Mesh/SpringPadModel/SpringPad/Spring


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	_boing()
	if body.has_method("launch") and body.is_multiplayer_authority():
		body.launch(Vector3(0, LAUNCH, 0))


func _boing() -> void:
	var t := create_tween()
	t.tween_property(spring, "scale", Vector3(1.4, 0.15, 1.4), 0.05)
	t.tween_property(spring, "scale", Vector3(0.5, 1.7, 0.5), 0.12)
	t.tween_property(spring, "scale", Vector3.ONE, 0.5) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
