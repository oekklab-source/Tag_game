extends Node

## Steamworks API / GodotSteam のラッパー Autoload。
## GodotSteam が利用可能な場合は Steam API を初期化し、
## P2P ロビー作成、検索、参加、Steam Leaderboards（ランキング）のやり取りを行う。
## Steam 非対応環境（Web版、Steam未起動時等）でもモック動作してクラッシュを防ぐ。

signal steam_initialized(success: bool)
signal lobby_created(connect_status: int, lobby_id: int)
signal lobby_match_list(lobbies: Array)
signal lobby_joined(lobby_id: int, permissions: int, locked: bool, response: int)
signal lobby_chat_update(lobby_id: int, change_id: int, making_change_id: int, chat_state: int)
signal leaderboard_loaded(entries: Array)
signal leaderboard_score_uploaded(success: bool, score: int)

const DEFAULT_APP_ID := 480 # Spacewar (テスト用AppID)
const LEADERBOARD_NAME := "GlobalRating"

var is_steam_available: bool = false
var steam_id: int = 0
var steam_username: String = ""
var current_lobby_id: int = 0
var is_host: bool = false


func _ready() -> void:
	_init_steam()


func _process(_delta: float) -> void:
	if is_steam_available:
		# GodotSteam のコールバックを回す
		if Engine.has_singleton("Steam"):
			Engine.get_singleton("Steam").run_callbacks()


## Steam API の初期化
func _init_steam() -> void:
	# GDExtension / モジュールとしての Steam シングルトンの有無を確認
	if Engine.has_singleton("Steam"):
		var steam = Engine.get_singleton("Steam")
		# ③GodotSteam のバージョンによって steamInitEx の引数順・status の成功値の意味が
		# 変わりうる（例: status==0 が成功、等）。ここを決め打ちすると「実際は成功しているのに
		# 失敗扱いになる」という診断困難な状態になるため、status の値そのものには依存せず、
		# 初期化が本当に通っていれば必ず取得できるはずの SteamID64 で二重に確認する
		var init_res = steam.steamInitEx(DEFAULT_APP_ID, false)
		steam_id = steam.getSteamID()
		if steam_id > 0:
			is_steam_available = true
			steam_username = steam.getPersonaName()
			print("[SteamManager] Steam initialized successfully. User: %s (ID: %d)" % [steam_username, steam_id])
			
			# シグナル接続
			steam.lobby_created.connect(_on_lobby_created)
			steam.lobby_match_list.connect(_on_lobby_match_list)
			steam.lobby_joined.connect(_on_lobby_joined)
			steam.lobby_chat_update.connect(_on_lobby_chat_update)
			steam.leaderboard_scores_downloaded.connect(_on_leaderboard_scores_downloaded)
			steam.leaderboard_score_uploaded.connect(_on_leaderboard_score_uploaded)
			
			# ProfileManager に Steam 名を自動反映（まだデフォルト名の場合など）
			if ProfileManager.player_name.begins_with("Runner_") or ProfileManager.player_name == "Player":
				ProfileManager.player_name = steam_username
				ProfileManager.save_profile()

			# ⑥Steam Cloud とのプロフィール同期。ProfileManager は既にローカルの
			# load_profile() を終えているので(autoload順で先に _ready() が走る)、
			# ここではローカル読み込み後の状態を前提にクラウドとマージ/初回アップロードする
			sync_profile_with_cloud()

			steam_initialized.emit(true)
			return
		else:
			print("[SteamManager] Steam init returned status: ", init_res)
	
	print("[SteamManager] Running in Offline / Fallback mode (Steam API not available).")
	steam_initialized.emit(false)


## ロビー作成
func create_lobby(lobby_type: int = 0, max_members: int = 8, lobby_name: String = "") -> void:
	if lobby_name.is_empty():
		lobby_name = "%s's Room" % ProfileManager.player_name
		
	if is_steam_available:
		var steam = Engine.get_singleton("Steam")
		# 0 = Private, 1 = FriendsOnly, 2 = Public, 3 = Invisible
		steam.createLobby(lobby_type, max_members)
	else:
		# オフラインモック
		current_lobby_id = 12345678
		is_host = true
		lobby_created.emit(1, current_lobby_id)


## ロビー一覧の取得リクエスト
func request_lobby_list() -> void:
	if is_steam_available:
		var steam = Engine.get_singleton("Steam")
		steam.addRequestLobbyListDistanceFilter(3) # 3 = Worldwide
		steam.addRequestLobbyListStringFilter("game", "Tag_Game", 0) # 0 = Equal
		steam.requestLobbyList()
	else:
		# モックのロビーリスト（Steam無し環境でも②のティア表示/フィルタUIを確認できるよう
		# レート帯をばらけさせてある）
		var mock_lobbies = [
			{"id": 1001, "name": "初心者歓迎！タグゲーム", "members": 2, "max_members": 6,
				"host_rating": 1250, "tier": "silver", "tier_lock": false},
			{"id": 1002, "name": "ガチ勢レート戦部屋", "members": 4, "max_members": 8,
				"host_rating": 1950, "tier": "diamond", "tier_lock": true},
			{"id": 1003, "name": "まったり部屋", "members": 1, "max_members": 8,
				"host_rating": 1500, "tier": "gold", "tier_lock": false},
		]
		lobby_match_list.emit(mock_lobbies)


## ロビー参加
func join_lobby(lobby_id: int) -> void:
	if is_steam_available:
		var steam = Engine.get_singleton("Steam")
		steam.joinLobby(lobby_id)
	else:
		current_lobby_id = lobby_id
		is_host = false
		lobby_joined.emit(lobby_id, 0, false, 1)


## ロビー退出
func leave_lobby() -> void:
	if is_steam_available and current_lobby_id != 0:
		var steam = Engine.get_singleton("Steam")
		steam.leaveLobby(current_lobby_id)
	current_lobby_id = 0
	is_host = false


## Steam Leaderboard: ランキング取得
func request_leaderboard(start_rank: int = 1, end_rank: int = 20) -> void:
	if is_steam_available:
		var steam = Engine.get_singleton("Steam")
		steam.findLeaderboard(LEADERBOARD_NAME)
	else:
		# モックランキング
		var mock_entries = [
			{"rank": 1, "name": "SpeedMaster", "score": 2150},
			{"rank": 2, "name": "Ninja_Shadow", "score": 1980},
			{"rank": 3, "name": "TagKing", "score": 1840},
			{"rank": 4, "name": ProfileManager.player_name, "score": ProfileManager.rating},
			{"rank": 5, "name": "ChillRunner", "score": 1420},
		]
		leaderboard_loaded.emit(mock_entries)


## Steam Leaderboard: スコア/レートの送信
func upload_rating(new_rating: int) -> void:
	if is_steam_available:
		var steam = Engine.get_singleton("Steam")
		# 1 = KeepBest, 2 = ForceUpdate (レートは上下するためForceUpdate)
		steam.uploadLeaderboardScore(new_rating, true)
	else:
		leaderboard_score_uploaded.emit(true, new_rating)


# --- ⑥Steamworks Cloud (Remote Storage) ---

const CLOUD_PROFILE_FILENAME := "profile.json"


## プロフィールJSONをSteam Cloudへ書き込む。Steam無効時は何もせず false を返す
func cloud_save_profile(json_text: String) -> bool:
	if not is_steam_available:
		return false
	var steam = Engine.get_singleton("Steam")
	return steam.fileWrite(CLOUD_PROFILE_FILENAME, json_text.to_utf8_buffer())


## Steam Cloud上のプロフィールJSONを読む。存在しない/Steam無効時は空文字を返す
func cloud_load_profile() -> String:
	if not is_steam_available:
		return ""
	var steam = Engine.get_singleton("Steam")
	if not steam.fileExists(CLOUD_PROFILE_FILENAME):
		return ""
	var size: int = steam.getFileSize(CLOUD_PROFILE_FILENAME)
	if size <= 0:
		return ""
	var result = steam.fileRead(CLOUD_PROFILE_FILENAME, size)
	# GodotSteamはバイナリ同梱のGDExtensionでソースを直接確認できず、fileRead()の
	# 戻り値がPackedByteArrayそのものか{ret, buf}形式のDictionaryかはバージョン依存。
	# 実機導入時にGodotエディタの「ヘルプ検索」で確定させるまでは両方を許容する
	var buffer: PackedByteArray
	if result is Dictionary:
		buffer = result.get("buf", result.get("buffer", PackedByteArray()))
	else:
		buffer = result
	return buffer.get_string_from_utf8()


## Steam Cloud上のプロフィールJSONの最終更新時刻(UNIX秒)。未保存/Steam無効時は0
func cloud_file_timestamp() -> int:
	if not is_steam_available:
		return 0
	var steam = Engine.get_singleton("Steam")
	if not steam.fileExists(CLOUD_PROFILE_FILENAME):
		return 0
	return int(steam.getFileTimestamp(CLOUD_PROFILE_FILENAME))


## ProfileManagerのローカル状態とSteam Cloudを同期する。
## - クラウドに未保存(初回): データ消失を防ぐため、ローカルの現在値を無条件アップロードする
## - クラウドに既存: ダウンロード→ProfileManager.merge_server_inventory()でマージ
##   →マージ後の状態を再アップロードして両端末を収束させる(merge-then-republish)
func sync_profile_with_cloud() -> void:
	if not is_steam_available:
		return
	if cloud_file_timestamp() == 0:
		cloud_save_profile(JSON.stringify(ProfileManager.to_save_dict()))
		return
	var remote_text := cloud_load_profile()
	if remote_text.is_empty():
		return
	var json := JSON.new()
	if json.parse(remote_text) != OK or typeof(json.data) != TYPE_DICTIONARY:
		# 破損データはマージをスキップし、ローカルを保護する(絶対にクラッシュ・削除しない)
		return
	ProfileManager.merge_server_inventory(json.data)
	cloud_save_profile(JSON.stringify(ProfileManager.to_save_dict()))


# --- コールバック群 ---

func _on_lobby_created(connect_status: int, lobby_id: int) -> void:
	if connect_status == 1:
		current_lobby_id = lobby_id
		is_host = true
		var steam = Engine.get_singleton("Steam")
		var room_name = "%s's Room" % ProfileManager.player_name
		steam.setLobbyData(lobby_id, "game", "Tag_Game")
		steam.setLobbyData(lobby_id, "name", room_name)
		steam.setLobbyData(lobby_id, "version", str(GameManager.PROTOCOL_VERSION))
		steam.setLobbyData(lobby_id, "host_rating", str(ProfileManager.rating))
		steam.setLobbyData(lobby_id, "tier", String(RankingManager.tier_id(ProfileManager.rating)))
		steam.setLobbyData(lobby_id, "tier_lock", "1" if GameManager.tier_lock_enabled else "0")
		# ②参加者が実際に繋げるアドレス。LAN IP は既に解決済みのことが多いので即座に、
		# トンネル（インターネット越し）が後から確立したら upgrade する
		steam.setLobbyData(lobby_id, "host_addr", NetworkManager.public_address)
		if not NetworkManager.public_address_ready.is_connected(_on_public_address_ready):
			NetworkManager.public_address_ready.connect(_on_public_address_ready)
	lobby_created.emit(connect_status, lobby_id)


## ②トンネルのホスト名が後から確立した場合、ロビーの host_addr を更新する
func _on_public_address_ready(addr: String) -> void:
	if is_steam_available and is_host and current_lobby_id != 0:
		var steam = Engine.get_singleton("Steam")
		steam.setLobbyData(current_lobby_id, "host_addr", addr)


## ロビーのカスタムデータを読む（Steam無効時は常に空文字）
func get_lobby_data(lobby_id: int, key: String) -> String:
	if is_steam_available:
		var steam = Engine.get_singleton("Steam")
		return steam.getLobbyData(lobby_id, key)
	return ""


## ③参加直後は、ロビー作成者がまだ host_addr を書き込めていない
## （LAN IP解決はほぼ即時だが、トンネル確立前に参加された場合など）ことがあるため、
## Steam有効時のみ短時間だけリトライしてから諦める。呼び出し側はこの結果が空文字なら
## 「まだ準備できていない」として扱い、127.0.0.1 へフォールバックしないこと
## （それはSteam無効時の同一マシン向けモック経路専用）
func await_host_addr(lobby_id: int, retries: int = 5, interval: float = 0.4) -> String:
	if not is_steam_available:
		return ""
	var steam = Engine.get_singleton("Steam")
	for i in range(retries):
		var addr: String = steam.getLobbyData(lobby_id, "host_addr")
		if not addr.is_empty():
			return addr
		await get_tree().create_timer(interval).timeout
	return ""


func _on_lobby_match_list(lobbies: Array) -> void:
	var lobby_data_list := []
	if is_steam_available:
		var steam = Engine.get_singleton("Steam")
		for l_id in lobbies:
			# Spacewar(AppID 480)の他ゲームのロビーを除外するため、ゲーム識別子とバージョンを照合
			var game_id = steam.getLobbyData(l_id, "game")
			var ver_str = steam.getLobbyData(l_id, "version")
			if game_id != "Tag_Game" or ver_str != str(GameManager.PROTOCOL_VERSION):
				continue
			var l_name = steam.getLobbyData(l_id, "name")
			var members = steam.getNumLobbyMembers(l_id)
			var max_m = steam.getLobbyMemberLimit(l_id)
			# ②レート帯マッチング用。host_rating/tier が無い旧ビルドのロビーは
			# 1500/ゴールド扱いにフォールバックする
			var rating_str: String = steam.getLobbyData(l_id, "host_rating")
			var host_rating := int(rating_str) if not rating_str.is_empty() else 1500
			var tier_str: String = steam.getLobbyData(l_id, "tier")
			var tier := tier_str if not tier_str.is_empty() else String(RankingManager.tier_id(host_rating))
			lobby_data_list.append({
				"id": l_id,
				"name": l_name if not l_name.is_empty() else "Room #%d" % l_id,
				"members": members,
				"max_members": max_m,
				"host_rating": host_rating,
				"tier": tier,
				"tier_lock": steam.getLobbyData(l_id, "tier_lock") == "1",
			})
	lobby_match_list.emit(lobby_data_list)


func _on_lobby_joined(lobby_id: int, permissions: int, locked: bool, response: int) -> void:
	if response == 1:
		current_lobby_id = lobby_id
	lobby_joined.emit(lobby_id, permissions, locked, response)


func _on_lobby_chat_update(lobby_id: int, change_id: int, making_change_id: int, chat_state: int) -> void:
	lobby_chat_update.emit(lobby_id, change_id, making_change_id, chat_state)


func _on_leaderboard_scores_downloaded(message: String, result: Array) -> void:
	var entries := []
	for item in result:
		entries.append({
			"rank": item.get("global_rank", 0),
			"name": _persona_name_for(int(item.get("steam_id", 0))),
			"score": item.get("score", 0)
		})
	leaderboard_loaded.emit(entries)


## Steam Leaderboard のエントリはプレイヤー名を含まず SteamID64 のみを返すため、
## ここで表示名に変換する。自分自身は既に取得済みの steam_username を使い、
## それ以外はフレンドの名前キャッシュ（getFriendPersonaName）を試す。
## フレンドでない相手はキャッシュが無く空文字になることがあるため、その場合は
## ID を添えて表示する（SteamID64を生のまま name として使わない）
func _persona_name_for(entry_steam_id: int) -> String:
	if entry_steam_id == steam_id:
		return steam_username
	if Engine.has_singleton("Steam"):
		var steam = Engine.get_singleton("Steam")
		var persona: String = steam.getFriendPersonaName(entry_steam_id)
		if not persona.is_empty():
			return persona
	return "Player %d" % entry_steam_id


func _on_leaderboard_score_uploaded(success: bool, _handle: int, score: int) -> void:
	leaderboard_score_uploaded.emit(success, score)
