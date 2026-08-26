extends Node

## ②課金コンテンツの購入処理を統括する Autoload。
## 決済そのものは PurchaseProvider（現状は MockPurchaseProvider）に委譲し、
## ここでは「決済成功後にジェムを付与する」「ジェムでアイテムを購入する」という
## ゲーム内のルールだけを扱う。

signal currency_changed
signal item_purchased(kind: StringName, id: StringName)
signal purchase_failed(reason: String)

var _provider: PurchaseProvider = MockPurchaseProvider.new()


## ②通貨パックを購入し、成功したらジェムを付与する
func buy_currency_pack(pack_id: StringName) -> bool:
	if not CurrencyPackCatalog.has(pack_id):
		purchase_failed.emit("不明な通貨パックです")
		return false
	var ok := _provider.buy_pack(pack_id)
	if not ok:
		purchase_failed.emit("購入処理に失敗しました")
		return false
	var gems := int(CurrencyPackCatalog.get_def(pack_id).get("gems", 0))
	ProfileManager.add_currency(gems)
	currency_changed.emit()
	return true


## ②ジェムでコスチューム/帽子を購入する。kind は &"costume" / &"hat"
func purchase_item(kind: StringName, id: StringName) -> bool:
	var price := _item_price(kind, id)
	if price < 0:
		purchase_failed.emit("不明なアイテムです")
		return false
	if _owns(kind, id):
		purchase_failed.emit("すでに所持しています")
		return false
	if not ProfileManager.spend_currency(price):
		purchase_failed.emit("ジェムが足りません")
		return false
	_grant(kind, id)
	currency_changed.emit()
	item_purchased.emit(kind, id)
	return true


## ③プレゼント用: 自分のジェムを消費するだけで、相手への付与は GiftManager が行う。
## 失敗（配信不可）時は呼び出し側が refund_gift() で払い戻すこと
func spend_for_gift(kind: StringName, id: StringName) -> bool:
	var price := _item_price(kind, id)
	if price < 0:
		return false
	return ProfileManager.spend_currency(price)


func refund_gift(kind: StringName, id: StringName) -> void:
	var price := _item_price(kind, id)
	if price > 0:
		ProfileManager.add_currency(price)
		currency_changed.emit()


func _item_price(kind: StringName, id: StringName) -> int:
	match kind:
		&"costume":
			if not CostumeCatalog.has(id):
				return -1
			return int(CostumeCatalog.get_def(id).get("price", 0))
		&"hat":
			if not HatCatalog.has(id):
				return -1
			return int(HatCatalog.get_def(id).get("price", 0))
		_:
			return -1


func _owns(kind: StringName, id: StringName) -> bool:
	match kind:
		&"costume":
			return ProfileManager.owns_costume(id)
		&"hat":
			return ProfileManager.owns_hat(id)
		_:
			return false


func _grant(kind: StringName, id: StringName) -> void:
	match kind:
		&"costume":
			ProfileManager.grant_costume(id)
		&"hat":
			ProfileManager.grant_hat(id)
