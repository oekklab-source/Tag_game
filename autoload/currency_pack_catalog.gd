class_name CurrencyPackCatalog
extends RefCounted

## ②ショップで購入できるジェム(ゲーム内通貨)パックの定義データ（純データ、副作用なし）。
## CostumeCatalog / HatCatalog と同じ「静的Dictionary + static関数」パターン。
##
## display_price は静的なフォールバック表示価格(概算)。Steam利用可能時は本来
## Steam側のローカライズ済み価格をUIで優先表示すべきだが、地域/通貨ロジックは
## ここに持たせずSteam側に任せる。steam_item_def_id はSteamworksパートナー
## バックエンドで各パックに対応するItem Definitionを作成した際に設定する値で、
## 現時点(申請中)ではプレースホルダー

const PACKS: Dictionary = {
	&"small": {
		"name": "ジェム 300個",
		"gems": 300,
		"display_price": "¥490",
		"steam_item_def_id": 100001,
	},
	&"medium": {
		"name": "ジェム 800個",
		"gems": 800,
		"display_price": "¥1,220",
		"steam_item_def_id": 100002,
	},
	&"large": {
		"name": "ジェム 2000個",
		"gems": 2000,
		"display_price": "¥2,800",
		"steam_item_def_id": 100003,
	},
}


static func has(id: StringName) -> bool:
	return PACKS.has(id)


static func get_def(id: StringName) -> Dictionary:
	return PACKS.get(id, {})


static func ordered_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for id in PACKS:
		ids.append(id)
	return ids
