extends Node

## ③プレゼント機能。EOS P2P(EOSGMultiplayerPeer, meshモード)を使い、
## 送受信とも「相手がオンラインでその場にいる」場合のみ配信する（非同期メールボックスは
## サーバーが無いため今回は実装しない）。
##
## メッセージ構造 {type, kind, id, from_name, nonce} はこのファイル内で完結しており、
## 将来サーバーを導入して非同期化する際も同じ形をそのままメールボックスの1レコードとして
## 転用できるようにしてある。
##
## 実装注意: _gift_peer(EOSGMultiplayerPeer)は「gift」ソケットのmeshピアとして
## GiftManagerだけが所有・ポーリングする専用インスタンス。get_tree().get_multiplayer()の
## multiplayer_peerには絶対に代入しない（NetworkManagerのWebSocketMultiplayerPeerが
## 実際のゲームプレイ通信で既にそこを占有しているため）。EosManager.eos_initialized(true)を
## 合図に生成し、以降は_process()で手動poll/get_packet/put_packetする、
## 「常時ポーリング」方式を踏襲する(旧Steam実装からの設計を引き継いだもの)。

signal gift_received(kind: StringName, id: StringName, from_name: String)

const GIFT_SOCKET_ID := "gift"
const ACK_TIMEOUT := 5.0
const ACK_POLL_INTERVAL := 0.25

var _gift_peer: EOSGMultiplayerPeer = null
var _pending_acks: Dictionary = {} # nonce(String) -> bool(受信済みか)


func _ready() -> void:
	EosManager.eos_initialized.connect(_on_eos_initialized)
	if EosManager.is_eos_available:
		_on_eos_initialized(true)


func _on_eos_initialized(success: bool) -> void:
	if not success or _gift_peer != null:
		return
	var peer := EOSGMultiplayerPeer.new()
	var err: int = peer.create_mesh(GIFT_SOCKET_ID)
	if err != OK:
		push_warning("[GiftManager] EOSGMultiplayerPeer.create_mesh failed: %s" % err)
		return
	peer.set_auto_accept_connection_requests(true)
	_gift_peer = peer


func _process(_delta: float) -> void:
	if _gift_peer == null:
		return
	_gift_peer.poll()
	_drain_incoming_packets()


func _drain_incoming_packets() -> void:
	while _gift_peer.get_available_packet_count() > 0:
		var sender_pid: int = _gift_peer.get_packet_peer()
		var data: PackedByteArray = _gift_peer.get_packet()
		_handle_packet(sender_pid, data)


## ③指定フレンド(EOS PUID)へアイテムを贈る。ジェムの消費・払い戻しは呼び出し側
## （PurchaseManager.spend_for_gift / refund_gift）の責務で、ここでは配信のみ行う。
## 戻り値: 配信（ack受領）に成功したら true。EOS無効時や相手に接続できない場合は false
func send_gift(friend_puid: String, kind: StringName, id: StringName) -> bool:
	if _gift_peer == null or friend_puid.is_empty():
		return false

	if not _gift_peer.has_user_id(friend_puid):
		_gift_peer.add_mesh_peer(friend_puid)

	var nonce := "%d_%s" % [Time.get_ticks_usec(), friend_puid]
	var payload := {
		"type": "gift",
		"kind": String(kind),
		"id": String(id),
		"from_name": ProfileManager.player_name,
		"nonce": nonce,
	}
	var bytes := JSON.stringify(payload).to_utf8_buffer()

	_pending_acks[nonce] = false
	var sent := false
	var elapsed := 0.0
	while elapsed < ACK_TIMEOUT:
		_gift_peer.poll()
		_drain_incoming_packets()

		if not sent:
			var pid: int = _gift_peer.get_peer_id(friend_puid)
			if pid != -1:
				_gift_peer.set_target_peer(pid)
				sent = _gift_peer.put_packet(bytes) == OK

		if _pending_acks.get(nonce, false):
			_pending_acks.erase(nonce)
			return true

		await get_tree().create_timer(ACK_POLL_INTERVAL).timeout
		elapsed += ACK_POLL_INTERVAL

	_pending_acks.erase(nonce)
	return false


func _handle_packet(sender_pid: int, data: PackedByteArray) -> void:
	var json := JSON.new()
	if json.parse(data.get_string_from_utf8()) != OK:
		return
	var payload = json.data
	if typeof(payload) != TYPE_DICTIONARY:
		return

	match String(payload.get("type", "")):
		"gift":
			_on_gift_packet(sender_pid, payload)
		"gift_ack":
			var nonce := str(payload.get("nonce", ""))
			if _pending_acks.has(nonce):
				_pending_acks[nonce] = true


func _on_gift_packet(sender_pid: int, payload: Dictionary) -> void:
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
	_send_ack(sender_pid, payload)


func _send_ack(sender_pid: int, payload: Dictionary) -> void:
	if _gift_peer == null:
		return
	var ack := {"type": "gift_ack", "nonce": payload.get("nonce", "")}
	_gift_peer.set_target_peer(sender_pid)
	_gift_peer.put_packet(JSON.stringify(ack).to_utf8_buffer())
