extends Node

## ショップの店員さんの動き(見る相手・歩く・反応・吹き出しの追従)の検証。
##
##   pwsh tools/run_headless_test.ps1 res://tests/shop_clerk.tscn
##
## shop_stage.tick() を固定の刻みで直接呼んで進める(実時間に依存させない)。
## ちら見は乱数で起きるので、確かめる区間以外では _next_glance を大きくして止めておく。
## ProfileManager の値はメモリ上で書き換える。実セーブは末尾の SaveGuard が戻す。

const STEP := 1.0 / 30.0
const DEG := PI / 180.0

var _fail := 0
var _shop: Control
var _stage: Control


func _ready() -> void:
	print("=== shop_stage 店員さんの動きの検証 ===")
	await get_tree().process_frame

	ProfileManager.skin = 0
	ProfileManager.costume_id = CostumeCatalog.DEFAULT_ID
	ProfileManager.costume_colors = CostumeCatalog.default_colors(CostumeCatalog.DEFAULT_ID)
	ProfileManager.hat_id = HatCatalog.DEFAULT_ID
	ProfileManager.owned_costumes = CostumeCatalog.default_owned_ids()
	ProfileManager.owned_hats.assign(["none"])
	ProfileManager.premium_currency = 2000

	_shop = load("res://scenes/shop_screen.tscn").instantiate()
	add_child(_shop)
	await get_tree().process_frame
	await get_tree().process_frame
	_stage = _shop.stage
	_stage.set_process(false)   # 進めるのはこのテストの tick だけにする
	_shop.set_process(false)
	_stage._next_glance = 999.0

	var cam: Vector3 = _stage._camera.position
	var avatar: Vector3 = _stage._turntable.position + Vector3.UP * _stage.AVATAR_HEAD_Y

	# 待機: カウンターの奥でお客さん(カメラ)を向く
	_run(1.0)
	_ok("待機中はカウンターの奥にいる", _clerk_at(_stage.CLERK_HOME))
	_ok("待機中はお客さんの方を向く", _stage.clerk_facing_error(cam) < 8 * DEG)
	_shop._process(0.0)
	var bubble_home: Vector2 = _shop.speech_bubble.position

	# 試着されたら、接客位置まで歩いて来てアバターを見る
	_shop._on_costume_pressed(&"sakura")
	_run(0.15)
	_ok("試着されると歩き出す", _stage._clerk_speed > 0.0)
	_run(1.0)
	_ok("接客位置(カウンターの端)に着く", _clerk_at(_stage.CLERK_ASSIST))
	_ok("着いたらアバターを見る", _stage.clerk_facing_error(avatar) < 10 * DEG)
	_ok("新しい物なら喜ぶ(Nice)", _stage._shopkeeper._emote == _stage.EMOTE_NICE)
	_shop._process(0.0)
	_ok("吹き出しが店員さんに付いて動く (%.0f → %.0f)" % [bubble_home.x, _shop.speech_bubble.position.x],
		absf(_shop.speech_bubble.position.x - bubble_home.x) > 40.0)

	# 見終わったらお客さんの方へ向き直る
	_run(2.0)
	_ok("見終わったらお客さんへ向き直る", _stage.clerk_facing_error(cam) < 10 * DEG)
	_ok("向き直っても接客位置に留まる", _clerk_at(_stage.CLERK_ASSIST))

	# 持っている物の試着は、見に来るが喜ばない
	_run(3.0)   # 喜びのエモートが終わるまで
	_shop._on_hat_pressed(&"none")   # なし(=所持品)。帽子「なし」はリアクション対象外
	ProfileManager.owned_hats.assign(["none", "party"])
	_shop._on_hat_pressed(&"party")
	_run(0.6)
	_ok("所持品の試着ではアバターを見る", _stage.clerk_facing_error(avatar) < 15 * DEG)
	_ok("所持品の試着では喜ばない", _stage._shopkeeper._emote == 0)

	# しばらく試着が無ければカウンターの奥へ戻る
	_run(_stage.ASSIST_LINGER + 1.5)
	_ok("しばらくするとカウンターの奥へ戻る", _clerk_at(_stage.CLERK_HOME))
	_ok("戻ったらお客さんの方を向く", _stage.clerk_facing_error(cam) < 10 * DEG)

	# 待機中のちら見
	_stage._next_glance = 0.05
	_run(0.6)
	_ok("ときどきアバターをちらっと見る", _stage.clerk_facing_error(avatar) < 15 * DEG)
	_stage._next_glance = 999.0
	_run(_stage.GLANCE_LENGTH + 1.0)
	_ok("ちら見のあとはお客さんへ戻る", _stage.clerk_facing_error(cam) < 10 * DEG)

	# 購入したらお客さんの方を向いて喜ぶ
	_shop._on_costume_pressed(&"gold")
	_run(1.5)
	_shop._on_checkout_pressed()
	_shop._on_confirm_buy_pressed()
	_run(1.0)
	_ok("購入されたら喜ぶ", _stage._shopkeeper._emote == _stage.EMOTE_NICE)
	_ok("購入のお礼はお客さんの方を向いて言う", _stage.clerk_facing_error(cam) < 10 * DEG)

	_shop.queue_free()
	print("=== %s ===" % ("すべての検証に合格しました" if _fail == 0
		else "%d 件の検証に失敗しました" % _fail))
	get_tree().quit(1 if _fail > 0 else 0)


func _run(seconds: float) -> void:
	for i in int(ceil(seconds / STEP)):
		_stage.tick(STEP)


func _clerk_at(point: Vector3) -> bool:
	var p: Vector3 = _stage._shopkeeper_root.position
	return Vector2(p.x - point.x, p.z - point.z).length() < 0.05


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
