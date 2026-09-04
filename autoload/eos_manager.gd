extends Node

## EOS (Epic Online Services) のラッパー Autoload。
## EOSG(epic-online-services-godot)アドオンが利用可能、かつ eos_credentials.cfg が
## 設定済みの場合に EOS Platform を初期化し、EOS Connect（匿名 Device ID 認証）を行う。
## それ以外(アドオン未導入 / クレデンシャル未設定)ではモック動作してクラッシュを防ぐ
## ——steam_manager.gd と同じ設計思想。
##
## ロビー/リーダーボード/クラウドセーブ等の各メソッドは、呼び出し元(steam_manager.gd利用箇所)を
## 機械的に切り替えられるよう、シグナル形状だけ steam_manager.gd に揃えてある。
## ロビー/マッチメイキング(Phase 2)は EOS Lobbies Interface(HLobbies/HLobby)で実装済み。
## リーダーボード(Phase 3)・クラウドセーブ(Phase 4)はまだ TODO のスタブ。
##
## project.godot の [autoload] に登録済み(scenes/room_match_dialog.gd から利用)。

signal eos_initialized(success: bool)
signal lobby_created(connect_status: int, lobby_id: String)
signal lobby_match_list(lobbies: Array)
signal lobby_joined(lobby_id: String, permissions: int, locked: bool, response: int)
signal lobby_chat_update(lobby_id: int, change_id: int, making_change_id: int, chat_state: int)
signal leaderboard_loaded(entries: Array)
signal leaderboard_score_uploaded(success: bool, score: int)

const CREDENTIALS_PATH := "res://eos_credentials.cfg"

var is_eos_available: bool = false
var product_user_id: String = ""
var current_lobby_id: String = ""
var is_host: bool = false

var _current_lobby: HLobby = null
var _search_results: Dictionary = {}  # String lobby_id -> HLobby


func _ready() -> void:
	_init_eos()


## EOS Platform の初期化 + EOS Connect(匿名 Device ID 認証)
func _init_eos() -> void:
	# EOSGのネイティブGDExtensionシングルトンの存在確認。steam_manager.gdの
	# Engine.has_singleton("Steam")と同じ検出パターン(DLL読み込み失敗時にクラッシュしない)。
	# 実クレデンシャルでの実機テストが行えるようになった際、この検出方法が実態と
	# 合っているか(Godotエディタの「ヘルプ検索」等で)再確認すること
	if not Engine.has_singleton("IEOS"):
		print("[EosManager] EOSG SDK not detected. Running in Offline / Fallback mode.")
		eos_initialized.emit(false)
		return

	var credentials := _load_credentials()
	if credentials == null:
		print("[EosManager] eos_credentials.cfg not configured yet. Running in Offline / Fallback mode.")
		eos_initialized.emit(false)
		return

	var setup_success: bool = await HPlatform.setup_eos_async(credentials)
	if not setup_success:
		print("[EosManager] Failed to setup EOS platform. Running in Offline / Fallback mode.")
		eos_initialized.emit(false)
		return

	var login_success: bool = await HAuth.login_anonymous_async(ProfileManager.player_name)
	if not login_success:
		print("[EosManager] EOS Connect anonymous login failed. Running in Offline / Fallback mode.")
		eos_initialized.emit(false)
		return

	is_eos_available = true
	product_user_id = HAuth.product_user_id
	print("[EosManager] EOS initialized successfully. product_user_id=%s" % product_user_id)
	eos_initialized.emit(true)


## eos_credentials.cfg を読み込み HCredentials を構築する。
## ファイルが存在しない、または必須項目が空の場合は null を返す(未設定扱い)
func _load_credentials() -> HCredentials:
	if not FileAccess.file_exists(CREDENTIALS_PATH):
		return null

	var cfg := ConfigFile.new()
	if cfg.load(CREDENTIALS_PATH) != OK:
		return null

	var product_id: String = cfg.get_value("eos", "product_id", "")
	var sandbox_id: String = cfg.get_value("eos", "sandbox_id", "")
	var deployment_id: String = cfg.get_value("eos", "deployment_id", "")
	var client_id: String = cfg.get_value("eos", "client_id", "")
	var client_secret: String = cfg.get_value("eos", "client_secret", "")
	if product_id.is_empty() or sandbox_id.is_empty() or deployment_id.is_empty() \
			or client_id.is_empty() or client_secret.is_empty():
		return null

	var credentials := HCredentials.new()
	credentials.product_name = cfg.get_value("eos", "product_name", "Tag_Game")
	credentials.product_version = cfg.get_value("eos", "product_version", "1.0")
	credentials.product_id = product_id
	credentials.sandbox_id = sandbox_id
	credentials.deployment_id = deployment_id
	credentials.client_id = client_id
	credentials.client_secret = client_secret
	credentials.encryption_key = cfg.get_value("eos", "encryption_key", "")
	return credentials


# --- ロビー/マッチメイキング(Phase 2) ---
# EOS Lobbies Interface(HLobbies/HLobby、addons/epic-online-services-godot/heos/)で実装。
# steam_manager.gdと同じシグナル形状を維持しているが、ロビーIDはEOSではStringのため
# current_lobby_id/lobby_created/lobby_joinedの型はintからStringに変更済み。

func create_lobby(lobby_type: int = 0, max_members: int = 8, lobby_name: String = "") -> void:
	if lobby_name.is_empty():
		lobby_name = "%s's Room" % ProfileManager.player_name
	if is_eos_available:
		var opts := EOS.Lobby.CreateLobbyOptions.new()
		opts.local_user_id = HAuth.product_user_id
		opts.max_lobby_members = max_members
		opts.permission_level = EOS.Lobby.LobbyPermissionLevel.PublicAdvertised
		opts.presence_enabled = HLobbies.presence_enabled
		var lobby: HLobby = await HLobbies.create_lobby_async(opts)
		if lobby == null:
			lobby_created.emit(0, "")
			return
		_current_lobby = lobby
		current_lobby_id = lobby.lobby_id
		is_host = true
		lobby.add_attribute("game", "Tag_Game")
		lobby.add_attribute("name", lobby_name)
		lobby.add_attribute("version", str(GameManager.PROTOCOL_VERSION))
		lobby.add_attribute("host_rating", str(ProfileManager.rating))
		lobby.add_attribute("tier", String(RankingManager.tier_id(ProfileManager.rating)))
		lobby.add_attribute("tier_lock", "1" if GameManager.tier_lock_enabled else "0")
		lobby.add_attribute("host_addr", NetworkManager.public_address)
		if not await lobby.update_async():
			print("[EosManager] Failed to write initial lobby attributes.")
		if not NetworkManager.public_address_ready.is_connected(_on_public_address_ready):
			NetworkManager.public_address_ready.connect(_on_public_address_ready)
		lobby_created.emit(1, current_lobby_id)
	else:
		current_lobby_id = "mock-12345678"
		is_host = true
		lobby_created.emit(1, current_lobby_id)


func request_lobby_list() -> void:
	if is_eos_available:
		var results = await HLobbies.search_by_attribute_async([
			{"key": "game", "value": "Tag_Game", "comparison": EOS.ComparisonOp.Equal},
			{"key": "version", "value": str(GameManager.PROTOCOL_VERSION), "comparison": EOS.ComparisonOp.Equal},
		])
		_search_results.clear()
		if results == null:
			lobby_match_list.emit([])
			return
		var lobbies: Array = []
		for lobby: HLobby in results:
			_search_results[lobby.lobby_id] = lobby
			var name_val: String = String(lobby.get_attribute("name").get("value", "Room #%s" % lobby.lobby_id))
			var host_rating: int = int(lobby.get_attribute("host_rating").get("value", 1500))
			var tier_val: String = String(lobby.get_attribute("tier").get("value", String(RankingManager.tier_id(host_rating))))
			var tier_lock_val: bool = String(lobby.get_attribute("tier_lock").get("value", "0")) == "1"
			lobbies.append({
				"id": lobby.lobby_id,
				"name": name_val,
				"members": lobby.members.size(),
				"max_members": lobby.max_members,
				"host_rating": host_rating,
				"tier": tier_val,
				"tier_lock": tier_lock_val,
			})
		lobby_match_list.emit(lobbies)
	else:
		var mock_lobbies = [
			{"id": "mock-1001", "name": "初心者歓迎！タグゲーム", "members": 2, "max_members": 6,
				"host_rating": 1250, "tier": "silver", "tier_lock": false},
			{"id": "mock-1002", "name": "ガチ勢レート戦部屋", "members": 4, "max_members": 8,
				"host_rating": 1950, "tier": "diamond", "tier_lock": true},
			{"id": "mock-1003", "name": "まったり部屋", "members": 1, "max_members": 8,
				"host_rating": 1500, "tier": "gold", "tier_lock": false},
		]
		lobby_match_list.emit(mock_lobbies)


func join_lobby(lobby_id: String) -> void:
	if is_eos_available:
		var lobby: HLobby
		if _search_results.has(lobby_id):
			lobby = await HLobbies.join_async(_search_results[lobby_id])
		else:
			lobby = await HLobbies.join_by_id_async(lobby_id)
		if lobby == null:
			lobby_joined.emit(lobby_id, 0, false, 0)
			return
		_current_lobby = lobby
		current_lobby_id = lobby.lobby_id
		is_host = false
		lobby_joined.emit(current_lobby_id, 0, false, 1)
	else:
		current_lobby_id = lobby_id
		is_host = false
		lobby_joined.emit(lobby_id, 0, false, 1)


func leave_lobby() -> void:
	if is_eos_available and _current_lobby != null:
		if not await _current_lobby.leave_async():
			print("[EosManager] Failed to leave lobby cleanly.")
	_current_lobby = null
	current_lobby_id = ""
	is_host = false


## ロビーのカスタムデータを読む(EOS無効時は常に空文字)
func get_lobby_data(lobby_id: String, key: String) -> String:
	var lobby: HLobby = null
	if _current_lobby != null and _current_lobby.lobby_id == lobby_id:
		lobby = _current_lobby
	elif _search_results.has(lobby_id):
		lobby = _search_results[lobby_id]
	if lobby == null:
		return ""
	return String(lobby.get_attribute(key).get("value", ""))


## 参加者が実際に繋げるアドレスを待つ(EOS無効時は常に空文字)
func await_host_addr(lobby_id: String, retries: int = 5, interval: float = 0.4) -> String:
	for i in retries:
		var addr := get_lobby_data(lobby_id, "host_addr")
		if not addr.is_empty():
			return addr
		await get_tree().create_timer(interval).timeout
	return ""


## Cloudflare Tunnelのホスト名が解決した後、ロビーのhost_addr属性を更新する
func _on_public_address_ready(addr: String) -> void:
	if is_eos_available and is_host and _current_lobby != null:
		_current_lobby.add_attribute("host_addr", addr)
		if not await _current_lobby.update_async():
			print("[EosManager] Failed to update host_addr attribute.")


# --- TODO(Phase 3): リーダーボード ---
# EOS Stats & Leaderboards Interface(HLeaderboards)で実装する。
# 表示名はスコア送信時に書き込む方式に変更する(匿名Connect認証では逆引き手段が無いため)。

func request_leaderboard(_start_rank: int = 1, _end_rank: int = 20) -> void:
	if is_eos_available:
		pass # TODO(Phase 3): HLeaderboards.get_leaderboard_records_async()でランキング取得
	else:
		var mock_entries = [
			{"rank": 1, "name": "SpeedMaster", "score": 2150},
			{"rank": 2, "name": "Ninja_Shadow", "score": 1980},
			{"rank": 3, "name": "TagKing", "score": 1840},
			{"rank": 4, "name": ProfileManager.player_name, "score": ProfileManager.rating},
			{"rank": 5, "name": "ChillRunner", "score": 1420},
		]
		leaderboard_loaded.emit(mock_entries)


func upload_rating(new_rating: int) -> void:
	if is_eos_available:
		pass # TODO(Phase 3): HStats/HLeaderboardsでスコア送信
	else:
		leaderboard_score_uploaded.emit(true, new_rating)


# --- TODO(Phase 4): クラウドセーブ ---
# EOS Player Data Storageで実装する。profile_manager.gdのmerge_server_inventory()は無変更で流用する。

## プロフィールJSONをEOS Player Data Storageへ書き込む(EOS無効時は何もせずfalseを返す)
func cloud_save_profile(_json_text: String) -> bool:
	# TODO(Phase 4): Player Data Storageへの書き込み
	return false


## EOS Player Data Storage上のプロフィールJSONを読む(未保存/EOS無効時は空文字)
func cloud_load_profile() -> String:
	# TODO(Phase 4): Player Data Storageからの読み込み
	return ""


## EOS Player Data Storage上のプロフィールJSONの最終更新時刻(UNIX秒)
func cloud_file_timestamp() -> int:
	# TODO(Phase 4): Player Data Storageのメタデータ取得
	return 0


## ProfileManagerのローカル状態とEOS Player Data Storageを同期する(steam_manager.gdのsync_profile_with_cloudと同じmerge-then-republish方針)
func sync_profile_with_cloud() -> void:
	# TODO(Phase 4): cloud_file_timestamp/cloud_load_profile/merge_server_inventory/cloud_save_profileを組み合わせて実装
	pass
