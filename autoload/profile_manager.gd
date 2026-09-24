extends Node

## プレイヤーのプロフィール情報（名前、カスタムカラー、戦績、レート等）を管理・保存する Autoload。
## user://profile.json にローカル保存し、EOS が利用可能な場合は初期値を EOS から取得する。

signal profile_updated

const SAVE_PATH := "user://profile.json"
const SCHEMA_VERSION := 6
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

## M-11: 名前バリデーション(sanitize_name/name_error)で使う定数
const MAX_NAME_LENGTH := 16
## NGワードの最小セット(運営/管理者への成りすまし対策のみ)。実運用の辞書拡張は
## コンテンツポリシー側の判断であり、ここはプレースホルダー
const NG_WORDS: PackedStringArray = [
	"admin", "administrator", "gm", "運営", "モデレーター", "management",
]

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

## 着せ替えのキャラ（Humanoid.SKINS の添字）。全キャラ最初から使えるので所持管理はしない。
## 範囲外の保存値は読み込み時に 0 へ丸める
var skin: int = 0

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

## C-03 R-4: /claim-initial-ratingへの初回登録がサーバー側で既に成功済みか。
## 一度trueになったら再claimしない一方向ラッチ。サーバー側のalready_claimed拒否は
## 安全網であって主ガードではない(再claimするとサーバー側matches_played/winsが
## 0から作り直されてしまうため、ローカルにも記録を残す)
var initial_rating_claimed: bool = false


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
		# M-12対策: このダイアログはOS標準のもので見た目はゲームと揃わないが、
		# 表示できるUIツリーがまだ無い最初期(autoload._ready())で発生するため
		# ゲーム内スタイルのパネルには置き換えられない(README/CLAUDE.md参照)。
		# 文言だけでも「なぜ・これからどうなるか」を明確にしておく
		OS.alert(
			"Tag_Game はすでに別のウィンドウで起動しています。\n\n"
			+ "同時に起動したままだと、セーブデータ（プレゼントの受け取りなど）が正しく"
			+ "保存されないことがあるため、このウィンドウはこのまま終了します。\n\n"
			+ "先に起動しているウィンドウを閉じてから、もう一度起動しなおしてください。",
			"多重起動のため、このウィンドウは終了します")
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
	# フィールドが無い旧セーブは 0（きょうりゅう）になるので schema は上げない
	skin = _clamp_skin(int(data.get("skin", 0)))

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

	# C-03 R-4: schema<6（フィールドが存在しない旧セーブ）は false で初期化する
	if schema >= 6:
		initial_rating_claimed = bool(data.get("initial_rating_claimed", initial_rating_claimed))
	else:
		initial_rating_claimed = false


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
		"skin": skin,
		"premium_currency": premium_currency,
		"rating": rating,
		"matches_played": matches_played,
		"runner_wins": runner_wins,
		"hunter_wins": hunter_wins,
		"highest_rating": highest_rating,
		"casual_matches_played": casual_matches_played,
		"last_modified_unix": last_modified_unix,
		"initial_rating_claimed": initial_rating_claimed
	}


## プロフィールの保存
func save_profile() -> void:
	last_modified_unix = int(Time.get_unix_time_from_system())
	var data := to_save_dict()
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))
	profile_updated.emit()


## 前後・連続する空白の圧縮、16文字への切り詰め、空文字のフォールバックを行う。
## 失敗しない(例外を投げない)自動整形のみを担当する
static func sanitize_name(raw: String) -> String:
	var s := raw.strip_edges()
	s = s.replace("　", " ")
	var re := RegEx.new()
	re.compile("[ \\t]+")
	s = re.sub(s, " ", true)
	s = s.strip_edges()
	if s.length() > MAX_NAME_LENGTH:
		s = s.substr(0, MAX_NAME_LENGTH).strip_edges()
	if s.is_empty():
		s = "Player"
	return s


## sanitize_name()適用後の名前を検査し、NGワードを含む場合はエラー文言を返す。
## 問題なければ空文字を返す
static func name_error(name: String) -> String:
	var lower := name.to_lower()
	for w in NG_WORDS:
		if lower.contains(w.to_lower()):
			return "使用できない言葉が含まれています"
	return ""


## プロフィール名の更新。整形→検査の順で行い、エラーがあれば保存せず文言を返す
## (空文字="" は成功を表す)
func update_profile(new_name: String) -> String:
	var sanitized := sanitize_name(new_name)
	var err := name_error(sanitized)
	if not err.is_empty():
		return err
	player_name = sanitized
	save_profile()
	return ""


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


func set_skin(id: int) -> void:
	skin = _clamp_skin(id)
	save_profile()


## キャラの一覧は Humanoid が持つ。設定ファイルに古い/壊れた値が入っていても
## 落ちないよう、読み込み時と保存時の両方でここを通す
static func _clamp_skin(id: int) -> int:
	return id if id >= 0 and id < Humanoid.SKINS.size() else 0


## ⑥EOS Player Data Storageから取得した相手側(別端末)のプロフィールをローカルへマージする。
## 単純な上書きではなく、以下のルールでマージする:
##   - 所持品(owned_costumes/owned_hats): 和集合。縮小させない(課金済みアイテムを消さない)
##   - 通貨・見た目等の単純フィールド: last_modified_unix によるLWW(新しい方を採用)
##   - レート/戦績クラスタ: matches_played(単調増加カウンタ)が大きい方を採用(同数ならLWW)。
##     highest_rating のみ常に max(local, remote) を取り、退行させない
##   - C-03 R-4: BackendConfig.USE_LIVE_RATING_BACKENDがtrueの間は、rating/matches_played/
##     runner_wins/hunter_wins/highest_ratingをこの関数では一切書き換えない(casual_matches_played
##     はランク戦スコープ外なので従来通り常時マージする)。これらのフィールドはrating-api(D1)が
##     唯一の権威になり、EosManager.eos_initialized後にRankingManager._reconcile_server_rating()が
##     /ratingから確定値を反映する。ここでPDS由来の値を先に適用してreconciliationに任せる設計には
##     しない――reconciliationはネットワークエラー・レート制限で黙って失敗しうるfire-and-forget
##     経路なので、「後で直る」に依存すると失敗時に別デバイスの陳腐化したPDSスナップショットが
##     そのまま残ってしまう。何もしない方が安全
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
		skin = _clamp_skin(int(data.get("skin", skin)))
		premium_currency = int(data.get("premium_currency", premium_currency))
		last_modified_unix = remote_ts
		changed = true

	# レート/戦績クラスタ: matches_played が大きい方をクラスタごと採用(同数ならLWW)。
	# casual_matches_playedはランク戦スコープ外なので、rating側の除外条件とは独立に常時マージする
	var remote_matches := int(data.get("matches_played", -1))
	if remote_matches >= 0:
		if remote_matches > matches_played or (remote_matches == matches_played and remote_ts > local_ts_before):
			if remote_matches != matches_played and not BackendConfig.USE_LIVE_RATING_BACKEND:
				rating = int(data.get("rating", rating))
				matches_played = remote_matches
				runner_wins = int(data.get("runner_wins", runner_wins))
				hunter_wins = int(data.get("hunter_wins", hunter_wins))
				changed = true
			# C-03 R-12(RV-13): 実際に値が変わったときだけ changed を立てる。
			# 無条件に立てていたため、USE_LIVE_RATING_BACKEND=true のときに
			# matches_played をリモートから採らない(上のガード)せいで
			# remote_matches > matches_played が永久に真になり、クラウド同期のたびに
			# save_profile() -> profile_updated -> GameManager._on_profile_updated()
			# -> broadcast_my_profile() が無駄に走っていた
			var remote_casual := int(data.get("casual_matches_played", casual_matches_played))
			if remote_casual != casual_matches_played:
				casual_matches_played = remote_casual
				changed = true
		if not BackendConfig.USE_LIVE_RATING_BACKEND:
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


## C-03 R-3: rating-apiが確定したレートで、apply_match_result()が既にローカル計算・反映
## 済みのratingを黙って上書き補正する。matches_played/runner_wins/hunter_winsは
## apply_match_result()で既に加算済みのため、ここでは絶対に触らない(二重加算防止)。
## highest_ratingのみ既存同様ratchet(後退させない)
func apply_server_rating_correction(new_rating: int) -> void:
	rating = maxi(100, new_rating)
	highest_rating = max(highest_rating, rating)
	save_profile()


## C-03 R-4: /claim-initial-ratingが成功した直後に呼ぶ唯一の入口。
## ratingは変更しない(送ったローカル値をサーバーがそのまま採用しただけで補正ではない)
func mark_initial_rating_claimed() -> void:
	if initial_rating_claimed:
		return
	initial_rating_claimed = true
	save_profile()


## C-03 R-4: 起動時reconciliation(RankingManager._reconcile_server_rating())専用の
## フルスナップショット反映。apply_server_rating_correction()(試合直後のRPC経由、
## rating+highest_ratingのみで呼び出し文脈も違う)とは別関数として維持する。
##
## matches_played/runner_wins/hunter_winsには一切触れない(設計判断、意図的):
## サーバー側のこれらのカウンタは/claim-initial-rating実行時点から0で数え直される
## 「claim後カウンタ」であり、ローカルの通算カウンタとは意味が違う。上書きすると
## claim以前の全戦績表示が消える(claimは既存プレイヤーにも起こりうるタイミングなので
## 無視できない実害)。ratingは対戦マッチング(tier_lock)・リーダーボードの両方で
## 外部公開される値であり食い違いが実害になるため必ずサーバー値を採用する。
## highest_ratingは既存箇所と同じくratchet(後退させない)のみ行う
func apply_server_rating_snapshot(new_rating: int, server_highest_rating: int) -> void:
	rating = maxi(100, new_rating)
	highest_rating = maxi(highest_rating, server_highest_rating)
	initial_rating_claimed = true
	save_profile()


## ①VS CPU戦（練習モード）の対戦終了時に呼ぶ。レート・戦績（matches_played等）には影響しない
func record_casual_match() -> void:
	casual_matches_played += 1
	save_profile()
