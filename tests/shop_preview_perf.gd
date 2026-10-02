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
	await get_tree().process_frame

	await _check_costume_cards_distinguishable()

	print("=== %s ===" % ("すべての検証に合格しました" if _fail == 0
		else "%d 件の検証に失敗しました" % _fail))
	get_tree().quit(1 if _fail > 0 else 0)


## 2026-10-02「ショップが全部同じアバターに見える」の回帰防止。
## 自分のキャラがきょうりゅう以外(コスチュームが効かない)でも、コスチュームカードは
## きょうりゅうで試着し、塗り分けが実際に効き、カードごとに体色が違うこと。
## 帽子カードは従来どおり自分のキャラのままであること
func _check_costume_cards_distinguishable() -> void:
	var orig_skin := ProfileManager.skin
	ProfileManager.skin = 1   # しのび。メモリ上だけ(実セーブは SaveGuard が戻す)
	var shop: Control = load("res://scenes/shop_screen.tscn").instantiate()
	add_child(shop)
	for i in 3:
		await get_tree().process_frame

	var costume_ids := CostumeCatalog.purchasable_ids()
	var cards: Array = shop.item_grid.get_children()
	var body_colors := {}
	for i in cards.size():
		var vbox: VBoxContainer = cards[i].get_child(0)
		var humanoid: Node3D = vbox.get_child(0)._humanoid
		if i < costume_ids.size():
			var id: StringName = costume_ids[i]
			_ok("skin=1でもcostumeカード[%s]はきょうりゅうで試着" % id, humanoid._skin == 0)
			_ok("costumeカード[%s]: 塗り分けが実際に適用されている" % id,
				not humanoid._override_keys.is_empty())
			body_colors[humanoid._costume_colors[0].to_html()] = true
			var has_note := false
			for c in vbox.get_children():
				if c is Label and c.text == tr("きょうりゅう専用"):
					has_note = true
			_ok("costumeカード[%s]: 「きょうりゅう専用」の注記がある" % id, has_note)
		else:
			_ok("hatカード%d: 自分のキャラ(skin=1)のまま" % i, humanoid._skin == 1)
	_ok("costumeカードの体色がすべて異なる (%d種/%d枚)" % [body_colors.size(), costume_ids.size()],
		body_colors.size() == costume_ids.size())

	shop.queue_free()
	ProfileManager.skin = orig_skin
	await get_tree().process_frame


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
