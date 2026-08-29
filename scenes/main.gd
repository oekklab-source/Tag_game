extends Control

## ロビー画面。ホスト開始（PC のみ）またはアドレスを指定して参加する。

@onready var status_label: Label = $CenterContainer/VBox/StatusLabel
@onready var version_label: Label = $VersionLabel
@onready var nickname_edit: LineEdit = $CenterContainer/VBox/NicknameEdit
@onready var host_button: Button = $CenterContainer/VBox/HostButton
@onready var address_edit: LineEdit = $CenterContainer/VBox/JoinRow/AddressEdit
@onready var join_button: Button = $CenterContainer/VBox/JoinRow/JoinButton


func _ready() -> void:
	# ブラウザは WebSocket サーバになれないため、Web 版ではホスト不可
	if OS.has_feature("web"):
		host_button.visible = false
	nickname_edit.text = PlayerPrefs.nickname
	status_label.text = NetworkManager.last_error
	NetworkManager.last_error = ""
	# ホストと参加者でここが違うと通信が噛み合わない。ひと目で分かるように出す
	version_label.text = "v%d" % GameManager.PROTOCOL_VERSION
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	# 配布リンク（.../?s=xxxx.trycloudflare.com）から開かれた場合はそのまま参加する
	var s := _server_from_query()
	if s.is_empty():
		return
	address_edit.text = s
	if not NetworkManager.auto_join_done:
		NetworkManager.auto_join_done = true
		# _ready() の最中はまだ親がこのシーンの子を追加中で、そこから change_scene すると
		# 「Parent node is busy adding/removing children」で失敗する。
		# ボタン経由（シグナル）と同じくフレーム境界まで遅らせる
		NetworkManager.start_client.call_deferred(s)


## Web でのみ有効。URL の ?s=<host> をゲームサーバのアドレスとして読む。
## トンネルの URL は起動ごとに変わるので、友達には「リンク1本」で渡せるようにする
func _server_from_query() -> String:
	if not OS.has_feature("web"):
		return ""
	var q: Variant = JavaScriptBridge.eval(
		"new URLSearchParams(location.search).get('s') || ''", true)
	if typeof(q) != TYPE_STRING:
		return ""
	return (q as String).strip_edges()


func _on_host_pressed() -> void:
	PlayerPrefs.set_nickname(nickname_edit.text)
	if NetworkManager.start_host():
		return
	# 始められなかった（たいていはポートの取り合い）。理由をその場で見せる
	status_label.text = NetworkManager.last_error
	NetworkManager.last_error = ""


func _on_join_pressed() -> void:
	var address := address_edit.text.strip_edges()
	if address.is_empty():
		status_label.text = "ホストのアドレスを入力してください"
		return
	PlayerPrefs.set_nickname(nickname_edit.text)
	NetworkManager.start_client(address)
