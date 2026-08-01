extends StaticBody3D

## 設置ブロック。一定時間だけ視線と通行を塞ぐ壁を作る。
##
## コリジョンは Platform レイヤー(8)。これで
##   - 視線を遮る（GameManager.SIGHT_MASK = World|Platform に含まれる）
##   - キャラの通行を塞ぐ（キャラの collision_mask に含まれる）
##   - ナビメッシュのベイク対象から外れる（geometry_collision_mask = 1）
## となる。ベイクに乗らないので CPU は経路上にあると押し付けられて止まるが、
## cpu_hunter.gd 側のスタック検知が横へ回り込ませる。

const LIFETIME := 15.0
const FADE := 1.0  # 消える直前に薄くして予告する

var _left := LIFETIME

@onready var mesh: MeshInstance3D = $Mesh


func _process(delta: float) -> void:
	_left -= delta
	if _left < FADE:
		mesh.transparency = clampf(1.0 - _left / FADE, 0.0, 0.95)
	if _left <= 0.0 and multiplayer.is_server():
		# サーバが消せば MultiplayerSpawner が全ピアの複製も消す
		queue_free()
