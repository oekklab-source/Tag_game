extends Control

## ロビー画面。ホスト開始（PC のみ）またはアドレスを指定して参加する。

@onready var status_label: Label = $CenterContainer/VBox/StatusLabel
@onready var host_button: Button = $CenterContainer/VBox/HostButton
@onready var address_edit: LineEdit = $CenterContainer/VBox/JoinRow/AddressEdit
@onready var join_button: Button = $CenterContainer/VBox/JoinRow/JoinButton


func _ready() -> void:
	# ブラウザは WebSocket サーバになれないため、Web 版ではホスト不可
	if OS.has_feature("web"):
		host_button.visible = false
	status_label.text = NetworkManager.last_error
	NetworkManager.last_error = ""
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)


func _on_host_pressed() -> void:
	NetworkManager.start_host()


func _on_join_pressed() -> void:
	var address := address_edit.text.strip_edges()
	if address.is_empty():
		status_label.text = "Enter the host address"
		return
	NetworkManager.start_client(address)
