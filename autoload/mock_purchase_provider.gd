class_name MockPurchaseProvider
extends PurchaseProvider

## ②本決済インフラ（サーバー・Steamworksパートナー審査）が無い間の暫定実装。
## 実際の決済は一切行わず、常に即時成功する。PurchaseManager はこのクラスの
## interfaceだけに依存しているので、将来ここを本決済プロバイダに差し替えるだけでよい。


func buy_pack(pack_id: StringName) -> Dictionary:
	if not CurrencyPackCatalog.has(pack_id):
		return {"ok": false, "granted_gems": 0, "reason": "unknown_pack"}
	var gems := int(CurrencyPackCatalog.get_def(pack_id).get("gems", 0))
	return {"ok": true, "granted_gems": gems, "reason": ""}
