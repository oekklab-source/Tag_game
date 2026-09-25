extends Node

## 現在のタイトル画面から開く「きせかえ」に、キャラクター選択が実際に表示され、
## 3Dプレビューと固定デザイン用のUI制御まで接続されていることを確認する。
## 保存ボタンは押さないため、user://profile.json は変更しない。


func _ready() -> void:
	# L-09: 日本語の原文を照合するので、OS の言語(英語環境なら en)に関係なく ja に固定する
	TranslationServer.set_locale("ja")
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

# --- 実セーブ(user://profile.json / settings.json)とクラウドセーブの保護 ---
# ラウンドを回さないテストでも、EOS にログインできる環境では起動時のクラウドセーブ同期が
# 実セーブを書き換える(2026-09-25 に boost_panel の実行中に実測)。どのテストが
# 踏むかを個別に見極めるより、全テストで一律に挟む。詳細は tests/save_guard.gd のヘッダ。
const _SaveGuard := preload("res://tests/save_guard.gd")
var _save_backup := {}


func _enter_tree() -> void:
	_save_backup = _SaveGuard.backup()


func _exit_tree() -> void:
	_SaveGuard.restore(_save_backup)
