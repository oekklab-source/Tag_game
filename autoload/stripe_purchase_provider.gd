class_name StripePurchaseProvider
extends PurchaseProvider

## ⑥Stripe Checkoutを使った実課金プロバイダ。
## Checkout Session作成はStripeのシークレットキーをクライアントに置かないため、
## 本リポジトリ内の別サービス(service/commerce-api/)経由で行う。決済自体は
## OS.shell_open()でシステムブラウザのStripe Hosted Checkoutへ遷移させ、
## クライアントはservice/commerce-api/の/purchase-statusをポーリングして結果を待つ。
## 決済確認そのもの(ジェム付与の確定)はサーバー側のStripe Webhookが唯一の真実源であり、
## このクライアントは確定済みの状態を読みに行くだけで、Stripeへは直接問い合わせない。
##
## PurchaseProviderはRefCountedでツリーに属さないため、HTTPRequestノードの追加先・
## SceneTreeタイマー取得先としてPurchaseManager(Node)自身をコンストラクタで受け取る。

const COMMERCE_API_BASE_URL := "https://YOUR-COMMERCE-API-HOST/"
const POLL_INTERVAL := 5.0
const POLL_TIMEOUT := 1860.0 # Checkout Sessionのexpires_at最小値(30分)に余裕を足した値
const PENDING_PURCHASE_PATH := "user://pending_purchase.json"

var _host: Node
var _cancel_requested := false


func _init(host_node: Node) -> void:
	_host = host_node


func buy_pack(pack_id: StringName) -> Dictionary:
	_cancel_requested = false

	var init_res := await _call_api("create-checkout-session", {"pack_id": String(pack_id)})
	var order_id := String(init_res.get("orderid", ""))
	var checkout_url := String(init_res.get("checkout_url", ""))
	if not init_res.get("api_ok", false) or order_id.is_empty() or checkout_url.is_empty():
		return {"ok": false, "granted_gems": 0, "reason": "network_error"}

	# ブラウザを開く前に永続化しておくことで、この直後にアプリが落ちても
	# reconcile_pending() が次回起動時に決済結果を回収できる
	_save_pending(order_id, pack_id)
	OS.shell_open(checkout_url)

	var elapsed := 0.0
	while elapsed < POLL_TIMEOUT:
		if _cancel_requested:
			_clear_pending()
			return {"ok": false, "granted_gems": 0, "reason": "user_cancelled"}
		await _host.get_tree().create_timer(POLL_INTERVAL).timeout
		elapsed += POLL_INTERVAL

		var status_res := await _call_api("purchase-status", {"order_id": order_id})
		if not status_res.get("api_ok", false):
			continue # 一時的な通信エラーはポーリングを継続する

		match String(status_res.get("status", "pending")):
			"paid":
				_clear_pending()
				return {"ok": true, "granted_gems": int(status_res.get("granted_gems", 0)), "reason": ""}
			"expired":
				_clear_pending()
				return {"ok": false, "granted_gems": 0, "reason": "user_cancelled"}
			_:
				pass # "pending" のままポーリング継続

	# タイムアウト: 決済が実際には成立している可能性があるため pending ファイルは
	# あえて残し、次回起動時の reconcile_pending() での再確認に委ねる
	return {"ok": false, "granted_gems": 0, "reason": "purchase_timeout"}


func cancel() -> void:
	_cancel_requested = true


## 前回セッションでタイムアウト/未解決のまま終わった購入がないか、起動時に1度だけ確認する。
## 戻り値: {"found": bool, "ok": bool, "granted_gems": int}
func reconcile_pending() -> Dictionary:
	if not FileAccess.file_exists(PENDING_PURCHASE_PATH):
		return {"found": false}
	var file := FileAccess.open(PENDING_PURCHASE_PATH, FileAccess.READ)
	if file == null:
		return {"found": false}
	var text := file.get_as_text()
	file.close()

	var json := JSON.new()
	if json.parse(text) != OK or typeof(json.data) != TYPE_DICTIONARY:
		_clear_pending()
		return {"found": false}
	var order_id := String(json.data.get("order_id", ""))
	if order_id.is_empty():
		_clear_pending()
		return {"found": false}

	var status_res := await _call_api("purchase-status", {"order_id": order_id})
	if not status_res.get("api_ok", false):
		return {"found": true, "ok": false, "granted_gems": 0} # 通信失敗、次回起動時に再試行(ファイルは残す)

	match String(status_res.get("status", "pending")):
		"paid":
			_clear_pending()
			return {"found": true, "ok": true, "granted_gems": int(status_res.get("granted_gems", 0))}
		"expired":
			_clear_pending()
			return {"found": true, "ok": false, "granted_gems": 0}
		_:
			return {"found": true, "ok": false, "granted_gems": 0} # まだpending、ファイルは残す


func _save_pending(order_id: String, pack_id: StringName) -> void:
	var file := FileAccess.open(PENDING_PURCHASE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"order_id": order_id,
		"pack_id": String(pack_id),
		"created_at": Time.get_unix_time_from_system(),
	}))
	file.close()


func _clear_pending() -> void:
	if FileAccess.file_exists(PENDING_PURCHASE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PENDING_PURCHASE_PATH))


## service/commerce-api/ の1エンドポイントをPOSTで呼ぶ
func _call_api(endpoint: String, body: Dictionary) -> Dictionary:
	return await HttpJsonClient.post_json(_host, COMMERCE_API_BASE_URL + endpoint, body)
