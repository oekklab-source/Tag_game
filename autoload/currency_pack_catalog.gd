class_name CurrencyPackCatalog
extends RefCounted

## ②ショップで購入できるジェム(ゲーム内通貨)パックの定義データ（純データ、副作用なし）。
## CostumeCatalog / HatCatalog と同じ「静的Dictionary + static関数」パターン。
##
## display_price はモック実装であることを踏まえ、実際に課金されるわけではないことを
## ボタン表示上も明確にする（PurchaseManager 側では常に即時成功する）。

const PACKS: Dictionary = {
	&"small": {
		"name": "ジェム 300個",
		"gems": 300,
		"display_price": "（無料お試し）",
	},
	&"medium": {
		"name": "ジェム 800個",
		"gems": 800,
		"display_price": "（無料お試し）",
	},
	&"large": {
		"name": "ジェム 2000個",
		"gems": 2000,
		"display_price": "（無料お試し）",
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
