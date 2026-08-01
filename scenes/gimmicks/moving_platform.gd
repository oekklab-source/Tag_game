extends AnimatableBody3D

## 動く床（リフト / シャトル）。開始位置と travel の間を緩急つきで往復する。
##
## 乗客の運搬は Godot 側に任せている: sync_to_physics = true の AnimatableBody3D は
## 物理サーバ経由で動くため、その上の CharacterBody3D は move_and_slide() の
## プラットフォーム速度で一緒に運ばれる。
##
## 位相は GameManager.world_time（ラウンド開始で全ピア同時にリセット）から
## 決めるので、床の位置はホストとクライアントで一致する。

@export var travel := Vector3(0, 7, 0)
@export var period := 8.0

var _start := Vector3.ZERO


func _ready() -> void:
	_start = position


func _physics_process(_delta: float) -> void:
	var f := 0.5 - 0.5 * cos(TAU * GameManager.world_time / period)
	position = _start + travel * f
