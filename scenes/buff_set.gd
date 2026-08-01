class_name BuffSet
extends RefCounted

## 時限バフの入れ物。プレイヤーと CPU 鬼が共用する。
##
## バフは意図的にレプリケートしない。効果はそのボディの権威ピアで適用され、
## 「速く動く / 高く跳ぶ」という結果は既存の位置同期で他ピアへ伝わるため。

var _b := {}  # StringName -> [倍率, 残り秒]


func add(key: StringName, mult: float, dur: float) -> void:
	_b[key] = [mult, dur]


func get_mult(key: StringName) -> float:
	return _b[key][0] if _b.has(key) else 1.0


func time_left(key: StringName) -> float:
	return _b[key][1] if _b.has(key) else 0.0


func keys() -> Array:
	return _b.keys()


func tick(delta: float) -> void:
	for k in _b.keys():
		_b[k][1] -= delta
		if _b[k][1] <= 0.0:
			_b.erase(k)


func clear() -> void:
	_b.clear()
