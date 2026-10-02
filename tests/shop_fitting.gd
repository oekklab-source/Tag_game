extends Node

## ショップの「試着しながらコーデを組んでまとめて買う」流れの検証(2026-10-02 の作り直し)。
##
##   pwsh tools/run_headless_test.ps1 res://tests/shop_fitting.tscn
##
## 検証内容:
##   - 入店時は保存済みのコーデで、確定ボタンは押せない
##   - コスチュームを選ぶと、他のキャラでもきょうりゅうに着替えて見本色で試着し、
##     舞台に反映され、未所持の物だけがまとめ買いの対象になる
##   - ジェムが足りなければ買わずにジェム購入を開く
##   - 確認オーバーレイを経てまとめて買い、そのまま保存(着替え)される
##   - 所持品だけの変更は「着替える」で、ジェムを使わず保存される
##   - 「元に戻す」で保存済みのコーデに戻る
##   - プレゼントは最後に選んだ有料品だけ
## ProfileManager の値はメモリ上で書き換える。実セーブは末尾の SaveGuard が戻す。

var _fail := 0


func _ready() -> void:
	print("=== shop_screen 試着・まとめ買いの検証 ===")
	await get_tree().process_frame

	ProfileManager.skin = 1   # しのび(コスチュームが効かないキャラ)
	ProfileManager.costume_id = CostumeCatalog.DEFAULT_ID
	ProfileManager.costume_colors = CostumeCatalog.default_colors(CostumeCatalog.DEFAULT_ID)
	ProfileManager.hat_id = HatCatalog.DEFAULT_ID
	ProfileManager.owned_costumes = CostumeCatalog.default_owned_ids()
	ProfileManager.owned_hats.assign(["none", "party"])
	ProfileManager.premium_currency = 2000

	var shop: Control = load("res://scenes/shop_screen.tscn").instantiate()
	add_child(shop)
	await _frames(3)
	var player: Node3D = shop.stage._player

	# 入店時
	_ok("入店時は保存済みのキャラ(しのび)で試着", player._skin == 1)
	_ok("入店時は確定ボタンが押せない", shop.checkout_btn.disabled)
	_ok("店員さんがいる", shop.stage._shopkeeper != null)
	_ok("店員さんがあいさつする", shop.speech_bubble.visible and shop.speech_label.text != "")

	# コスチュームの試着
	shop._on_costume_pressed(&"gold")
	await _frames(1)
	_ok("コスチュームを選ぶときょうりゅうに着替える", player._skin == 0)
	_ok("舞台にゴールドが反映", player._costume_id == &"gold" and not player._override_keys.is_empty())
	_ok("色は見本色", player._costume_colors == CostumeCatalog.preview_colors(&"gold"))
	_ok("試着中バッジが出る", shop.stage._lock_badge.visible)
	_ok("まとめ買いの対象はゴールドだけ", shop._cart_items().size() == 1)
	_ok("確定ボタンが合計💎500を出す", "500" in shop.checkout_btn.text and not shop.checkout_btn.disabled)

	# 帽子も足す
	shop._on_hat_pressed(&"crown")
	await _frames(1)
	_ok("舞台に王冠が反映", player._hat_id == &"crown")
	_ok("まとめ買いの合計が💎1100", shop._cart_total(shop._cart_items()) == 1100)
	_ok("所持済みの帽子はまとめ買いに入らない", (func():
		shop._on_hat_pressed(&"party")
		return shop._cart_items().size() == 1).call())
	shop._on_hat_pressed(&"crown")

	# ジェム不足
	ProfileManager.premium_currency = 100
	shop._on_checkout_pressed()
	_ok("ジェム不足なら確認を出さない", not shop.confirm_overlay.visible)
	_ok("ジェム不足ならジェム購入を開く", shop.gem_overlay.visible)
	_ok("ジェム不足では何も買わない", not ProfileManager.owns_costume(&"gold") and ProfileManager.premium_currency == 100)
	shop._close_gem_overlay()

	# まとめ買い
	ProfileManager.premium_currency = 2000
	shop._on_checkout_pressed()
	_ok("購入前に確認オーバーレイが出る", shop.confirm_overlay.visible)
	_ok("確認文に合計が入る", "1100" in shop.confirm_message_label.text)
	_ok("確認だけではまだ買わない", not ProfileManager.owns_costume(&"gold"))
	shop._on_confirm_buy_pressed()
	await _frames(1)
	_ok("ゴールドと王冠を所持", ProfileManager.owns_costume(&"gold") and ProfileManager.owns_hat(&"crown"))
	_ok("ジェムが1100減る", ProfileManager.premium_currency == 900)
	_ok("購入したコーデに着替えて保存", ProfileManager.skin == 0 and ProfileManager.costume_id == &"gold"
		and ProfileManager.hat_id == &"crown")
	_ok("見本色のまま保存", ProfileManager.costume_colors == CostumeCatalog.preview_colors(&"gold"))
	_ok("購入後は確定ボタンが押せない", shop.checkout_btn.disabled)
	_ok("購入後は試着中バッジが消える", not shop.stage._lock_badge.visible)

	# 所持品だけの変更(色)
	shop._on_slot_color_pressed(0, OutfitCards.PALETTE_COLORS[0])
	_ok("色を変えると「着替える」になる", not shop.checkout_btn.disabled and shop._cart_items().is_empty())
	shop._on_checkout_pressed()
	_ok("着替えはジェムを使わない", ProfileManager.premium_currency == 900)
	_ok("変えた色が保存される", ProfileManager.costume_colors[0] == OutfitCards.PALETTE_COLORS[0])
	_ok("着替えに確認は出ない", not shop.confirm_overlay.visible)

	# 元に戻す
	shop._on_hat_pressed(&"wizard")
	shop._on_reset_pressed()
	await _frames(1)
	_ok("「元に戻す」で保存済みの帽子に戻る", shop._sel_hat == &"crown" and player._hat_id == &"crown")

	# プレゼント(Web 版では常に無効なので、デスクトップでのみ確認)
	if not OS.has_feature("web"):
		shop._on_hat_pressed(&"wizard")
		_ok("有料品を選ぶとプレゼントできる", not shop.gift_btn.disabled)
		shop._on_hat_pressed(&"propeller")
		_ok("無料品はプレゼントできない", shop.gift_btn.disabled)

	shop.queue_free()
	print("=== %s ===" % ("すべての検証に合格しました" if _fail == 0
		else "%d 件の検証に失敗しました" % _fail))
	get_tree().quit(1 if _fail > 0 else 0)


func _frames(n: int) -> void:
	for i in n:
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
