class_name CurrencyPackCatalog
extends RefCounted

## ②ショップで購入できるジェム(ゲーム内通貨)パックの定義データ（純データ、副作用なし）。
## CostumeCatalog / HatCatalog と同じ「静的Dictionary + static関数」パターン。
##
## display_price は静的なフォールバック表示価格(概算)。stripe_price_id は
## Stripe Dashboardで各パックに対応する商品として事前作成したPrice ID
## (例: price_xxxxxxxxxxxx)。テストモード/本番モードでID体系が別れるため、
## 本番切替時は別途本番用Priceを作成しIDを差し替える必要がある

const PACKS: Dictionary = {
	&"small": {
		"name": "ジェム 300個",
		"gems": 300,
		"display_price": "¥490",
		"stripe_price_id": "price_REPLACE_WITH_REAL_SMALL",
	},
	&"medium": {
		"name": "ジェム 800個",
		"gems": 800,
		"display_price": "¥1,220",
		"stripe_price_id": "price_REPLACE_WITH_REAL_MEDIUM",
	},
	&"large": {
		"name": "ジェム 2000個",
		"gems": 2000,
		"display_price": "¥2,800",
		"stripe_price_id": "price_REPLACE_WITH_REAL_LARGE",
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
