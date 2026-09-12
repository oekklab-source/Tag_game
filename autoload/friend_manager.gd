extends Node

## ⑤フレンド機能 Autoload。EOS Product User ID(PUID)をキーにした自前の
## フレンドリストシステム(service/friend-api/、Cloudflare Workers)を使う。
##
## EOS純正のFriends APIは使わない: Epic Account Services(EAS)ログインが必須で、
## Steam/itch.io経由でプレイする大多数のプレイヤーはEpicアカウントを持っていない
## ため。代わりにサーバー側生成の不透明なフレンドコードで1:1追加する方式にし、
## PUID自体は一覧・列挙できないようにしてある。表示名の完全一致検索(search_user)は
## 追加したが、前方一致・部分一致・一覧列挙は構造的に不可能なまま(詳細はfriend-api/README.md)。
##
## EosManagerと同じ方針(バックエンド無効時はモックデータで
## フォールバックし、クラッシュを防ぐ)に倣う。USE_LIVE_FRIEND_BACKENDは
## PurchaseManager.USE_LIVE_PURCHASESと同じ「デプロイ・動作確認が済むまでfalse」
## のロールアウト規約。

## 値の実体は autoload/backend_config.gd に集約してある。ここに残すのは
## 既存の参照箇所(このファイル内、tests/test_friend_backend_mock.gd)を
## 書き換えないための転送のみ
const USE_LIVE_FRIEND_BACKEND := BackendConfig.USE_LIVE_FRIEND_BACKEND

## クライアントからのオンライン生存通知の間隔。friend-api側のONLINE_THRESHOLD_MS(5分)は
## この2.5倍に取ってあるので、1〜2回の欠落は許容される
const HEARTBEAT_INTERVAL_SEC := 120.0
## 着せ替え画面の保存操作は name/costume/hat の最大3回 profile_updated を発火させるため、
## 1回の保存につきアップロードを1回にまとめる待ち時間
const STATS_UPLOAD_DEBOUNCE_SEC := 2.0

var _heartbeat_timer: Timer
var _stats_debounce_timer: Timer


func _ready() -> void:
	EosManager.eos_initialized.connect(_on_eos_initialized)
	ProfileManager.profile_updated.connect(_on_profile_updated_for_stats)


## 8箇所で繰り返される「実バックエンドを使ってよいか」の判定を1つに畳む
func _live() -> bool:
	return USE_LIVE_FRIEND_BACKEND and EosManager.is_eos_available


## EOS初期化(成功時のみ)を機にハートビートの開始判定を行う。失敗時(オフライン)は
## _live()がfalseのままなので、以降のheartbeat呼び出しは全て無音で無視される。
## ヘッドレス実行(tests/*.tscn)はEOS credentials設定済みの開発機だと毎回ここまで
## 到達してしまい、テスト実行のたびに本番friend-apiへハートビート/戦績アップロードの
## 実HTTPが飛んでKV書き込み予算(無料枠1日1,000件)を消費する。
## network_manager.gd._launch_tunnel()・profile_manager.gd._acquire_instance_lock()と
## 同じ理由・同じガードで、ヘッドレスでは開始しない
func _on_eos_initialized(success: bool) -> void:
	if DisplayServer.get_name() == "headless":
		return
	if not success or not USE_LIVE_FRIEND_BACKEND:
		return
	# EOS初期化前に発火したprofile_updated分の戦績も、ここで一度アップロードしておく
	_upload_my_stats_now()
	# フレンドが1人もいない間は誰も自分のオンライン状態を見ないため、ハートビートは
	# get_friends()の結果(_update_heartbeat_state経由)で必要な時だけ開始する
	get_friends()


func _send_heartbeat() -> void:
	if _live():
		await FriendBackendClient.heartbeat(self)


## ⑤フレンドが1人もいない間はオンライン状態を見る相手がいないため、ハートビート
## (KV書き込み予算を消費)を送らない。get_friends()が呼ばれるたび(フレンド画面を開いた時・
## 更新ボタン・リクエスト応答後・削除後・ギフト送り先選択時)に再評価されるので、
## フレンドが増減すれば自動的に開始/停止が切り替わる
func _update_heartbeat_state(has_friends: bool) -> void:
	if has_friends:
		_start_heartbeat()
	else:
		_stop_heartbeat()


func _start_heartbeat() -> void:
	if _heartbeat_timer == null:
		_heartbeat_timer = Timer.new()
		_heartbeat_timer.wait_time = HEARTBEAT_INTERVAL_SEC
		_heartbeat_timer.timeout.connect(_send_heartbeat)
		add_child(_heartbeat_timer)
	if _heartbeat_timer.is_stopped():
		_heartbeat_timer.start()
		_send_heartbeat()


func _stop_heartbeat() -> void:
	if _heartbeat_timer != null and not _heartbeat_timer.is_stopped():
		_heartbeat_timer.stop()


## ⑤⑦名前変更だけでなく戦績・スキン変更でも発火するため、デバウンスして
## 1回の操作につきアップロードを1回にまとめる。_on_eos_initialized()と同じ理由で
## ヘッドレス実行では開始しない(tests/net_roles.gd等がProfileManager.profile_updated
## を直接emitするテストがあり、ガードが無いと本番へ実HTTPが飛ぶ)
func _on_profile_updated_for_stats() -> void:
	if DisplayServer.get_name() == "headless":
		return
	if not _live():
		return
	if _stats_debounce_timer == null:
		_stats_debounce_timer = Timer.new()
		_stats_debounce_timer.one_shot = true
		_stats_debounce_timer.timeout.connect(_upload_my_stats_now)
		add_child(_stats_debounce_timer)
	_stats_debounce_timer.start(STATS_UPLOAD_DEBOUNCE_SEC)


func _upload_my_stats_now() -> void:
	if not _live():
		return
	var stats := {
		"rating": ProfileManager.rating,
		"matches_played": ProfileManager.matches_played,
		"runner_wins": ProfileManager.runner_wins,
		"hunter_wins": ProfileManager.hunter_wins,
		"highest_rating": ProfileManager.highest_rating,
		"costume_id": String(ProfileManager.costume_id),
		"costume_colors": ProfileManager.colors_to_html(ProfileManager.costume_colors),
		"hat_id": String(ProfileManager.hat_id),
	}
	await FriendBackendClient.sync(self, ProfileManager.player_name, stats)


## ⑤自分のフレンドコードを取得/生成する。フレンド画面が開いた際に呼ぶ。
## 失敗時は空文字列を返す(クラッシュしない)
func sync_with_backend() -> String:
	if _live():
		var res := await FriendBackendClient.sync(self, ProfileManager.player_name)
		if not res.get("api_ok", false):
			return ""
		return String(res.get("friend_code", ""))
	return "DEV12345"


## ⑤フレンド一覧を返す。各要素: {id: String(PUID), name, online}
## online はサーバー側のハートビート(_send_heartbeat)による在席判定の実データ
func get_friends() -> Array[Dictionary]:
	if _live():
		var res := await FriendBackendClient.list_friends(self)
		if not res.get("api_ok", false):
			return []
		var out: Array[Dictionary] = []
		for f in res.get("friends", []):
			out.append({"id": String(f.get("puid", "")), "name": String(f.get("name", "Friend")),
				"online": bool(f.get("online", false))})
		_update_heartbeat_state(not out.is_empty())
		return out
	return _mock_friends()


## ⑤コード完全一致 or 表示名完全一致でユーザーを検索する(mode: "code" | "name")。
## 戻り値: {found: bool, matches: [{code, name}], reason}(PUIDは含まない。追加はコードで行う)。
## reasonは失敗時のみ("rate_limited"等)、UIが特別な文言を出したければ使える
func search_user(query: String, mode: String) -> Dictionary:
	if query.is_empty():
		return {"found": false, "matches": [], "reason": "invalid_request"}
	if _live():
		var res := await FriendBackendClient.search_user(self, query, mode)
		if not res.get("api_ok", false):
			return {"found": false, "matches": [], "reason": "network_error"}
		if not res.get("ok", true):
			return {"found": false, "matches": [], "reason": String(res.get("reason", ""))}
		return {"found": res.get("found", false), "matches": res.get("matches", []), "reason": ""}
	return {"found": true, "matches": [{"code": "DEV12345", "name": query}], "reason": ""}


## ⑤フレンド1人の詳細(オンライン状態・戦績・レート・最終ログイン・スキン)。
## 戻り値: {ok: bool, reason(失敗時), name, online, last_seen, stats_available,
## [rating, matches_played, runner_wins, hunter_wins, highest_rating, costume_id,
## costume_colors, hat_id]}
func get_friend_profile(friend_puid: String) -> Dictionary:
	if _live():
		var res := await FriendBackendClient.friend_profile(self, friend_puid)
		if not res.get("api_ok", false):
			return {"ok": false, "reason": "network_error"}
		if not res.get("ok", false):
			return {"ok": false, "reason": String(res.get("reason", ""))}
		return res
	return {
		"ok": true, "name": "MockFriend", "online": true,
		"last_seen": int(Time.get_unix_time_from_system() * 1000),
		"stats_available": true, "rating": 1550, "matches_played": 12,
		"runner_wins": 5, "hunter_wins": 4, "highest_rating": 1600,
		"costume_id": "default", "costume_colors": [], "hat_id": "none",
	}


## ⑤自分に届いている保留中のフレンドリクエスト一覧
func get_pending_requests() -> Array[Dictionary]:
	if _live():
		var res := await FriendBackendClient.list_requests(self)
		if not res.get("api_ok", false):
			return []
		var out: Array[Dictionary] = []
		for r in res.get("requests", []):
			out.append({
				"request_id": String(r.get("request_id", "")),
				"from_puid": String(r.get("from_puid", "")),
				"from_name": String(r.get("from_name", "Friend")),
			})
		return out
	return [{"request_id": "mock-request-1", "from_puid": "mock-puid-9", "from_name": "MockRequester"}]


## ⑤フレンドコードを使ってリクエストを送る。戻り値: {ok, target_name, reason}
func send_friend_request(code: String) -> Dictionary:
	if code.is_empty():
		return {"ok": false, "target_name": "", "reason": "invalid_code"}
	if _live():
		var res := await FriendBackendClient.send_request(self, code)
		if not res.get("api_ok", false):
			return {"ok": false, "target_name": "", "reason": String(res.get("reason", "network_error"))}
		return {"ok": true, "target_name": String(res.get("target_name", "")), "reason": ""}
	return {"ok": true, "target_name": "MockFriend", "reason": ""}


## ⑤フレンドリクエストに応答する(承諾/拒否)
func respond_to_request(request_id: String, accept: bool) -> bool:
	if _live():
		var res := await FriendBackendClient.respond_request(self, request_id, accept)
		return res.get("api_ok", false) and res.get("ok", false)
	return true


## ⑤フレンドを解除する(双方向)
func remove_friend(friend_puid: String) -> bool:
	if _live():
		var res := await FriendBackendClient.remove_friend(self, friend_puid)
		return res.get("api_ok", false) and res.get("ok", false)
	return true


## ⑤自分がロビー中の場合のみ、接続先アドレスをクリップボードにコピーする。
## EOS Lobbiesにはpushでの招待APIが無いため、既存のDirectConnect導線に
## 相手が貼り付けられるようにする代替手段(配信確認はできない)
func invite_to_lobby() -> bool:
	if EosManager.current_lobby_id.is_empty():
		return false
	if EosManager.is_eos_available:
		var addr := await EosManager.await_host_addr(EosManager.current_lobby_id)
		if addr.is_empty():
			return false
		DisplayServer.clipboard_set(addr)
		return true
	DisplayServer.clipboard_set("127.0.0.1")
	return true


## ⑦レーティング戦で逃げる役が切断した際、ホストが代わりに敗北分のレート変動を
## 報告する(暫定実装)。本人はオフラインのため次回ログイン時にconsume_pending_penalty()
## で本人自身が適用する。失敗しても対戦継続には影響しないためfire-and-forgetでよい
func report_disconnect_penalty(puid: String, rating_delta: int) -> void:
	if _live():
		await FriendBackendClient.report_penalty(self, puid, rating_delta)


## ⑦自分宛ての保留中ペナルティがあれば取得し、同時にサーバー側から削除する。
## 戻り値: {"pending": bool, "rating_delta": int}
func consume_pending_penalty() -> Dictionary:
	if _live():
		var res := await FriendBackendClient.consume_penalty(self)
		if not res.get("api_ok", false) or not res.get("pending", false):
			return {"pending": false}
		return {"pending": true, "rating_delta": int(res.get("rating_delta", 0))}
	return {"pending": false}


## バックエンド無効時、⑤のUIをオフラインでも確認できるようにするモックフレンド一覧
func _mock_friends() -> Array[Dictionary]:
	return [
		{"id": "mock-puid-1", "name": "SpeedMaster", "online": true},
		{"id": "mock-puid-2", "name": "Ninja_Shadow", "online": false},
		{"id": "mock-puid-3", "name": "ChillRunner", "online": true},
	]
