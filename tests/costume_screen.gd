extends Node

## 現在のタイトル画面から開く「きせかえ」に、キャラクター選択が実際に表示され、
## 3Dプレビューと固定デザイン用のUI制御まで接続されていることを確認する。
## 保存ボタンは押さないため、user://profile.json は変更しない。


func _ready() -> void:
	var screen: Control = load("res://scenes/costume_screen.tscn").instantiate()
	add_child(screen)
	await get_tree().process_frame

	var skin_grid: GridContainer = screen.skin_grid
	assert(skin_grid.get_child_count() == Humanoid.SKINS.size())
	assert(_card_name(skin_grid, 0) == "きょうりゅう")
	assert(_card_name(skin_grid, 1) == "しのび")
	assert(_card_name(skin_grid, 2) == "バスケ08")

	screen._on_skin_button_pressed(1)
	assert(screen._selected_skin == 1)
	assert(screen.preview._humanoid._skin == 1)
	assert(screen.category_costume_btn.disabled)
	assert(screen.category_color_btn.disabled)
	assert(not screen.category_hat_btn.disabled)

	screen._on_skin_button_pressed(2)
	assert(screen.preview._humanoid._skin == 2)
	assert(screen.hint_label.text.contains("固定デザイン"))

	screen._on_skin_button_pressed(0)
	assert(not screen.category_costume_btn.disabled)
	assert(not screen.category_color_btn.disabled)

	print("COSTUME SCREEN: ALL OK")
	get_tree().quit()


func _card_name(grid: GridContainer, index: int) -> String:
	var card := grid.get_child(index)
	return card.get_child(0).text
