class_name CostumeCatalog
extends RefCounted

## ④コスチュームの定義データ（純データ、副作用なし）。
## Autoload にしていないのは、UI 側（costume_screen）と対戦中の見た目適用
## （humanoid.gd）の両方から Autoload の初期化順序に依存せず参照できるようにするため。
##
## 塗り分けの単位は fallguy.glb の実構造に合わせてある:
##   Body    (1面: Body)
##   Costume (5面: Skin / SpikePurple / Claw / SpikeYellow / SpikeBlue)
##   Face    (2面: FaceWhite / Pupil)
## 新規3Dアセットは追加せず、この8スロットの塗り分けレシピだけでコスチュームを表現する。

const PART_SURFACES := {"Body": 1, "Costume": 5, "Face": 2}

## rarity: common / rare / epic / legendary（将来のショップ表示用）
## unlock: default(最初から所持) / rating(到達レート報酬) / shop(課金/購入) / event(配布)
## color_slots: プレイヤーが選べる色の数（costume_colors 配列の要素数と対応）
## surfaces: 各要素は {"part", "index", 他}
##   - "slot" があれば costume_colors[slot] をその面の albedo として使う（ユーザー選択色）
##   - "albedo" があれば固定色（ユーザーは変更不可）
##   - "role_tint" が true の面は、対戦中は常に役割色（逃走者=緑/鬼=赤/待機=灰）で上書きされる
##   - surfaces に載っていない面は glTF インポート時の元マテリアルのまま変更しない
const COSTUMES: Dictionary = {
	&"default": {
		"name": "きほん",
		"rarity": &"common",
		"price": 0,
		"unlock": &"default",
		"color_slots": 1,
		"surfaces": [
			{"part": "Body", "index": 0, "slot": 0, "role_tint": true},
		],
	},
	&"neon": {
		"name": "ネオン",
		"rarity": &"rare",
		"price": 0,
		"unlock": &"default",
		"color_slots": 2,
		"surfaces": [
			{"part": "Body", "index": 0, "slot": 0, "role_tint": true},
			{"part": "Costume", "index": 0, "albedo": Color(0.05, 0.05, 0.08)},  # Skin -> 黒
			{"part": "Costume", "index": 1, "slot": 1, "emission": true},        # SpikePurple -> 発光アクセント
			{"part": "Costume", "index": 2, "albedo": Color(0.08, 0.08, 0.10)},  # Claw -> 黒
			{"part": "Costume", "index": 3, "slot": 1, "emission": true},        # SpikeYellow -> 発光アクセント
			{"part": "Costume", "index": 4, "slot": 1, "emission": true},        # SpikeBlue -> 発光アクセント
			{"part": "Face", "index": 0, "albedo": Color(0.9, 0.92, 0.95)},
		],
	},
	&"mono": {
		"name": "モノトーン",
		"rarity": &"common",
		"price": 0,
		"unlock": &"default",
		"color_slots": 1,
		"surfaces": [
			{"part": "Body", "index": 0, "slot": 0, "role_tint": true},
			{"part": "Costume", "index": 0, "albedo": Color(0.85, 0.85, 0.85)},
			{"part": "Costume", "index": 1, "albedo": Color(0.25, 0.25, 0.25)},
			{"part": "Costume", "index": 2, "albedo": Color(0.15, 0.15, 0.15)},
			{"part": "Costume", "index": 3, "albedo": Color(0.55, 0.55, 0.55)},
			{"part": "Costume", "index": 4, "albedo": Color(0.35, 0.35, 0.35)},
		],
	},
	&"candy": {
		"name": "キャンディ",
		"rarity": &"rare",
		"price": 0,
		"unlock": &"rating",
		"color_slots": 2,
		"surfaces": [
			{"part": "Body", "index": 0, "slot": 0, "role_tint": true},
			{"part": "Costume", "index": 0, "slot": 1},                          # Skin -> ユーザー色2
			{"part": "Costume", "index": 1, "albedo": Color(1.0, 0.55, 0.75)},   # SpikePurple -> ピンク
			{"part": "Costume", "index": 2, "albedo": Color(1.0, 0.85, 0.30)},   # Claw -> 黄
			{"part": "Costume", "index": 3, "albedo": Color(0.55, 0.85, 1.0)},   # SpikeYellow -> 水色
			{"part": "Costume", "index": 4, "slot": 1},                          # SpikeBlue -> ユーザー色2
		],
	},
	&"gold": {
		"name": "ゴールド",
		"rarity": &"legendary",
		"price": 500,
		"unlock": &"shop",
		"color_slots": 1,
		"surfaces": [
			{"part": "Body", "index": 0, "slot": 0, "role_tint": true},
			{"part": "Costume", "index": 0, "albedo": Color(0.83, 0.68, 0.21), "metallic": 0.8},
			{"part": "Costume", "index": 1, "albedo": Color(0.90, 0.75, 0.30), "metallic": 0.8},
			{"part": "Costume", "index": 2, "albedo": Color(0.70, 0.55, 0.15), "metallic": 0.8},
			{"part": "Costume", "index": 3, "albedo": Color(0.95, 0.82, 0.40), "metallic": 0.8},
			{"part": "Costume", "index": 4, "albedo": Color(0.83, 0.68, 0.21), "metallic": 0.8},
		],
	},
}

const DEFAULT_ID: StringName = &"default"


static func has(id: StringName) -> bool:
	return COSTUMES.has(id)


## 不正な id は default にフォールバックした定義を返す
static func get_def(id: StringName) -> Dictionary:
	if COSTUMES.has(id):
		return COSTUMES[id]
	return COSTUMES[DEFAULT_ID]


static func default_colors(id: StringName) -> PackedColorArray:
	var slots: int = int(get_def(id).get("color_slots", 1))
	var colors := PackedColorArray()
	for i in range(slots):
		colors.append(Color(0.25, 0.65, 0.95))
	return colors


## 初期所持（unlock == "default"）の一覧
static func default_owned_ids() -> Array[String]:
	var ids: Array[String] = []
	for id in COSTUMES:
		if COSTUMES[id].get("unlock", &"default") == &"default":
			ids.append(String(id))
	return ids


## ショップ等で表示する購入可能一覧（unlock != "default"）
static func purchasable_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for id in COSTUMES:
		if COSTUMES[id].get("unlock", &"default") != &"default":
			ids.append(id)
	return ids
