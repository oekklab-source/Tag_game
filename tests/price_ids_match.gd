extends Node

## ジェムパックの Price ID・ジェム数が、クライアントとサーバーの2か所で一致しているかの検証（KAN-26）
##
##   pwsh tools/run_headless_test.ps1 res://tests/price_ids_match.tscn
##
## Price ID は autoload/currency_pack_catalog.gd と service/commerce-api/src/index.ts の PACKS に
## 重複して書いてある。片方だけ本番の値に変えると、表示と請求がずれるか購入が失敗する。
## サーバーの値はソースの文字列から読む（commerce-api はデプロイしないと動かないため）。

const SERVER_SRC := "res://service/commerce-api/src/index.ts"

var _fail := 0


func _ready() -> void:
	print("=== Price ID の一致の検証 ===")
	var src := FileAccess.get_file_as_string(SERVER_SRC)
	_ok("サーバーのソースを読める", not src.is_empty())
	var server := parse_server_packs(src)
	_ok("サーバーのパックを読み取れた", not server.is_empty())

	var client_ids: Array = []
	for id in CurrencyPackCatalog.ordered_ids():
		client_ids.append(String(id))
	var server_ids: Array = server.keys()
	client_ids.sort()
	server_ids.sort()
	_ok("パックの種類が同じ (%s / %s)" % [client_ids, server_ids], client_ids == server_ids)

	for id in CurrencyPackCatalog.ordered_ids():
		var def := CurrencyPackCatalog.get_def(id)
		var s: Dictionary = server.get(String(id), {})
		_ok("%s: Price ID が一致" % id, String(def.get("stripe_price_id", "")) == String(s.get("price_id", "?")))
		_ok("%s: ジェム数が一致" % id, int(def.get("gems", -1)) == int(s.get("gems", -2)))

	print("=== Price ID の結果: %s ===" % ("ALL OK" if _fail == 0 else "%d 件 FAIL" % _fail))
	get_tree().quit()


## `small: { gems: 300, priceId: "price_xxx" },` の形の行を {id: {gems, price_id}} にする
static func parse_server_packs(src: String) -> Dictionary:
	var out := {}
	var re := RegEx.create_from_string("(\\w+):\\s*\\{\\s*gems:\\s*(\\d+),\\s*priceId:\\s*\"([^\"]+)\"\\s*\\}")
	for m in re.search_all(src):
		out[m.get_string(1)] = {"gems": int(m.get_string(2)), "price_id": m.get_string(3)}
	return out


func _ok(label: String, cond: bool) -> void:
	if not cond:
		_fail += 1
	print("  %s: %s" % [label, "OK" if cond else "FAIL"])


# --- 実セーブ(user://profile.json / settings.json)とクラウドセーブの保護 ---
# このテスト自体は保存しないが、起動時のクラウドセーブ同期を止めるため全テストで挟む。
# 詳細は tests/save_guard.gd のヘッダ。
const _SaveGuard := preload("res://tests/save_guard.gd")
var _save_backup := {}


func _enter_tree() -> void:
	_save_backup = _SaveGuard.backup()


func _exit_tree() -> void:
	_SaveGuard.restore(_save_backup)
