extends Node

## プレイヤーのプロフィール情報（名前、カスタムカラー、戦績、レート等）を管理・保存する Autoload。
## user://profile.json にローカル保存し、EOS が利用可能な場合は初期値を EOS から取得する。

signal profile_updated

const SAVE_PATH := "user://profile.json"
const SCHEMA_VERSION := 5
## 多重起動防止用ロックファイル。SAVE_PATHは同一PC上の全プロセス共通の1ファイルなので、
## 2つ目のプロセスが後からsave_profile()すると1つ目の変更(プレゼント受領等)を
## 丸ごと上書きして消してしまう(実機で発生: 接続トラブル対応中に多重起動し、
## 友達から届いたプレゼントが消えた)。_ready()で他プロセスの生存を確認して防ぐ
##
## 既知の許容リスク(意図的に未対策): OSがPIDを再利用した場合、既に終了した旧プロセスの
## PIDを別の無関係なプロセスが引き継いでいると誤って「起動中」と判定しうる。発生には
## 旧プロセスのクラッシュ直後に他プロセスがPID空間を一巡するほど大量に起動される必要があり
## 確率は極めて低いため、プロセス開始時刻の照合(WMI/PowerShell呼び出しが必要)までは行わない
const INSTANCE_LOCK_PATH := "user://instance.lock"
var _holds_instance_lock := false

var player_name: String = "Player"
## ④現在選択中のコスチュームの色見本1つ目のミラー。costume_colors[0] と常に一致させ、
## 旧セーブとの互換・タイトルバッジ等の簡易表示に使う
var body_color: Color = Color(0.25, 0.65, 0.95)   # デフォルトの爽やかなブルー
var icon_id: int = 0

# ④コスチューム
var costume_id: StringName = CostumeCatalog.DEFAULT_ID
var costume_colors: PackedColorArray = PackedColorArray([Color(0.25, 0.65, 0.95)])
var owned_costumes: Array[String] = ["default"]

# ⑤帽子（新規ジオメトリの部位、コスチュームとは独立して組み合わせる）
var hat_id: StringName = HatCatalog.DEFAULT_ID
var owned_hats: Array[String] = ["none"]

## ②課金コンテンツ用のゲーム内通貨（モック実装。実際の決済は行わず、
## PurchaseManager 経由でのみ増減する）
var premium_currency: int = 0

# 戦績・レート（ランク戦のみ）
var rating: int = 1500
var matches_played: int = 0
var runner_wins: int = 0
var hunter_wins: int = 0
var highest_rating: int = 1500
## ①VS CPU戦（練習モード）の対戦回数。レート・勝敗数（matches_played等）には含めない
var casual_matches_played: int = 0

## ⑥クラウド同期用の最終更新時刻(UNIX秒)。save_profile() の度に更新され、
## merge_server_inventory() でのLWW判定・クラウドとの新旧比較に使う
var last_modified_unix: int = 0


func _ready() -> void:
	if not _acquire_instance_lock():
		return
	load_profile()


func _exit_tree() -> void:
	# 自分が持っているロックだけを消す。多重起動で弾かれた側(ロックを書いていない)が
	# 終了時に正規プロセスのロックを消してしまうと、以後の多重起動チェックが無効になる
	if _holds_instance_lock and FileAccess.file_exists(INSTANCE_LOCK_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(INSTANCE_LOCK_PATH))


## Web版は複数タブが同じuser://を共有する形がOSプロセスの多重起動とは違う
## (PIDで生死を判定する手段が無い)ため対象外。前回のロックが残っていても、
## そのPIDが既に終了していれば(前回クラッシュ等)古いロックとみなして起動を許可する。
## ヘッドレス(tests/)も対象外: net_anim.tscn等は同一プロジェクトを
## `-- host` / `-- client` で意図的に複数プロセス同時起動する(README参照)ため、
## ここで弾くとテストが軒並み動かなくなる
func _acquire_instance_lock() -> bool:
	if OS.has_feature("web") or DisplayServer.get_name() == "headless":
		return true
	if _other_instance_holds_lock():
		OS.alert(
			"Tag_Game は既に起動しています。\n"
			+ "二重に起動すると、セーブデータ（プレゼントの受け取り等）が正しく保存されないことがあります。\n"
			+ "先に起動しているウィンドウを閉じてから、もう一度起動してください。",
			"多重起動を検出しました")
		get_tree().quit()
		return false
	var out := FileAccess.open(INSTANCE_LOCK_PATH, FileAccess.WRITE)
	if out:
		out.store_string(str(OS.get_process_id()))
		out.close()
	# TOCTOU対策: 直前の_other_instance_holds_lock()チェックとこの書き込みの間には
	# 排他が無いため、ほぼ同時に別プロセスが起動しているとお互いの存在確認をすり抜けて
	# 両方とも書き込みに進んでしまいうる。書き込み直後に読み直し、自分のPIDのままか
	# (=最後に書いたのが自分か)を確認することでこのレースの窓を大きく縮める
	# (ファイルロック等を使わない簡易ロックのため、理論上完全な排他ではない)
	if _other_instance_holds_lock():
		return false
	_holds_instance_lock = true
	return true


## ロックファイルが自分以外の生存プロセスのPIDを指しているか
func _other_instance_holds_lock() -> bool:
	if not FileAccess.file_exists(INSTANCE_LOCK_PATH):
		return false
	var f := FileAccess.open(INSTANCE_LOCK_PATH, FileAccess.READ)
	var pid := int(f.get_as_text()) if f else -1
	return pid > 0 and pid != OS.get_process_id() and OS.is_process_running(pid)


## プロフィールの読み込み
func load_profile() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if file:
			var text := file.get_as_text()
			var json := JSON.new()
			if json.parse(text) == OK and typeof(json.data) == TYPE_DICTIONARY:
				_apply_data(json.data)
				return

	# 初回起動時: EOS があれば EOS 名を取得、無ければランダム名を生成
	_init_default_name()
	save_profile()


## 読み込んだ JSON 辞書をインスタンス変数へ反映する（ファイルI/Oを含まない純粋な部分）。
## tests/costume_model.gd から旧セーブ（schema_version無し）の移行を検証する際にも使う
func _apply_data(data: Dictionary) -> void:
	player_name = data.get("player_name", player_name)
	if data.has("body_color"):
		body_color = Color.html(data.get("body_color", body_color.to_html()))
	icon_id = int(data.get("icon_id", icon_id))
	rating = int(data.get("rating", rating))
	matches_played = int(data.get("matches_played", matches_played))
	runner_wins = int(data.get("runner_wins", runner_wins))
	hunter_wins = int(data.get("hunter_wins", hunter_wins))
	highest_rating = int(data.get("highest_rating", highest_rating))
	casual_matches_played = int(data.get("casual_matches_played", casual_matches_played))

	# ④コスチューム: schema_version が無い（＝旧セーブ、body_colorしか無い）場合は
	# 選んでいた色を無駄にせず costume_colors[0] に引き継ぎ、costume_id は default にする
	var schema := int(data.get("schema_version", 1))
	if schema < 2:
		costume_id = CostumeCatalog.DEFAULT_ID
		costume_colors = PackedColorArray([body_color])
		owned_costumes = CostumeCatalog.default_owned_ids()
	else:
		costume_id = StringName(data.get("costume_id", String(costume_id)))
		var colors := colors_from_html(data.get("costume_colors", []))
		costume_colors = colors if not colors.is_empty() else PackedColorArray([body_color])
		owned_costumes = _to_string_array(data.get("owned_costumes", ["default"]))
	# 未所持のコスチュームが装備されたまま保存されていた場合（改造されたセーブ、
	# 将来のサーバー権威化での所持リスト縮小など）は、所持を自動付与せず default に戻す。
	# defaultは常に owned_costumes に含める（初回起動時の唯一の保証された所持品）
	if not owned_costumes.has("default"):
		owned_costumes.append("default")
	if not CostumeCatalog.has(costume_id) or not owned_costumes.has(String(costume_id)):
		costume_id = CostumeCatalog.DEFAULT_ID

	# ⑤帽子: schema<3（帽子フィールドが存在しない旧セーブ）は所持済み帽子を初期化する。
	# コスチュームの schema<2 分岐とは独立した条件にしてあるので、schema=2 の既存セーブは
	# 「コスチュームはそのまま読み込み・帽子だけ初期化」という意図通りの挙動になる
	if schema < 3:
		hat_id = HatCatalog.DEFAULT_ID
		owned_hats = HatCatalog.default_owned_ids()
	else:
		hat_id = StringName(data.get("hat_id", String(hat_id)))
		owned_hats = _to_string_array(data.get("owned_hats", ["none"]))
	if not owned_hats.has("none"):
		owned_hats.append("none")
	if not HatCatalog.has(hat_id) or not owned_hats.has(String(hat_id)):
		hat_id = HatCatalog.DEFAULT_ID

	# ②ジェム: schema<4（フィールドが存在しない旧セーブ）は 0 で初期化する
	if schema >= 4:
		premium_currency = int(data.get("premium_currency", premium_currency))
	else:
		premium_currency = 0

	# ⑥クラウド同期用タイムスタンプ: schema<5（フィールドが存在しない旧セーブ）は 0 で初期化する
	if schema >= 5:
		last_modified_unix = int(data.get("last_modified_unix", last_modified_unix))
	else:
		last_modified_unix = 0


## ④HTML文字列配列 <-> PackedColorArray の変換。保存(save_profile)・読み込み(_apply_data)・
## ネットワーク配信(GameManager._my_profile_payload / player.gd._apply_peer_costume)の
## いずれでも同じ表現を使うので、ここに一本化する
static func colors_to_html(colors: PackedColorArray) -> Array:
	var out: Array = []
	for c in colors:
		out.append(c.to_html())
	return out


static func colors_from_html(arr: Array) -> PackedColorArray:
	var out := PackedColorArray()
	for c in arr:
		out.append(Color.html(str(c)))
	return out


static func _to_string_array(raw: Array) -> Array[String]:
	var out: Array[String] = []
	for o in raw:
		out.append(str(o))
	return out


func _init_default_name() -> void:
	# デフォルト名の自動生成（例: Runner_4821）
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	player_name = "Runner_%04d" % rng.randi_range(1000, 9999)


## 現在のプロフィール状態を保存用Dictionaryに変換する(ファイルI/Oを含まない)。
## save_profile()のローカル書き込みと、EosManagerのCloud書き込みの両方で
## 同じ表現を使うため、ここに一本化する
func to_save_dict() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"player_name": player_name,
		"body_color": body_color.to_html(),
		"icon_id": icon_id,
		"costume_id": String(costume_id),
		"costume_colors": colors_to_html(costume_colors),
		"owned_costumes": owned_costumes,
		"hat_id": String(hat_id),
		"owned_hats": owned_hats,
		"premium_currency": premium_currency,
		"rating": rating,
		"matches_played": matches_played,
		"runner_wins": runner_wins,
		"hunter_wins": hunter_wins,
		"highest_rating": highest_rating,
		"casual_matches_played": casual_matches_played,
		"last_modified_unix": last_modified_unix
	}


## プロフィールの保存
func save_profile() -> void:
	last_modified_unix = int(Time.get_unix_time_from_system())
	var data := to_save_dict()
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))
	profile_updated.emit()


## プロフィール名の更新
func update_profile(new_name: String) -> void:
	player_name = new_name.strip_edges()
	if player_name.is_empty():
		player_name = "Player"
	save_profile()


## ④指定コスチュームを所持しているか
func owns_costume(id: StringName) -> bool:
	return owned_costumes.has(String(id))


## ④課金SDK・報酬付与など、コスチュームの所持を追加する唯一の入口。
## 実際の決済・権利確認は呼び出し側の責務で、ここでは所持リストへの追加のみ行う
func grant_costume(id: StringName) -> void:
	if not CostumeCatalog.has(id):
		return
	if not owned_costumes.has(String(id)):
		owned_costumes.append(String(id))
		save_profile()


## ④コスチュームと色を選択する。未所持の場合は何もしない
func set_costume(id: StringName, colors: PackedColorArray) -> void:
	if not owns_costume(id):
		return
	costume_id = id
	costume_colors = colors
	if not colors.is_empty():
		body_color = colors[0]
	save_profile()


## ⑥EOS Player Data Storageから取得した相手側(別端末)のプロフィールをローカルへマージする。
## 単純な上書きではなく、以下のルールでマージする:
##   - 所持品(owned_costumes/owned_hats): 和集合。縮小させない(課金済みアイテムを消さない)
##   - 通貨・見た目等の単純フィールド: last_modified_unix によるLWW(新しい方を採用)
##   - レート/戦績クラスタ: matches_played(単調増加カウンタ)が大きい方を採用(同数ならLWW)。
##     highest_rating のみ常に max(local, remote) を取り、退行させない
func merge_server_inventory(data: Dictionary) -> void:
	var remote_schema := int(data.get("schema_version", 1))
	var remote_ts := int(data.get("last_modified_unix", 0)) if remote_schema >= 5 else 0
	var local_ts_before := last_modified_unix
	var changed := false

	# 所持品: 和集合(縮小させない)
	for c in _to_string_array(data.get("owned_costumes", [])):
		if not owned_costumes.has(c):
			owned_costumes.append(c)
			changed = true
	for h in _to_string_array(data.get("owned_hats", [])):
		if not owned_hats.has(h):
			owned_hats.append(h)
			changed = true

	# 単純フィールド: リモートの方が新しければ採用
	if remote_ts > local_ts_before:
		player_name = data.get("player_name", player_name)
		icon_id = int(data.get("icon_id", icon_id))
		if data.has("body_color"):
			body_color = Color.html(data.get("body_color", body_color.to_html()))
		var remote_costume_id := StringName(data.get("costume_id", String(costume_id)))
		if CostumeCatalog.has(remote_costume_id) and owned_costumes.has(String(remote_costume_id)):
			costume_id = remote_costume_id
			var colors := colors_from_html(data.get("costume_colors", []))
			if not colors.is_empty():
				costume_colors = colors
		var remote_hat_id := StringName(data.get("hat_id", String(hat_id)))
		if HatCatalog.has(remote_hat_id) and owned_hats.has(String(remote_hat_id)):
			hat_id = remote_hat_id
		premium_currency = int(data.get("premium_currency", premium_currency))
		last_modified_unix = remote_ts
		changed = true

	# レート/戦績クラスタ: matches_played が大きい方をクラスタごと採用(同数ならLWW)
	var remote_matches := int(data.get("matches_played", -1))
	if remote_matches >= 0:
		if remote_matches > matches_played or (remote_matches == matches_played and remote_ts > local_ts_before):
			if remote_matches != matches_played:
				rating = int(data.get("rating", rating))
				matches_played = remote_matches
				runner_wins = int(data.get("runner_wins", runner_wins))
				hunter_wins = int(data.get("hunter_wins", hunter_wins))
				casual_matches_played = int(data.get("casual_matches_played", casual_matches_played))
				changed = true
		# highest_rating は勝敗に関わらず常に退行させない(ratchet)
		var remote_highest := int(data.get("highest_rating", highest_rating))
		if remote_highest > highest_rating:
			highest_rating = remote_highest
			changed = true

	if changed:
		save_profile()


## ⑤指定帽子を所持しているか
func owns_hat(id: StringName) -> bool:
	return owned_hats.has(String(id))


## ⑤課金SDK・報酬付与など、帽子の所持を追加する唯一の入口（grant_costume と同じ役割）
func grant_hat(id: StringName) -> void:
	if not HatCatalog.has(id):
		return
	if not owned_hats.has(String(id)):
		owned_hats.append(String(id))
		save_profile()


## ⑤帽子を選択する。未所持の場合は何もしない
func set_hat(id: StringName) -> void:
	if not owns_hat(id):
		return
	hat_id = id
	save_profile()


## ②ジェムを加算する唯一の入口（PurchaseManager の通貨パック購入・GiftManager の
## 送金失敗時の払い戻しから呼ばれる）
func add_currency(amount: int) -> void:
	if amount <= 0:
		return
	premium_currency += amount
	save_profile()


## ②ジェムを消費できるか確認したうえで消費する。残高不足なら何もせず false を返す。
## amount == 0(無料アイテムの購入/プレゼント)は消費不要なのでそのまま true を返す
func spend_currency(amount: int) -> bool:
	if amount < 0 or premium_currency < amount:
		return false
	if amount == 0:
		return true
	premium_currency -= amount
	save_profile()
	return true


## 戦績・レートの更新（ランク戦のみ）
func apply_match_result(delta_rating: int, is_winner: bool, was_runner: bool) -> void:
	rating = max(100, rating + delta_rating)
	highest_rating = max(highest_rating, rating)
	matches_played += 1
	if is_winner:
		if was_runner:
			runner_wins += 1
		else:
			hunter_wins += 1
	save_profile()


## ①VS CPU戦（練習モード）の対戦終了時に呼ぶ。レート・戦績（matches_played等）には影響しない
func record_casual_match() -> void:
	casual_matches_played += 1
	save_profile()
