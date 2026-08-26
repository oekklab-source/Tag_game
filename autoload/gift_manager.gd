extends Node

## ③プレゼント機能。Steamの P2P Networking(SteamNetworking) を使い、
## 送受信とも「相手がオンラインでその場にいる」場合のみ配信する（非同期メールボックスは
## サーバーが無いため今回は実装しない）。
##
## メッセージ構造 {type, kind, id, from_name, nonce} はこのファイル内で完結しており、
## 将来サーバーを導入して非同期化する際も同じ形をそのままメールボックスの1レコードとして
## 転用できるようにしてある。
##
## 実装注意: sendP2PPacket / readP2PPacket / getAvailableP2PPacketSize /
## acceptP2PSessionWithUser / p2p_session_request は GodotSteam の一般的な
## バインディング名。addons/godotsteam はコンパイル済みGDExtensionのため事前の
## テキスト検索では確認できておらず、導入バージョン(4.22)の実際のメソッド一覧を
## Godotエディタのオートコンプリートで確認し、名称が異なる場合はここだけ調整すること。

signal gift_received(kind: StringName, id: StringName, from_name: String)

const GIFT_CHANNEL := 0
const ACK_TIMEOUT := 5.0
const ACK_POLL_INTERVAL := 0.25

# Steamworks EP2PSend 相当（k_EP2PSendReliable）
const P2P_SEND_RELIABLE := 2

var _pending_acks: Dictionary = {} # nonce(String) -> bool(受信済みか)


func _ready() -> void:
	if Engine.has_singleton("Steam"):
		var steam = Engine.get_singleton("Steam")
		if steam.has_signal("p2p_session_request"):
			steam.p2p_session_request.connect(_on_p2p_session_request)


func _process(_delta: float) -> void:
	if not (SteamManager.is_steam_available and Engine.has_singleton("Steam")):
		return
	var steam = Engine.get_singleton("Steam")
	var packet_size: int = steam.getAvailableP2PPacketSize(GIFT_CHANNEL)
	while packet_size > 0:
		var result: Dictionary = steam.readP2PPacket(packet_size, GIFT_CHANNEL)
		_handle_packet(result)
		packet_size = steam.getAvailableP2PPacketSize(GIFT_CHANNEL)


func _on_p2p_session_request(remote_id: int) -> void:
	var steam = Engine.get_singleton("Steam")
	steam.acceptP2PSessionWithUser(remote_id)


## ③指定フレンドへアイテムを贈る。ジェムの消費・払い戻しは呼び出し側
## （PurchaseManager.spend_for_gift / refund_gift）の責務で、ここでは配信のみ行う。
## 戻り値: 配信（ack受領）に成功したら true。Steam無効時や相手がオフラインの場合は false
func send_gift(friend_steam_id: int, kind: StringName, id: StringName) -> bool:
	if not (SteamManager.is_steam_available and Engine.has_singleton("Steam")):
		return false
	var steam = Engine.get_singleton("Steam")
	var nonce := "%d_%d" % [Time.get_ticks_usec(), friend_steam_id]
	var payload := {
		"type": "gift",
		"kind": String(kind),
		"id": String(id),
		"from_name": ProfileManager.player_name,
		"nonce": nonce,
	}
	var bytes := JSON.stringify(payload).to_utf8_buffer()
	var sent: bool = steam.sendP2PPacket(friend_steam_id, bytes, P2P_SEND_RELIABLE, GIFT_CHANNEL)
	if not sent:
		return false

	_pending_acks[nonce] = false
	var elapsed := 0.0
	while elapsed < ACK_TIMEOUT:
		if _pending_acks.get(nonce, false):
			_pending_acks.erase(nonce)
			return true
		await get_tree().create_timer(ACK_POLL_INTERVAL).timeout
		elapsed += ACK_POLL_INTERVAL
	_pending_acks.erase(nonce)
	return false


func _handle_packet(result: Dictionary) -> void:
	var data: PackedByteArray = result.get("data", PackedByteArray())
	var remote_id: int = int(result.get("remote_steam_id", 0))
	var json := JSON.new()
	if json.parse(data.get_string_from_utf8()) != OK:
		return
	var payload = json.data
	if typeof(payload) != TYPE_DICTIONARY:
		return

	match String(payload.get("type", "")):
		"gift":
			_on_gift_packet(remote_id, payload)
		"gift_ack":
			var nonce := str(payload.get("nonce", ""))
			if _pending_acks.has(nonce):
				_pending_acks[nonce] = true


func _on_gift_packet(remote_id: int, payload: Dictionary) -> void:
	var kind := StringName(str(payload.get("kind", "")))
	var id := StringName(str(payload.get("id", "")))
	var from_name := String(payload.get("from_name", "フレンド"))

	var valid := false
	match kind:
		&"costume":
			if CostumeCatalog.has(id):
				ProfileManager.grant_costume(id)
				valid = true
		&"hat":
			if HatCatalog.has(id):
				ProfileManager.grant_hat(id)
				valid = true

	if not valid:
		return

	gift_received.emit(kind, id, from_name)
	_send_ack(remote_id, payload)


func _send_ack(remote_id: int, payload: Dictionary) -> void:
	if not Engine.has_singleton("Steam"):
		return
	var steam = Engine.get_singleton("Steam")
	var ack := {"type": "gift_ack", "nonce": payload.get("nonce", "")}
	steam.sendP2PPacket(remote_id, JSON.stringify(ack).to_utf8_buffer(), P2P_SEND_RELIABLE, GIFT_CHANNEL)
