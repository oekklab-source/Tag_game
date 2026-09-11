extends Node

## EOS (Epic Online Services) のラッパー Autoload。
## EOSG(epic-online-services-godot)アドオンが利用可能、かつ eos_credentials.cfg が
## 設定済みの場合に EOS Platform を初期化し、EOS Connect（匿名 Device ID 認証）を行う。
## それ以外(アドオン未導入 / クレデンシャル未設定)ではモック動作してクラッシュを防ぐ
## ——旧Steam実装(steam_manager.gd、Phase 7で削除済み)と同じ設計思想。
##
## ロビー/リーダーボード/クラウドセーブ等の各メソッドは、旧Steam実装からの移行時に
## 機械的に切り替えられるよう、シグナル形状を旧実装に揃えて作られている。
## ロビー/マッチメイキング(Phase 2)は EOS Lobbies Interface(HLobbies/HLobby)で実装済み。
## リーダーボード(Phase 3)・クラウドセーブ(Phase 4)も実装済み。
##
## project.godot の [autoload] に登録済み(scenes/room_match_dialog.gd から利用)。

signal eos_initialized(success: bool)
signal lobby_created(connect_status: int, lobby_id: String)
signal lobby_match_list(lobbies: Array)
signal lobby_joined(lobby_id: String, permissions: int, locked: bool, response: int)
signal lobby_chat_update(lobby_id: int, change_id: int, making_change_id: int, chat_state: int)
## ⑨EOSロビーのオーナーが(元オーナーの消失により)別メンバーへ自動的に昇格した際に発火。
## new_owner_puidは新オーナーのproduct_user_id、i_am_new_hostは自分がそれかどうか
signal host_migrated(new_owner_puid: String, i_am_new_host: bool)
signal leaderboard_loaded(entries: Array)
signal leaderboard_score_uploaded(success: bool, score: int)

const CREDENTIALS_PATH := "res://eos_credentials.cfg"
const SYNC_PROFILE_TIMEOUT_SEC := 8.0
const LOBBY_SEARCH_TIMEOUT_SEC := 10.0

var is_eos_available: bool = false
var product_user_id: String = ""
var current_lobby_id: String = ""
var is_host: bool = false

## EOS Connectへ最後に送った表示名。_on_profile_updated_for_display_name() が
## 変化の有無を判定するのに使う(profile_updated は名前以外の変更でも発火するため、
## 変化が無いのに毎回再ログインを試みるのを防ぐ)
var _last_synced_display_name: String = ""

var _current_lobby: HLobby = null
var _search_results: Dictionary = {}  # String lobby_id -> HLobby
var _is_searching_lobbies: bool = false

# --- ネイティブ呼び出しハングに対する最終防波堤(watchdog) ---
# 下の各所にあるcreate_timer()ベースのタイムアウトは「メインループが回り続けている」ことが
# 前提の協調的なものであり、Phase3実機検証で確認した「プロセス全体が完全停止する」真の
# フリーズ(CPU使用率ほぼ0%、physics_frame停止)には無力(タイマー自体が発火しない)。
#
# 【設計変更履歴】最初は同一プロセス内のGodot Threadで壁時計を監視する案を実装したが、
# 実機再現検証で21分間(CPU時間はわずか6.5秒)無応答のまま生き続け、Thread側のwatchdogは
# 一度も発火しないことを確認した。フリーズはプロセス全体(独立Threadも含め)を巻き込む
# 真のブロックであり、同一プロセス内のThreadでは原理的に保護できないと判断し、
# プロセス外部の独立したOSプロセス(PowerShell)による監視に変更した。別プロセスなので
# Godot/EOSSDK側のロック・スレッド状態に一切依存せず、OSレベルでの強制終了を保証できる
# (Windowsのタスクマネージャ「タスクの終了」が常にフリーズしたアプリに効くのと同じ原理)。
#
## 指定秒後に自分自身(このGodotプロセス)を強制終了する監視用PowerShellプロセスを起動する
## (既存のソフトタイムアウトに上乗せするハードタイムアウト)。戻り値の監視プロセスPIDを
## 保持しておき、処理が(ハングせず)完了したら_disarm_watchdog()に渡して止めること。
func _arm_watchdog(label: String, timeout_sec: float) -> int:
	var cmd := "Start-Sleep -Seconds %d; Stop-Process -Id %d -Force -ErrorAction SilentlyContinue" \
			% [int(ceil(timeout_sec)), OS.get_process_id()]
	var watcher_pid := OS.create_process(
		"powershell.exe", ["-NoProfile", "-WindowStyle", "Hidden", "-Command", cmd], false)
	if watcher_pid <= 0:
		printerr("[EosManager][watchdog] '%s' 用の監視プロセス起動に失敗。このハードタイムアウトは無効です。" % label)
	return watcher_pid


## _arm_watchdog()が返した監視プロセスPIDを渡し、期限前に監視プロセスを止める(武装解除)。
func _disarm_watchdog(watcher_pid: int) -> void:
	if watcher_pid > 0:
		OS.kill(watcher_pid)


## 実機再現検証で判明: 個別のEOS呼び出し(PDS同期/ロビー検索/リーダーボード取得)が
## すべて成功していても、その後のエンジン終了処理(quit()呼び出し→ノードツリー解体→
## ネイティブGDExtension側の後始末)でプロセスが無期限に残留する場合がある
## (EOS未使用のオフライン実行では一度も再現せず、EOSのネイティブ層に何らかの
## ネットワーク活動があった場合にのみ発生することを実機で確認済み)。個別呼び出し単位の
## watchdogでは終了処理そのものに潜むこのハングを検出できないため、ノードツリー解体開始時点
## (_exit_tree())でも独立して武装する。正常終了する場合はプロセスが先に消えるため
## 監視プロセスのkillは的外れ(無害)になるだけで、明示的な解除は不要。
func _exit_tree() -> void:
	if Engine.has_singleton("IEOS"):
		_arm_watchdog("engine_shutdown", 8.0)


func _ready() -> void:
	_init_eos()
	ProfileManager.profile_updated.connect(_on_profile_updated_for_display_name)


## EOS Platform の初期化 + EOS Connect(匿名 Device ID 認証)
func _init_eos() -> void:
	# EOSGのネイティブGDExtensionシングルトンの存在確認。旧Steam実装の
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
	_last_synced_display_name = ProfileManager.player_name
	print("[EosManager] EOS initialized successfully. product_user_id=%s" % product_user_id)

	# EAS(Epic Account Services)へは一切ログインしない匿名Device ID認証のみの構成のため、
	# Presence機能(Friends/Overlayと連動)の前提条件(EASセッション)を満たせない。
	# 有効なままだとLobby作成/参加でEOS側から拒否される可能性があるため無効化しておく。
	HLobbies.presence_enabled = false

	# EOS Player Data Storageとのプロフィール同期。ProfileManagerは既にローカルの
	# load_profile()を終えているので(autoload順で先に_ready()が走る)、
	# ここではローカル読み込み後の状態を前提にクラウドとマージ/初回アップロードする
	await _sync_profile_with_cloud_bounded()

	eos_initialized.emit(true)


## 着せ替え画面での名前変更をEOS Connect側にも反映しようとするベストエフォート処理。
## login_anonymous_async()の再呼び出しがサーバー側のDisplayNameを実際に更新するかは
## addon側にも保証コメントが無く実機でしか確認できないため、これが効かなくても
## _request_leaderboard_worker()/ranking_dialog.gdのpuidベースの自分判定・表示名上書きで
## 「自分の行が見つからない」症状自体は別途解消している(そちらが本命)
func _on_profile_updated_for_display_name() -> void:
	if not is_eos_available:
		return
	if ProfileManager.player_name == _last_synced_display_name:
		return
	_last_synced_display_name = ProfileManager.player_name
	await HAuth.login_anonymous_async(ProfileManager.player_name)


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


## EOS Connectが発行したID Token(JWT)を取得する。サーバー(friend-api等)への
## リクエスト認証に使う。呼ぶたびにEOSから取り直す(同期呼び出しなのでコストは低く、
## 有効期限管理の複雑さを避けるためキャッシュしない)。EOS未初期化時は空文字を返す
func get_id_token() -> String:
	if not is_eos_available:
		return ""
	var result: Dictionary = EOS.Connect.ConnectInterface.copy_id_token(EOS.Connect.CopyIdTokenOptions.new())
	var id_token: Dictionary = result.get("id_token", {})
	return id_token.get("json_web_token", "")


# --- ロビー/マッチメイキング(Phase 2) ---
# EOS Lobbies Interface(HLobbies/HLobby、addons/epic-online-services-godot/heos/)で実装。
# 旧Steam実装と同じシグナル形状を維持しているが、ロビーIDはEOSではStringのため
# current_lobby_id/lobby_created/lobby_joinedの型はintからStringに変更済み。

func create_lobby(lobby_type: int = 0, max_members: int = 8, lobby_name: String = "") -> void:
	if lobby_name.is_empty():
		lobby_name = "%s's Room" % ProfileManager.player_name
	if is_eos_available:
		var opts := EOS.Lobby.CreateLobbyOptions.new()
		opts.local_user_id = HAuth.product_user_id
		opts.bucket_id = "Tag_Game"  # 必須項目(未設定=空文字だとEOS_InvalidParametersになる。実機検証で確認済み)
		opts.max_lobby_members = max_members
		opts.permission_level = EOS.Lobby.LobbyPermissionLevel.PublicAdvertised
		opts.presence_enabled = HLobbies.presence_enabled
		# ⑨明示的にfalse(=マイグレーション許可)を設定する。既定値も既にfalseだが、
		# ホストマイグレーション機能が本作の前提になったことを意図として明文化しておく
		opts.disable_host_migration = false
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
		# ここでNetworkManager.public_addressをそのまま書かない。start_host()はこの
		# 関数の呼び出し元(lobby_created経由)より後に走るため、まだ前回ホストした時の
		# 値(古いトンネルのホスト名やLAN IP)が残っている可能性があり、それを新しい
		# ロビーの最終値として誤って公開してしまう。空にしておき、この直後に繋ぐ
		# public_address_ready経由で今回のセッションの値に更新させる
		lobby.add_attribute("host_addr", "")
		if not await lobby.update_async():
			print("[EosManager] Failed to write initial lobby attributes.")
		if not NetworkManager.public_address_ready.is_connected(_on_public_address_ready):
			NetworkManager.public_address_ready.connect(_on_public_address_ready)
		_watch_lobby(lobby)
		await _publish_can_host()
		lobby_created.emit(1, current_lobby_id)
	else:
		current_lobby_id = "mock-12345678"
		is_host = true
		lobby_created.emit(1, current_lobby_id)


## 実機検証で判明した既知の問題(request_leaderboard()と同種): HLobbies.search_by_attribute_async()の
## ネイティブコールバック(IEOS.lobby_search_find_callback)が無応答のままハングする場合がある。
## さらにこのシグナルはHLobbies内部でグローバル共有(呼び出しごとの相関IDが無い)ため、
## 検索が多重に同時実行されると片方のコールバックがもう片方の待機を巻き込んで消費してしまい、
## 残された側が永久に完了しなくなる問題も確認済み。そのため
## (1)_is_searching_lobbiesで多重実行そのものを禁止し、(2)念のためタイムアウトも設ける
## 二重の防御にする(PDS/Leaderboardsと同じ方針)。
func request_lobby_list() -> void:
	if is_eos_available:
		if _is_searching_lobbies:
			print("[EosManager] request_lobby_list() は既に検索中のため無視しました(多重実行防止)。")
			return
		_is_searching_lobbies = true
		var state := {"done": false}
		var watchdog_pid := _arm_watchdog("request_lobby_list", LOBBY_SEARCH_TIMEOUT_SEC + 5.0)
		_request_lobby_list_worker(state, watchdog_pid)
		var elapsed := 0.0
		while not state["done"] and elapsed < LOBBY_SEARCH_TIMEOUT_SEC:
			await get_tree().create_timer(0.5).timeout
			elapsed += 0.5
		if not state["done"]:
			print("[EosManager] request_lobby_list() timed out after %.1fs (Lobby検索が無応答の可能性あり)。" % LOBBY_SEARCH_TIMEOUT_SEC)
			lobby_match_list.emit([])
			# ワーカーはバックグラウンドで動き続ける可能性がある(state["done"]がその後trueになっても
			# ここでは待たない)。_is_searching_lobbiesはワーカー側が責任を持って解除する
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


## 実機検証で判明した既知の問題: HLobby.get_attribute()はキーの完全一致比較だが、
## EOS backendはロビー検索結果(copy_search_result_by_index経由)から返す属性キーを
## 大文字に正規化する(ホスト自身がcopy_lobby_details経由で読む場合は設定時の大文字小文字
## がそのまま保たれるため、この差異は検索結果を介した相手側でのみ顕在化する)。
## そのため検索結果由来のHLobbyから読む属性は、この大小文字非依存の照合を必ず使う。
func _get_lobby_attr_ci(lobby: HLobby, key: String) -> Dictionary:
	var key_lower := key.to_lower()
	for attr in lobby.attributes:
		if String(attr.key).to_lower() == key_lower:
			return attr
	return {}


func _request_lobby_list_worker(state: Dictionary, watchdog_pid: int) -> void:
	var results = await HLobbies.search_by_attribute_async([
		{"key": "game", "value": "Tag_Game", "comparison": EOS.ComparisonOp.Equal},
		{"key": "version", "value": str(GameManager.PROTOCOL_VERSION), "comparison": EOS.ComparisonOp.Equal},
	])
	state["done"] = true
	_disarm_watchdog(watchdog_pid)
	_is_searching_lobbies = false
	_search_results.clear()
	if results == null:
		lobby_match_list.emit([])
		return
	var lobbies: Array = []
	for lobby: HLobby in results:
		_search_results[lobby.lobby_id] = lobby
		var name_val: String = String(_get_lobby_attr_ci(lobby, "name").get("value", "Room #%s" % lobby.lobby_id))
		var host_rating: int = int(_get_lobby_attr_ci(lobby, "host_rating").get("value", 1500))
		var tier_val: String = String(_get_lobby_attr_ci(lobby, "tier").get("value", String(RankingManager.tier_id(host_rating))))
		var tier_lock_val: bool = String(_get_lobby_attr_ci(lobby, "tier_lock").get("value", "0")) == "1"
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
		_watch_lobby(lobby)
		await _publish_can_host()
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


## 今のロビーの公開定員(ホストのみ意味を持つ)。ロビー未所持時は室内UIの初期値と
## 揃えて8を返す
func get_current_lobby_max_members() -> int:
	if _current_lobby != null:
		return _current_lobby.max_members
	return 8


## ホストが待機中に公開ロビーの定員を変更する。add_attribute()と同じ
## 「値を書き換えてupdate_async()で反映」の2段階パターン(create_lobby()参照)
func update_max_members(new_max: int) -> bool:
	if not is_eos_available or _current_lobby == null or not is_host:
		return false
	_current_lobby.max_members = new_max
	if not await _current_lobby.update_async():
		print("[EosManager] Failed to update lobby max_members.")
		return false
	return true


## ロビーのカスタムデータを読む(EOS無効時は常に空文字)
func get_lobby_data(lobby_id: String, key: String) -> String:
	var lobby: HLobby = null
	if _current_lobby != null and _current_lobby.lobby_id == lobby_id:
		lobby = _current_lobby
	elif _search_results.has(lobby_id):
		lobby = _search_results[lobby_id]
	if lobby == null:
		return ""
	return String(_get_lobby_attr_ci(lobby, key).get("value", ""))


## 参加者が実際に繋げるアドレスを待つ(EOS無効時は常に空文字)。
##
## host_addr は最初LAN内IPで埋まり、Cloudflare Tunnelが確立し次第トンネルの
## ホスト名へ更新される(create_lobby()参照)。LAN内IPは「非公開・確立前の仮の値」
## である可能性があるため、非空というだけでは確定と見なさない。ホスト名（IPでない
## 文字列）が来るまで待ち、来なければ最後に見えていた値(LAN内IPでも)で妥協する。
## retries*interval はホスト側の待ち時間(NetworkManager.TUNNEL_POLL_TIMEOUT=30秒)と揃えてある
func await_host_addr(lobby_id: String, retries: int = 60, interval: float = 0.5) -> String:
	var last_addr := ""
	for i in retries:
		var addr := get_lobby_data(lobby_id, "host_addr")
		if not addr.is_empty():
			last_addr = addr
			if not addr.is_valid_ip_address():
				return addr  # ホスト名 = トンネル確立済みの最終値
		await get_tree().create_timer(interval).timeout
	return last_addr


## Cloudflare Tunnelのホスト名が解決した後、ロビーのhost_addr属性を更新する
func _on_public_address_ready(addr: String) -> void:
	if is_eos_available and is_host and _current_lobby != null:
		_current_lobby.add_attribute("host_addr", addr)
		if not await _current_lobby.update_async():
			print("[EosManager] Failed to update host_addr attribute.")


# --- ホストマイグレーション(Phase 8) ---
# EOS Lobbiesは既定でホストマイグレーション(オーナー消失時の自動オーナー昇格)が
# 有効になっている(create_lobby()のdisable_host_migration=false参照)。ここでは
# そのイベントを購読してゲーム側(NetworkManager)へ伝える薄い橋渡しだけを行う。

## Windows Desktop版のみ_launch_tunnel()(Cloudflare Tunnel)でインターネット越しの
## 到達性を確保できるため、ホストマイグレーションの昇格先になれるのもこの条件を
## 満たす端末だけ(Web版はtitle.gdでそもそもホストボタン自体が非表示)
func _compute_can_host() -> bool:
	return not OS.has_feature("web") and OS.get_name() == "Windows"


## 自分のcan_host(ホストになれるか)をロビーメンバー属性として公開する。
## create_lobby()/join_lobby()の両方から、ロビー参加が確定した直後に呼ぶ
func _publish_can_host() -> void:
	if not is_eos_available or _current_lobby == null:
		return
	_current_lobby.add_current_member_attribute("can_host", "1" if _compute_can_host() else "0")
	if not await _current_lobby.update_async():
		print("[EosManager] Failed to publish can_host attribute.")


func _watch_lobby(lobby: HLobby) -> void:
	if not lobby.lobby_owner_changed.is_connected(_on_lobby_owner_changed):
		lobby.lobby_owner_changed.connect(_on_lobby_owner_changed)


## EOSのオーナー自動昇格(旧オーナー消失検知)を受けての通知。
## _init_from_details()がowner_product_user_idを更新してからこのシグナルを
## 発火する(hlobby.gd参照)ため、ここでis_owner()を読めば新オーナーを正しく判定できる
func _on_lobby_owner_changed() -> void:
	if _current_lobby == null:
		return
	is_host = _current_lobby.is_owner()
	# ⑨join_lobby()経由(=元は参加者)でマイグレーション昇格した場合はcreate_lobby()を
	# 通らないため、ここで配線しないと新ホストのトンネル確立後もhost_addr属性が
	# 更新されず誰も再接続できなくなる(実機検証で確認した重大バグ)
	if is_host and not NetworkManager.public_address_ready.is_connected(_on_public_address_ready):
		NetworkManager.public_address_ready.connect(_on_public_address_ready)
	host_migrated.emit(_current_lobby.owner_product_user_id, is_host)


## 指定したメンバーがホストになれる(can_host=1を公開済み)かどうか
func can_host_of(product_user_id: String) -> bool:
	if _current_lobby == null:
		return false
	var member := _current_lobby.get_member_by_product_user_id(product_user_id)
	if member == null:
		return false
	return String(member.get_attribute("can_host").get("value", "0")) == "1"


## can_host=1の候補の中から決定的なルール(puidの辞書順)で1人選ぶ。
## EOS呼び出しを一切含まない純粋関数として切り出してあり、テストではこちらを直接検証する。
## 候補が見つからなければ空文字を返す
func _pick_handoff_target() -> String:
	if _current_lobby == null:
		return ""
	var candidates: Array[String] = []
	for member in _current_lobby.members:
		if member.product_user_id != product_user_id and can_host_of(member.product_user_id):
			candidates.append(member.product_user_id)
	if candidates.is_empty():
		return ""
	candidates.sort()
	return candidates[0]


## 自分が新オーナーに昇格したがホストになれない(can_host=0、Web版等)場合に呼ぶ。
## can_host=1の別メンバーへ委譲し、再度lobby_owner_changed(→host_migrated)を連鎖的に発火させる。
## 戻り値true=委譲を試みた(次のhost_migratedを待てばよい)、
## false=委譲先が見つからない/委譲失敗(呼び出し側でマイグレーション断念と判断する)
func handoff_if_incapable() -> bool:
	if _current_lobby == null or not is_host:
		return false
	var target_puid := _pick_handoff_target()
	if target_puid.is_empty():
		return false
	var target := _current_lobby.get_member_by_product_user_id(target_puid)
	return await target.promote_member_async()


# --- リーダーボード(Phase 3) ---
# EOS Stats & Leaderboards Interface(HStats/HLeaderboards)で実装。
# 表示名はEOS Connect匿名ログイン時(_init_eos内のlogin_anonymous_async)に渡した
# display_nameがバックエンド側に保持され、get_leaderboard_records_asyncの
# user_display_nameへそのまま反映される想定(旧Steam実装のような逆引きは不要)。
# ただしログイン後にプロフィール名を変更しても次回ログインまでは反映されない。

const LEADERBOARD_STAT_NAME := "PlayerRating"
const LEADERBOARD_QUERY_TIMEOUT_SEC := 10.0

var _leaderboard_id_cache: String = ""


## stat_nameからLeaderboard IDを動的に解決する(ポータルのIDをコードに転記しない方針)。
## 見つからない場合は空文字(Developer PortalでStat/Leaderboard定義が未作成、または取得失敗)
func _resolve_leaderboard_id() -> String:
	if not _leaderboard_id_cache.is_empty():
		return _leaderboard_id_cache
	var defs = await HLeaderboards.get_leaderboard_definitions_async()
	if defs == null:
		return ""
	for d in defs:
		if d.get("stat_name") == LEADERBOARD_STAT_NAME:
			_leaderboard_id_cache = d.get("leaderboard_id", "")
			break
	return _leaderboard_id_cache


## 実機検証で判明した既知の問題: query_leaderboard_definitions/query_leaderboard_ranksの
## ネイティブコールバックが(エラーすら出さず)無応答のままハングする場合がある。
## PDS書き込みハング対策(_sync_profile_with_cloud_bounded)と同じ方針で、
## タイムアウト時は空配列で先に画面を返す(ワーカーはバックグラウンドで動き続け、
## 遅れて本来のデータが届けばleaderboard_loadedが再度発火しUIも更新される)。
func request_leaderboard(_start_rank: int = 1, _end_rank: int = 20) -> void:
	if is_eos_available:
		var state := {"done": false}
		var watchdog_pid := _arm_watchdog("request_leaderboard", LEADERBOARD_QUERY_TIMEOUT_SEC + 5.0)
		_request_leaderboard_worker(state, watchdog_pid)
		var elapsed := 0.0
		while not state["done"] and elapsed < LEADERBOARD_QUERY_TIMEOUT_SEC:
			await get_tree().create_timer(0.5).timeout
			elapsed += 0.5
		if not state["done"]:
			print("[EosManager] request_leaderboard() timed out after %.1fs (Leaderboardsクエリが無応答の可能性あり)。" % LEADERBOARD_QUERY_TIMEOUT_SEC)
			leaderboard_loaded.emit([])
	else:
		var mock_entries = [
			{"rank": 1, "name": "SpeedMaster", "score": 2150},
			{"rank": 2, "name": "Ninja_Shadow", "score": 1980},
			{"rank": 3, "name": "TagKing", "score": 1840},
			# puidを付けない: is_eos_available==falseのオフラインモックでは
			# EosManager.product_user_idも空文字のままなので、ranking_dialog.gd側は
			# 名前一致にフォールバックして自分の行を見つける
			{"rank": 4, "name": ProfileManager.player_name, "score": ProfileManager.rating},
			{"rank": 5, "name": "ChillRunner", "score": 1420},
		]
		leaderboard_loaded.emit(mock_entries)


func _request_leaderboard_worker(state: Dictionary, watchdog_pid: int) -> void:
	var leaderboard_id := await _resolve_leaderboard_id()
	if leaderboard_id.is_empty():
		print("[EosManager] Leaderboard定義が見つかりません(stat_name=%s)。Developer Portal側の設定を確認してください。" % LEADERBOARD_STAT_NAME)
		state["done"] = true
		_disarm_watchdog(watchdog_pid)
		leaderboard_loaded.emit([])
		return
	var records = await HLeaderboards.get_leaderboard_records_async(leaderboard_id)
	state["done"] = true
	_disarm_watchdog(watchdog_pid)
	if records == null:
		leaderboard_loaded.emit([])
		return
	var entries: Array = []
	for r in records:
		var name_val: String = r.get("user_display_name", "")
		if name_val.is_empty():
			name_val = "Player"
		# puid(user_id)を含めておく。表示名はEOS Connectログイン時点の値で固まっており
		# 後からの名前変更を追わないため(_on_profile_updated_for_display_nameのコメント参照)、
		# ranking_dialog.gd はここのnameではなくpuidで自分の行を判定する
		entries.append({"rank": r.get("rank", 0), "name": name_val, "score": r.get("score", 0),
			"puid": r.get("user_id", "")})
	leaderboard_loaded.emit(entries)


func upload_rating(new_rating: int) -> void:
	if is_eos_available:
		var result = await HStats.ingest_stat_async(LEADERBOARD_STAT_NAME, new_rating)
		leaderboard_score_uploaded.emit(EOS.is_success(result), new_rating)
	else:
		leaderboard_score_uploaded.emit(true, new_rating)


# --- クラウドセーブ(Phase 4) ---
# EOS Player Data Storage Interface(HPlayerDataStorage、アドオン本体には未バンドルのため
# Phase 4で新規作成)で実装。merge-then-republishの方針は旧Steam実装の
# sync_profile_with_cloud()と同一(バックエンドが変わってもProfileManager側の契約は不変)。

const CLOUD_PROFILE_FILENAME := "profile.json"


## プロフィールJSONをEOS Player Data Storageへ書き込む(EOS無効時は何もせずfalseを返す)
func cloud_save_profile(json_text: String) -> bool:
	if not is_eos_available:
		return false
	return await HPlayerDataStorage.write_file_async(CLOUD_PROFILE_FILENAME, json_text.to_utf8_buffer())


## EOS Player Data Storage上のプロフィールJSONを読む(未保存/EOS無効時は空文字)
func cloud_load_profile() -> String:
	if not is_eos_available:
		return ""
	var buffer: PackedByteArray = await HPlayerDataStorage.read_file_async(CLOUD_PROFILE_FILENAME)
	return buffer.get_string_from_utf8()


## EOS Player Data Storage上のプロフィールJSONの最終更新時刻(UNIX秒)
func cloud_file_timestamp() -> int:
	if not is_eos_available:
		return 0
	return await HPlayerDataStorage.get_file_timestamp_async(CLOUD_PROFILE_FILENAME)


## sync_profile_with_cloud()をタイムアウト付きで実行する。
## 実機検証でPDS書き込み/読み込みが応答なくハングする既知の問題を確認済みのため
## (Client PolicyでPDS機能が未有効な場合など)、eos_initialized発火が
## 永久にブロックされないようにする。ハングした場合、同期処理はバックグラウンドで
## 動き続けるが(いつか完了すればProfileManager側に反映される)、
## 起動フローはそれを待たずに先へ進む。
func _sync_profile_with_cloud_bounded() -> void:
	var state := {"done": false}
	var watchdog_pid := _arm_watchdog("sync_profile_with_cloud", SYNC_PROFILE_TIMEOUT_SEC + 5.0)
	var run := func() -> void:
		await sync_profile_with_cloud()
		state["done"] = true
		_disarm_watchdog(watchdog_pid)
	run.call()
	var elapsed := 0.0
	while not state["done"] and elapsed < SYNC_PROFILE_TIMEOUT_SEC:
		await get_tree().create_timer(0.5).timeout
		elapsed += 0.5
	if not state["done"]:
		print("[EosManager] sync_profile_with_cloud() timed out after %.1fs (PDS may be unresponsive). Continuing without waiting." % SYNC_PROFILE_TIMEOUT_SEC)


## ProfileManagerのローカル状態とEOS Player Data Storageを同期する。
## - クラウドに未保存と確認できた場合(初回): データ消失リスクなく、ローカルの現在値を無条件アップロードする
## - クラウドに既存: ダウンロード→ProfileManager.merge_server_inventory()でマージ
##   →マージ後の状態を再アップロードして両端末を収束させる(merge-then-republish)
## - クラウド側の存在有無自体が確認できない場合(一時的な通信障害/PDS不調など):
##   「未保存」と誤認して上書きしてしまうデータ消失を避けるため、同期処理を中断する
func sync_profile_with_cloud() -> void:
	if not is_eos_available:
		return
	var status: HPlayerDataStorage.FileQueryStatus = \
		await HPlayerDataStorage.query_file_status_async(CLOUD_PROFILE_FILENAME)
	if status == HPlayerDataStorage.FileQueryStatus.ERROR:
		print("[EosManager] sync_profile_with_cloud(): failed to query cloud file status (transient?). Skipping sync to avoid overwriting cloud data.")
		return
	if status == HPlayerDataStorage.FileQueryStatus.NOT_FOUND:
		await cloud_save_profile(JSON.stringify(ProfileManager.to_save_dict()))
		return
	var remote_text := await cloud_load_profile()
	if remote_text.is_empty():
		return
	var json := JSON.new()
	if json.parse(remote_text) != OK or typeof(json.data) != TYPE_DICTIONARY:
		# 破損データはマージをスキップし、ローカルを保護する(絶対にクラッシュ・削除しない)
		return
	ProfileManager.merge_server_inventory(json.data)
	await cloud_save_profile(JSON.stringify(ProfileManager.to_save_dict()))
