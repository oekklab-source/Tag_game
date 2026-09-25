extends Node

## M-01: shop_screenのアイテムカードに追加した3Dプレビューの検証。
## request_static_render()の適用漏れ(=最大10件同時生成時のGPU負荷退行)と、
## costume/hatカードの見た目の出し分けをheadlessで検知する。
##
##   godot --headless --path . res://tests/shop_preview_perf.tscn
##
## 実際の描画負荷(GPU使用率)そのものはheadlessでは確認できないため、
## 実機での目視確認と併用すること(計画ファイル参照)

var _fail := 0


func _ready() -> void:
	print("=== shop_screen プレビュー静止化・出し分けの検証 ===")
	await get_tree().process_frame

	var shop: Control = load("res://scenes/shop_screen.tscn").instantiate()
	add_child(shop)
	# call_deferredで登録されたプレビュー反映処理が確実に消化されるまで数フレーム待つ
	for i in 3:
		await get_tree().process_frame

	var costume_ids := CostumeCatalog.purchasable_ids()
	var hat_ids := HatCatalog.purchasable_ids()
	var expected_count := costume_ids.size() + hat_ids.size()

	var cards: Array = shop.item_grid.get_children()
	_ok("カード数がpurchasable_ids合計と一致 (期待%d件, 実際%d件)" % [expected_count, cards.size()],
		cards.size() == expected_count)

	for i in cards.size():
		var box: PanelContainer = cards[i]
		var vbox: VBoxContainer = box.get_child(0)
		var preview: Control = vbox.get_child(0)
		_ok("カード%d: request_static_renderが適用されている" % i,
			preview._viewport.render_target_update_mode == SubViewport.UPDATE_ONCE)
		if i < costume_ids.size():
			var id: StringName = costume_ids[i]
			_ok("costumeカード[%s]: 該当コスチュームを試着している" % id,
				preview._humanoid._costume_id == id)
		else:
			var id: StringName = hat_ids[i - costume_ids.size()]
			_ok("hatカード[%s]: 該当帽子を試着している" % id,
				preview._humanoid._hat_id == id)

	shop.queue_free()
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
