extends Node

## M-10: costume_screenの「戻る」未保存確認ダイアログの検証。
## ProfileManagerの実データを一時的に書き換えて検証し、最後に復元する
## (save_profile()は呼ばないため、ディスクへの書き込みは発生しない)。
##
##   godot --headless --path . res://tests/costume_screen_confirm.tscn

var _fail := 0
var _closed_count := 0


func _ready() -> void:
	print("=== きせかえ画面「戻る」未保存確認の検証 ===")
	await get_tree().process_frame

	var orig_costume_id := ProfileManager.costume_id
	var orig_colors := ProfileManager.costume_colors.duplicate()
	var orig_hat_id := ProfileManager.hat_id
	var orig_owned_costumes := ProfileManager.owned_costumes.duplicate()
	var orig_owned_hats := ProfileManager.owned_hats.duplicate()

	ProfileManager.owned_costumes = ["default"]
	ProfileManager.owned_hats = ["none"]
	ProfileManager.costume_id = CostumeCatalog.DEFAULT_ID
	ProfileManager.costume_colors = PackedColorArray([Color(0.25, 0.65, 0.95)])
	ProfileManager.hat_id = HatCatalog.DEFAULT_ID

	var screen: Control = load("res://scenes/costume_screen.tscn").instantiate()
	add_child(screen)
	screen.closed.connect(func(): _closed_count += 1)
	await get_tree().process_frame
	await get_tree().process_frame

	# [1] 無変更のまま戻る -> 確認なしで即座に離脱
	screen.back_btn.pressed.emit()
	_ok("無変更なら確認オーバーレイが出ない", not screen.confirm_overlay.visible)
	_ok("無変更なら即座にcloseが発火する (%d)" % _closed_count, _closed_count == 1)

	# [2] 未所持コスチュームの試着だけでは確認が出ない(_on_save_pressedが保存しないため対象外)
	screen._selected_costume_id = &"gold"
	screen.back_btn.pressed.emit()
	_ok("未所持コスチュームの試着だけでは確認が出ない", not screen.confirm_overlay.visible)
	_ok("未所持のみなら即座にcloseが発火する (%d)" % _closed_count, _closed_count == 2)
	screen._selected_costume_id = screen._initial_costume_id

	# [3] 所持中コスチュームの色を変更すると確認が出る
	screen._selected_colors[0] = Color(1, 0, 0)
	screen.back_btn.pressed.emit()
	_ok("所持中コスチュームの色変更で確認が出る", screen.confirm_overlay.visible)
	_ok("確認中はcloseが発火しない (%d)" % _closed_count, _closed_count == 2)
	_ok("既定フォーカスは「やめる」", screen.confirm_cancel_btn.has_focus())

	# [4] 「やめる」はオーバーレイを閉じるだけで離脱しない
	screen.confirm_cancel_btn.pressed.emit()
	_ok("「やめる」でオーバーレイが閉じる", not screen.confirm_overlay.visible)
	_ok("「やめる」ではcloseが発火しない (%d)" % _closed_count, _closed_count == 2)

	# [5] もう一度戻る -> 「破棄して戻る」で離脱する
	screen.back_btn.pressed.emit()
	_ok("変更が残ったままなら再度確認が出る", screen.confirm_overlay.visible)
	screen.confirm_discard_btn.pressed.emit()
	_ok("「破棄して戻る」でオーバーレイが閉じる", not screen.confirm_overlay.visible)
	_ok("「破棄して戻る」でcloseが発火する (%d)" % _closed_count, _closed_count == 3)

	screen.queue_free()
	ProfileManager.costume_id = orig_costume_id
	ProfileManager.costume_colors = orig_colors
	ProfileManager.hat_id = orig_hat_id
	ProfileManager.owned_costumes = orig_owned_costumes
	ProfileManager.owned_hats = orig_owned_hats

	print("=== %s ===" % ("すべての検証に合格しました" if _fail == 0
		else "%d 件の検証に失敗しました" % _fail))
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(label: String, cond: bool) -> void:
	if not cond:
		_fail += 1
	print("  %s: %s" % [label, "OK" if cond else "FAIL"])

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
