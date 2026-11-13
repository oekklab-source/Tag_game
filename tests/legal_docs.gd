extends Node

## 法務3文書への導線と同意画面の検証（KAN-20 / KAN-21 / KAN-27）
##
##   pwsh tools/run_headless_test.ps1 res://tests/legal_docs.tscn
##
## 検証内容:
##   - 公開前（LegalDocs の URL が空）は、同意画面もリンクも出ない
##   - 公開後（テスト用の URL を差し込む）は、未同意ならタイトルに同意画面が出て、
##     同意すると版がプロフィールに残り、次からは出ない
##   - 公開後は、クレジット画面とジェム購入の画面に3文書へのリンクが出る
##   - ジェムパックの購入確認に、税込の価格・付与数・支払と付与の時期・返金不可・
##     未成年への注意が出て、特商法の表記へのリンクはジェムパックのときだけ出る
## ProfileManager の値はメモリ上で書き換える。実セーブは末尾の SaveGuard が戻す。

const FAKE_URLS := {
	&"terms": "https://example.invalid/terms",
	&"privacy": "https://example.invalid/privacy",
	&"tokushoho": "https://example.invalid/tokushoho",
}

var _fail := 0


func _ready() -> void:
	print("=== 法務文書の導線と同意画面の検証 ===")
	await get_tree().process_frame

	# 公開前
	LegalDocs.url_override = {}
	ProfileManager.legal_agreed_version = 0
	_ok("公開前は published() が false", not LegalDocs.published())
	_ok("公開前は同意画面を出さない", not LegalDocs.needs_consent())
	var title: Control = load("res://scenes/title.tscn").instantiate()
	add_child(title)
	await _frames(3)
	_ok("公開前はタイトルに同意画面が無い", _consent_of(title) == null)
	title.queue_free()
	var credits: Control = load("res://scenes/credits_screen.tscn").instantiate()
	add_child(credits)
	await _frames(2)
	_ok("公開前はクレジット画面にリンクが無い", _links_in(credits).is_empty())
	credits.queue_free()
	await _frames(2)

	# 1つだけ欠けていても出さない（読めない文書への同意になるため）
	LegalDocs.url_override = {&"terms": FAKE_URLS[&"terms"], &"privacy": FAKE_URLS[&"privacy"]}
	_ok("1つ欠けていれば published() は false", not LegalDocs.published())

	# 公開後
	LegalDocs.url_override = FAKE_URLS
	_ok("公開後は未同意なら同意画面を出す", LegalDocs.needs_consent())
	title = load("res://scenes/title.tscn").instantiate()
	add_child(title)
	await _frames(3)
	var consent := _consent_of(title)
	_ok("公開後はタイトルに同意画面が出る", consent != null)
	if consent != null:
		_ok("同意画面に3文書のリンクがある", _links_in(consent).size() == 3)
		consent.agree_button.pressed.emit()
		await _frames(2)
		_ok("同意すると同意画面が消える", _consent_of(title) == null)
	_ok("同意した版がプロフィールに残る", ProfileManager.legal_agreed_version == LegalDocs.VERSION)
	_ok("同意後は同意画面を出さない", not LegalDocs.needs_consent())
	_ok("同意した版は保存データに入る",
		int(ProfileManager.to_save_dict().get("legal_agreed_version", -1)) == LegalDocs.VERSION)
	title.queue_free()
	await _frames(2)

	credits = load("res://scenes/credits_screen.tscn").instantiate()
	add_child(credits)
	await _frames(2)
	_ok("公開後はクレジット画面に3文書のリンクがある", _links_in(credits).size() == 3)
	credits.queue_free()

	# ショップ
	var text: String = load("res://scenes/shop_screen.gd").pack_confirm_text(&"small")
	var def := CurrencyPackCatalog.get_def(&"small")
	_ok("購入確認に税込の価格", text.contains(String(def.get("display_price", ""))) and text.contains("税込"))
	_ok("購入確認に付与数", text.contains("💎%d" % int(def.get("gems", 0))))
	_ok("購入確認に支払時期と付与時期", text.contains("お支払い") and text.contains("ジェムの付与"))
	_ok("購入確認に返金不可", text.contains("返金はできません"))
	_ok("購入確認に未成年への注意", text.contains("保護者の同意"))

	var shop: Control = load("res://scenes/shop_screen.tscn").instantiate()
	add_child(shop)
	await _frames(3)
	_ok("公開後はジェム購入の画面に3文書のリンクがある", _links_in(shop.gem_overlay).size() == 3)
	shop._on_buy_pack_pressed(&"small", Button.new())
	_ok("ジェムパックの購入確認には特商法のリンクが出る", shop._confirm_legal_link.visible)
	shop._close_confirm_overlay()
	shop._open_confirm_overlay("test", func(): pass)
	_ok("ジェムで買うアイテムの確認には特商法のリンクを出さない", not shop._confirm_legal_link.visible)
	shop.queue_free()

	LegalDocs.url_override = {}
	await _frames(2)
	print("=== 法務文書の結果: %s ===" % ("ALL OK" if _fail == 0 else "%d 件 FAIL" % _fail))
	get_tree().quit()


func _consent_of(title: Node) -> Node:
	for c in title.get_children():
		if c.get_script() == preload("res://scenes/legal_consent.gd") and not c.is_queued_for_deletion():
			return c
	return null


func _links_in(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	for n in root.find_children("*", "LinkButton", true, false):
		if n.visible:
			out.append(n)
	return out


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _ok(label: String, cond: bool) -> void:
	if not cond:
		_fail += 1
	print("  %s: %s" % [label, "OK" if cond else "FAIL"])


# --- 実セーブ(user://profile.json / settings.json)とクラウドセーブの保護 ---
# 同意すると save_profile() を踏むので必須。詳細は tests/save_guard.gd のヘッダ。
const _SaveGuard := preload("res://tests/save_guard.gd")
var _save_backup := {}


func _enter_tree() -> void:
	_save_backup = _SaveGuard.backup()


func _exit_tree() -> void:
	_SaveGuard.restore(_save_backup)
