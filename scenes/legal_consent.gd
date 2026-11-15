extends Control

## KAN-21: 初回起動（と LegalDocs.VERSION を上げたとき）にタイトル画面へ重ねる同意画面。
## EULA は「利用した時点で同意したとみなす」としているが、課金とオンライン機能があるので
## 明示的に同意を取る。出すかどうかは LegalDocs.needs_consent()（文書が公開済みのときだけ）。
##
## 同意するまで下の画面を触らせない（全面を覆って入力を止める）。「同意しない」は置かない。
## Web 版では終了できず、押しても行き場が無いため。同意できない人には閉じてもらう旨を書く。

signal agreed

var agree_button: Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 100

	var dimmer := ColorRect.new()
	dimmer.color = Color(0, 0, 0, 0.7)
	dimmer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dimmer)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(620, 0)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	panel.add_child(vbox)

	var head := Label.new()
	head.text = tr("はじめに")
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_font_size_override("font_size", 28)
	vbox.add_child(head)

	var body := Label.new()
	body.text = tr("遊ぶ前に、次の文書を読んで同意してください。同意できない場合は、このままゲームを閉じてください。")
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(580, 0)
	vbox.add_child(body)

	for kind in LegalDocs.KINDS:
		var link := LinkButton.new()
		link.text = LegalDocs.title(kind)
		link.pressed.connect(LegalDocs.open.bind(kind))
		vbox.add_child(link)

	agree_button = Button.new()
	agree_button.text = tr("同意して始める")
	agree_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	agree_button.custom_minimum_size = Vector2(240, 0)
	agree_button.pressed.connect(_on_agree_pressed)
	vbox.add_child(agree_button)
	agree_button.grab_focus.call_deferred()


func _on_agree_pressed() -> void:
	LegalDocs.agree()
	agreed.emit()
	queue_free()
