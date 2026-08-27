class_name PurchaseProvider
extends RefCounted

## ②課金コンテンツの決済処理を差し替え可能にするための基底クラス。
## MockPurchaseProvider（即時成功）と SteamPurchaseProvider（Steamworks
## Microtransactions）の2実装がある。本決済プロバイダは await を含む
## コルーチンとして buy_pack() をオーバーライドすること（PurchaseManager 側の
## 呼び出しコードは変更不要、必ず await で呼び出す）。


## 指定した通貨パックの決済を実行する。戻り値は {"ok": bool, "granted_gems": int,
## "reason": String} 形式。ok が true の場合のみ granted_gems（プロバイダ側で
## 確定した付与量）を信用してよい。呼び出し側はこれ以外の値でジェムを
## 加算してはならない（クライアント側の静的カタログ値を信用しない）
func buy_pack(_pack_id: StringName) -> Dictionary:
	assert(false, "PurchaseProvider.buy_pack() はサブクラスで実装してください")
	return {"ok": false, "granted_gems": 0, "reason": "not_implemented"}
