class_name StuckEscape
extends RefCounted

## 壁の角に押し付けられて動けなくなった時の共通の抜け出し方。
## CPU 鬼(cpu_hunter.gd)と逃走者(player.gd)の両方から呼ぶ。
##
## 動けているかの判定はナビ目標(鬼)・入力方向(逃走者)と実際の変位が
## それぞれ違うので、閾値だけをここに集約し、判定自体は呼び出し側に任せる。
const STUCK_DIST := 0.6
const STUCK_TIME := 0.6
## 脱出キックを何秒間かけ続けるか。1フレームだけだと角を抜けきる前に
## 通常の移動制御へ戻り、また同じ場所へ押し戻されてしまう
const KICK_TIME := 0.35

## 直前の move_and_slide() が拾った衝突法線を合成し、そこから離れる向きの
## 脱出速度を返す。法線ベースなので、2枚の壁から均等に押し返されるコーナーでは
## 自然と対角線方向（＝両方の壁から等しく離れる向き）を向く。
## 衝突情報が無ければ（壁以外が原因、または今フレーム衝突していない）ZERO を返す
static func normal_kick(body: CharacterBody3D, speed: float) -> Vector3:
	var sum := Vector3.ZERO
	for i in body.get_slide_collision_count():
		var n := body.get_slide_collision(i).get_normal()
		sum += Vector3(n.x, 0.0, n.z)
	return sum.normalized() * speed if sum.length_squared() > 0.01 else Vector3.ZERO
