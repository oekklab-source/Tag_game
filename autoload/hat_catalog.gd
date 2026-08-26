class_name HatCatalog
extends RefCounted

## ⑤帽子(頭部装備)の定義データ（純データ、副作用なし）。CostumeCatalog と対になる
## 「部位ごとに独立して選べる」装備カテゴリの第一弾。CostumeCatalog が Body/Costume/Face
## の8サーフェスを塗り分けるだけなのに対し、こちらは新規ジオメトリ(スキニング無しの
## 剛体メッシュ)を Chest ボーンへ BoneAttachment3D 経由で装着する。
##
## 3部位目の装備カテゴリが必要になった場合は、この HatCatalog / CostumeCatalog の
## 共通部分（has/get_def/default_owned_ids）を基底クラスへ切り出すことを検討する。
## 今は2部位しか無いため、既存 CostumeCatalog には手を入れず並べるだけにしてある。

## offset/rotation_degrees は Chest ボーン(BoneAttachment3D)のローカル空間での値。
## Blender と glTF でボーン軸の向きが変わるため机上計算では決められず、
## Godot エディタ上で帽子を仮置きして目視調整した結果をここに転記すること
## （scenes/humanoid.tscn の HatAttachment 参照）。
const HATS: Dictionary = {
	&"none": {
		"name": "なし",
		"rarity": &"common",
		"price": 0,
		"unlock": &"default",
		"scene": null,
		"offset": Vector3.ZERO,
		"rotation_degrees": Vector3.ZERO,
	},
	&"party": {
		"name": "パーティハット",
		"rarity": &"common",
		"price": 0,
		"unlock": &"default",
		"scene": preload("res://assets/character/hats/hat_party.glb"),
		"offset": Vector3(0.0, 0.48, 0.0),
		"rotation_degrees": Vector3.ZERO,
	},
	&"cap": {
		"name": "キャップ",
		"rarity": &"rare",
		"price": 0,
		"unlock": &"rating",
		"scene": preload("res://assets/character/hats/hat_cap.glb"),
		"offset": Vector3(0.0, 0.42, 0.0),
		"rotation_degrees": Vector3.ZERO,
	},
	&"propeller": {
		"name": "プロペラ帽",
		"rarity": &"epic",
		"price": 0,
		"unlock": &"shop",
		"scene": preload("res://assets/character/hats/hat_propeller.glb"),
		"offset": Vector3(0.0, 0.50, 0.0),
		"rotation_degrees": Vector3.ZERO,
	},
}

const DEFAULT_ID: StringName = &"none"


static func has(id: StringName) -> bool:
	return HATS.has(id)


## 不正な id は none にフォールバックした定義を返す
static func get_def(id: StringName) -> Dictionary:
	if HATS.has(id):
		return HATS[id]
	return HATS[DEFAULT_ID]


## 初期所持（unlock == "default"）の一覧
static func default_owned_ids() -> Array[String]:
	var ids: Array[String] = []
	for id in HATS:
		if HATS[id].get("unlock", &"default") == &"default":
			ids.append(String(id))
	return ids


## ショップ等で表示する購入可能一覧（unlock != "default"）
static func purchasable_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for id in HATS:
		if HATS[id].get("unlock", &"default") != &"default":
			ids.append(id)
	return ids
