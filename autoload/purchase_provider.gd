class_name PurchaseProvider
extends RefCounted

## ②課金コンテンツの決済処理を差し替え可能にするための基底クラス。
## 今は MockPurchaseProvider（即時成功）のみ実装されているが、将来
## Steam Microtransactions API 等を使った本決済プロバイダに差し替える際は、
## このクラスを継承して buy_pack() を実装すればよい（PurchaseManager 側の
## 呼び出しコードは変更不要）。


## 指定した通貨パックの決済を実行する。成功したら true を返す。
## 本決済プロバイダでは非同期処理（await）になる想定のため、呼び出し側も
## await で使うこと
func buy_pack(_pack_id: StringName) -> bool:
	assert(false, "PurchaseProvider.buy_pack() はサブクラスで実装してください")
	return false
