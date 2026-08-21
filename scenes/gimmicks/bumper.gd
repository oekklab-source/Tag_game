extends Area3D

## Fall Guys 風のバンパー。触れたキャラを外向きに弾き返す。
##
## 幾何（潰した球の StaticBody3D）は親側にあり、この Area はそれを一回り覆う。
## 押し出す向きは「バンパーの中心から相手へ」の水平方向なので、
## どの角度から当たっても必ず離れる向きへ飛ぶ。上に乗った場合も同じで、
## 弾き返しがそのまま「天面に立てない」を兼ねる。
##
## Area3D の body_entered は全ピアで発火するため、
## 効果の適用は必ず「そのボディの権威ピア」に限定する（演出は全ピアで再生）。

## launch() は水平を加算するので、走り込む速度（最大 8m/s、滑り台の出口なら
## それ以上）を打ち消してなお離れる向きへ残る大きさにしてある
const PUSH := 13.0
## 軽く浮かせて弾んだ感触にする。頂点は 2.6^2/(2*9.8) ≒ 0.35m しかないので、
## これで届く場所が増えることはない（登坂ルートの設計は変わらない）
const LIFT := 2.6

@onready var _mesh: MeshInstance3D = get_parent().get_node_or_null("Mesh")


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	_squash()
	if not body.has_method("launch") or not body.is_multiplayer_authority():
		return
	var away := body.global_position - global_position
	away.y = 0.0
	# 真上から落ちてきた場合は水平成分が消えるので、適当な向きへ逃がす
	if away.length() < 0.01:
		away = Vector3.FORWARD
	away = away.normalized()
	body.launch(Vector3(away.x * PUSH, LIFT, away.z * PUSH))


func _squash() -> void:
	if _mesh == null:
		return
	var t := create_tween()
	t.tween_property(_mesh, "scale", Vector3(1.25, 0.8, 1.25), 0.06)
	t.tween_property(_mesh, "scale", Vector3.ONE, 0.4) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
