extends Area3D

## 壁の天面に乗ったキャラを外へ弾き出す。
##
## 天面は 63° の屋根型にしてあるが、それだけでは塞ぎきれない:
## カプセルが稜線の真上に来ると接触法線が「真上」になり、面の傾斜に関係なく
## is_on_floor() が成立してしまう（凸形状では原理的に避けられない）。
## そのため最後の保証としてこの領域を置き、入ってきたキャラを横へ弾く。
##
## 効果はそのボディの権威ピアだけが適用する（他のギミックと同じ規約）。

const PUSH_OUT := 8.0
const PUSH_UP := 2.5


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if not body.has_method("launch") or not body.is_multiplayer_authority():
		return
	var away := body.global_position - global_position
	away.y = 0.0
	if away.length() < 0.05:
		# 稜線の真上に真っ直ぐ落ちてきた場合は壁の短辺方向へ逃がす
		away = global_transform.basis.z
		away.y = 0.0
	body.launch(away.normalized() * PUSH_OUT + Vector3(0, PUSH_UP, 0))
