extends Node

## プレイヤーのプロフィール情報（名前、カスタムカラー、戦績、レート等）を管理・保存する Autoload。
## user://profile.json にローカル保存し、Steam が利用可能な場合は初期値を Steam から取得する。

signal profile_updated

const SAVE_PATH := "user://profile.json"
const SCHEMA_VERSION := 3

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

# 戦績・レート（ランク戦のみ）
var rating: int = 1500
var matches_played: int = 0
var runner_wins: int = 0
var hunter_wins: int = 0
var highest_rating: int = 1500
## ①VS CPU戦（練習モード）の対戦回数。レート・勝敗数（matches_played等）には含めない
var casual_matches_played: int = 0


func _ready() -> void:
	load_profile()


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

	# 初回起動時: Steam があれば Steam 名を取得、無ければランダム名を生成
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


## プロフィールの保存
func save_profile() -> void:
	var colors_html := colors_to_html(costume_colors)
	var data := {
		"schema_version": SCHEMA_VERSION,
		"player_name": player_name,
		"body_color": body_color.to_html(),
		"icon_id": icon_id,
		"costume_id": String(costume_id),
		"costume_colors": colors_html,
		"owned_costumes": owned_costumes,
		"hat_id": String(hat_id),
		"owned_hats": owned_hats,
		"rating": rating,
		"matches_played": matches_played,
		"runner_wins": runner_wins,
		"hunter_wins": hunter_wins,
		"highest_rating": highest_rating,
		"casual_matches_played": casual_matches_played
	}
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


## ④将来のサーバー権威化用スタブ。サーバーから配られた所持データで上書きする
func merge_server_inventory(data: Dictionary) -> void:
	var raw_owned: Array = data.get("owned_costumes", [])
	if not raw_owned.is_empty():
		owned_costumes = _to_string_array(raw_owned)
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
