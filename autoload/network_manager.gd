extends Node

## WebSocket 接続の確立と切断処理を担当する Autoload。
## クライアントは world シーンを読み込んでから接続する
## （MultiplayerSpawner のスポーン通知を取りこぼさないため）。

enum Mode { NONE, HOST, CLIENT }
## ①VS CPU戦にレートを適用しないための区別。ラウンド開始時の判定自体は
## GameManager.round_is_ranked が humans>=2 で行うので、これは主に UI 表示
## （「ソロ練習」ボタンの文言等）や将来の用途のためのラベル
enum SessionKind { SOLO, ONLINE }

const PORT := 9999
const WORLD_SCENE := "res://scenes/world.tscn"
const MAIN_SCENE := "res://scenes/title.tscn"
const MIGRATION_OVERLAY_SCENE := "res://scenes/migration_overlay.tscn"
## ⑨EOSがオーナー消失を検知して新オーナーを確定させるまでの待ち時間。この間に
## host_migratedが来なければ諦める(EOSのハートビート検知は疎通確認ベースで
## Godot高レベルAPIのTCP切断即時検知より遅れうるため、余裕を持たせる)
const MIGRATION_OWNER_WAIT_SEC := 15.0
## ⑨新ホストがCloudflare Tunnelを再確立するまでの待ち時間。既存のTUNNEL_POLL_TIMEOUTと揃える
const MIGRATION_RECONNECT_WAIT_SEC := 30.0
## tools/serve.ps1 がトンネルのホスト名を書き出す先。ホストのゲームプロセスは
## create_process で撃ちっぱなしにした別プロセスの標準出力を直接は読めないため、
## ファイル経由でホスト名を受け渡す
const TUNNEL_HOST_FILE := "user://tunnel_host.txt"
const TUNNEL_POLL_INTERVAL := 1.0
const TUNNEL_POLL_TIMEOUT := 30.0

var mode := Mode.NONE
var session_kind := SessionKind.SOLO
var join_address := "127.0.0.1"
var last_error := ""
## ②EOSロビー参加者が実際に接続すべきアドレス（LAN IP、後にトンネルのホスト名で
## 上書きされることがある）。host_addr としてロビーデータに載せる
var public_address := ""
signal public_address_ready(addr: String)
## URL の ?s= による自動参加は1回だけ。接続失敗時は leave() が main.tscn へ戻すので、
## ガードが無いと同じアドレスへ無限に再接続しに行く
var auto_join_done := false
## ③このセッションがEOSロビー(ルームマッチ/クイックマッチ、見知らぬ相手との
## レーティング戦)経由か、DirectConnect(招待リンク/IP直結、フレンドのみの
## プライベート対戦)経由かを表す。room_match_dialog.gd が接続開始前に設定する。
## ホスト側のこの値がGameManager._start_round()のRPC引数として全ピアへ配られ、
## 鬼のランダム化・レーティング適用可否を決める(接続方法はピアごとに違いうるため、
## 各ピアが自分のこの値だけを見て判断すると食い違いうる。PROTOCOL_VERSION 4の説明参照)
var matched_via_eos_lobby := false
## tools/serve.ps1（トンネル）の PID。同一セッションで再ホストしても二重起動しないための記録
var _tunnel_pid := -1
var _tunnel_poll_timer: Timer = null
var _tunnel_poll_elapsed := 0.0

## ⑨EOSロビー経由の対戦中、ホストが落ちた際に生存者だけでゲームを続けるための状態機械。
## 対象はEOSロビー経由のみ(DirectConnectはロビーを持たないため対象外、matched_via_eos_lobby参照)
signal migration_status_changed(text: String)
var is_migrating := false
## GameManager.snapshot_for_host_disconnect_penalty()の戻り値を、新ホストが
## 確定するまで一時保持しておく置き場(空辞書なら報告対象なし)
var _pending_host_penalty := {}
## SceneTreeTimerのtimeoutを後から無効化する手段がないため、世代カウンタで
## 「もう次の段階に進んでいる/マイグレーションが終わっている」場合の遅延タイムアウトを無視する
var _migration_token := 0
var _migration_overlay: CanvasLayer = null


func _ready() -> void:
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	EosManager.host_migrated.connect(_on_host_migrated)
	_apply_cmdline()


## 動作確認用。`-- client <addr>` を付けて world.tscn を直接起動するとロビーを飛ばす。
## ホストは world.gd 側で mode == NONE をホスト扱いするので指定不要。
##   godot --headless --path . res://scenes/world.tscn
##   godot --headless --path . res://scenes/world.tscn -- client 127.0.0.1
func _apply_cmdline() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("client")
	if i < 0:
		return
	mode = Mode.CLIENT
	session_kind = SessionKind.ONLINE
	if i + 1 < args.size():
		join_address = args[i + 1]


## ホストを始める。始められなければ false を返し、理由は last_error に入れる。
##
## ポートが空いているかを**シーンを移る前に**確かめるのが肝。
## world.tscn へ移ってから create_server に失敗すると、画面はゲームなのに
## 誰ともつながらない状態になる。しかも前回の Godot が生きたまま 9999 を
## 掴んでいるので、配った参加リンクは**その古いホスト**につながってしまい、
## 「参加者からは begin しない・こちらの操作が届かない」という
## 極めて分かりにくい症状になる（実際にこれで詰まった）。
## @param is_online: true ならオンライン対戦（レート対象になり得る）、false ならソロ練習
func start_host(is_online: bool = false) -> bool:
	var probe := TCPServer.new()
	var err := probe.listen(PORT)
	probe.stop()
	if err != OK:
		last_error = ("ポート %d が既に使われています。
"
			+ "前に起動した Godot（ゲーム）が残っていないか確認して、閉じてから試してください。") % PORT
		return false
	mode = Mode.HOST
	session_kind = SessionKind.ONLINE if is_online else SessionKind.SOLO
	# ②EOSロビー経由の参加者が実際に接続できるよう、LAN IPを即座に解決しておく。
	# トンネル（インターネット越し）を使う場合は _launch_tunnel() 側で後から上書きする
	public_address = _resolve_lan_address()
	if not public_address.is_empty():
		public_address_ready.emit(public_address)
	get_tree().change_scene_to_file(WORLD_SCENE)
	return true


## プライベートIPv4アドレスを1つ選ぶ（LAN内の参加者が直接繋げるアドレス）。
## WSL/Hyper-V/Dockerの仮想アダプタ(172.x)よりも物理LAN(192.168.x, 10.x)を優先する
func _resolve_lan_address() -> String:
	var addrs := IP.get_local_addresses()
	# 1. 192.168.x.x (家庭内LAN最優先)
	for addr in addrs:
		if addr.begins_with("192.168.") and addr.is_valid_ip_address():
			return addr
	# 2. 10.x.x.x
	for addr in addrs:
		if addr.begins_with("10.") and addr.is_valid_ip_address() and not ":" in addr:
			return addr
	# 3. 172.16.x.x - 172.31.x.x (WSL/Hyper-V等の仮想NICの可能性あり)
	for addr in addrs:
		if _is_private_ipv4(addr):
			return addr
	return ""


func _is_private_ipv4(addr: String) -> bool:
	if ":" in addr or not addr.is_valid_ip_address():
		return false  # IPv6 は対象外
	if addr.begins_with("127."):
		return false  # ループバック
	if addr.begins_with("192.168.") or addr.begins_with("10."):
		return true
	if addr.begins_with("172."):
		var second := addr.split(".")[1].to_int()
		return second >= 16 and second <= 31
	return false


func start_client(address: String) -> void:
	mode = Mode.CLIENT
	session_kind = SessionKind.ONLINE
	join_address = address
	get_tree().change_scene_to_file(WORLD_SCENE)


## 入力されたアドレスを接続先 URL にする。
##
## LAN の IP は従来どおり平文の ws://IP:9999。ホスト名が来た場合は
## トンネル（Cloudflare 等）経由とみなして wss://host（443）にする。
## https で配信された Web ビルドからは ws:// が mixed content でブロックされるため、
## 外部公開の経路は必ず wss でなければならない。
func resolve_url(addr: String) -> String:
	if addr.begins_with("ws://") or addr.begins_with("wss://"):
		return addr
	var host := addr
	var port := PORT
	var colon := addr.rfind(":")
	if colon > 0:
		host = addr.substr(0, colon)
		port = addr.substr(colon + 1).to_int()
	if host == "localhost" or host.is_valid_ip_address():
		# 同一マシン内での接続（ローカルテスト等）の場合はファイアウォールや自己ルーティング問題を避けるため 127.0.0.1 に繋ぐ
		if host in IP.get_local_addresses():
			host = "127.0.0.1"
		return "ws://%s:%d" % [host, port]
	return "wss://%s" % host


## world._ready() から呼ばれ、実際にピアを生成する。
func setup_peer() -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	var err: Error
	if mode == Mode.HOST:
		err = peer.create_server(PORT)
	else:
		err = peer.create_client(resolve_url(join_address))
	if err != OK:
		if mode == Mode.HOST:
			last_error = ("ポート %d で待ち受けられませんでした。
"
				+ "前に起動した Godot（ゲーム）が残っていないか確認してください。") % PORT
		else:
			last_error = "通信を開始できませんでした（エラー %d）" % err
		# ここは world.tscn の _ready() の途中。その場でシーンを差し替えると
		# 「Parent node is busy adding/removing children」で失敗し、
		# タイトルにも戻れない半端な状態のまま残る
		leave.call_deferred()
		return err
	multiplayer.multiplayer_peer = peer
	if mode == Mode.HOST:
		_launch_tunnel()
	return OK


## HOST 開始と同時に Cloudflare Tunnel を張って参加リンクを作る（tools/serve.ps1）。
## そのスクリプトは Get-NetTCPConnection / Set-Clipboard など Windows PowerShell 前提なので
## Windows デスクトップ版でのみ起動する。同一プロセス内で再ホストしても、前のトンネルが
## まだ生きていれば張り直さない（cloudflare 側のサブドメインが変わって混乱するのを防ぐ）
func _launch_tunnel() -> void:
	if OS.has_feature("web") or OS.get_name() != "Windows":
		return
	# ヘッドレス（テストや CI）ではトンネルを張らない。
	# ここを塞がないと tests/ でホストを起こすたびに公開トンネルが増え、
	# 実行が終わっても cloudflared が residual プロセスとして残り続ける
	if DisplayServer.get_name() == "headless":
		return
	if _tunnel_pid != -1 and OS.is_process_running(_tunnel_pid):
		# 前のトンネルを使い回す場合、poll は再始動しない（既に止まっている）ため、
		# ここで改めて emit しないと新しく作ったロビーの host_addr がLAN内IPのまま
		# 更新されず止まる（await_host_addr はホスト名が来るまで待ち続けるため）
		if not public_address.is_empty():
			public_address_ready.emit(public_address)
		return
	var script_path := _prepare_tunnel_script()
	if script_path.is_empty():
		return
	var host_file := ProjectSettings.globalize_path(TUNNEL_HOST_FILE)
	# 前回の記録が残っていると、今回まだ確立していないのに古いホスト名を拾ってしまう
	if FileAccess.file_exists(TUNNEL_HOST_FILE):
		DirAccess.remove_absolute(host_file)
	# create_process は PID をそのまま返す（失敗時 -1）。辞書ではない
	# pwsh (PowerShell Core) が入っていない環境向けに、Windows PowerShell へフォールバックする
	# (tools/serve.ps1 自体はどちらでも動く内容で書かれている)
	var ps_args := ["-NoProfile", "-File", script_path, "-HostAddrFile", host_file]
	_tunnel_pid = OS.create_process("pwsh", ps_args, true)
	if _tunnel_pid == -1:
		_tunnel_pid = OS.create_process("powershell", ps_args, true)
	_start_tunnel_poll()


## res://tools/serve.ps1 は（embed_pck の書き出し版では）PCK内の仮想パスで、
## OS側の実ファイルではないため pwsh/powershell の -File には直接渡せない
## （eos_credentials.cfg と違い、これは外部プロセスが直接開く必要があるため
## include_filter でPCKに含めるだけでは足りない）。毎回 user:// に実ファイルとして
## 書き出し、そちらの実パスを返す
func _prepare_tunnel_script() -> String:
	const EXTRACTED_PATH := "user://serve.ps1"
	var src := FileAccess.open("res://tools/serve.ps1", FileAccess.READ)
	if src == null:
		push_warning("[NetworkManager] tools/serve.ps1 を読み込めませんでした。トンネルを起動できません")
		return ""
	var content := src.get_as_text()
	src.close()
	var dst := FileAccess.open(EXTRACTED_PATH, FileAccess.WRITE)
	if dst == null:
		push_warning("[NetworkManager] serve.ps1 の書き出しに失敗しました。トンネルを起動できません")
		return ""
	# store_string() は BOM を付けない。Windows PowerShell 5.1 は BOM 無し .ps1 を
	# システムのANSIコードページとして読むため、日本語コメント/文字列が文字化けして
	# パースエラーになる。UTF-8 BOM を明示的に先頭へ書いて防ぐ
	dst.store_8(0xEF)
	dst.store_8(0xBB)
	dst.store_8(0xBF)
	dst.store_string(content)
	dst.close()
	return ProjectSettings.globalize_path(EXTRACTED_PATH)


## ②cloudflared の起動には数秒かかる。tools/serve.ps1 がホスト名をファイルに
## 書き出すのを短い間隔で待ち、見つかったら public_address をトンネル経由に昇格させる
func _start_tunnel_poll() -> void:
	if _tunnel_poll_timer:
		return
	_tunnel_poll_elapsed = 0.0
	_tunnel_poll_timer = Timer.new()
	_tunnel_poll_timer.wait_time = TUNNEL_POLL_INTERVAL
	_tunnel_poll_timer.timeout.connect(_on_tunnel_poll_tick)
	add_child(_tunnel_poll_timer)
	_tunnel_poll_timer.start()


func _on_tunnel_poll_tick() -> void:
	_tunnel_poll_elapsed += TUNNEL_POLL_INTERVAL
	if FileAccess.file_exists(TUNNEL_HOST_FILE):
		var f := FileAccess.open(TUNNEL_HOST_FILE, FileAccess.READ)
		var host := f.get_as_text().strip_edges() if f else ""
		if not host.is_empty():
			public_address = host
			public_address_ready.emit(public_address)
			_stop_tunnel_poll()
			return
	if _tunnel_poll_elapsed >= TUNNEL_POLL_TIMEOUT:
		_stop_tunnel_poll()


func _stop_tunnel_poll() -> void:
	if _tunnel_poll_timer:
		_tunnel_poll_timer.stop()
		_tunnel_poll_timer.queue_free()
		_tunnel_poll_timer = null


func leave() -> void:
	# ⑨connection_failed等、_migration_failed()を経由しない経路からleave()が
	# 呼ばれた場合の後始末(再接続試行中の接続失敗など)。既にクリア済みなら無害
	is_migrating = false
	_pending_host_penalty = {}
	_hide_migration_overlay()
	mode = Mode.NONE
	session_kind = SessionKind.SOLO
	public_address = ""
	matched_via_eos_lobby = false
	_stop_tunnel_poll()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	GameManager.reset()
	# EOSロビー経由のセッションだった場合、ここで明示的に抜けておかないと
	# ロビーがゴースト状態(検索には出るがホストの実体はもう無い)のまま残り続ける
	if not EosManager.current_lobby_id.is_empty():
		EosManager.leave_lobby()
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_connection_failed() -> void:
	last_error = "ホストに接続できませんでした"
	leave()


func _on_server_disconnected() -> void:
	last_error = "ホストとの接続が切れました"
	if not _should_attempt_migration():
		leave()
		return
	# ⑨旧ホスト(peer_id==1)のペナルティ計算に必要な情報は、まだ生きている今のうちに
	# ローカルのレプリケート済み状態から確保しておく(GameManager.reset()で失われる前)
	_pending_host_penalty = GameManager.snapshot_for_host_disconnect_penalty()
	is_migrating = true
	_show_migration_overlay("ホストとの接続が切れました。引き継ぎ先を確認しています…")
	_start_migration_timeout(MIGRATION_OWNER_WAIT_SEC)


## ⑨EOSロビー経由(クイックマッチ/ルームマッチ)の対戦のみマイグレーションを試みる。
## DirectConnect(招待リンク/IP直結)はEOSロビーを持たないため対象外(現状どおりleave()へ)
func _should_attempt_migration() -> bool:
	return matched_via_eos_lobby and EosManager.is_eos_available \
		and not EosManager.current_lobby_id.is_empty()


## EosManager.host_migrated(EOSロビーのオーナー自動昇格)を受けて、実際にホストを
## 差し替える。is_migrating中でなければ無関係なロビーイベントとして無視する
func _on_host_migrated(_new_owner_puid: String, i_am_new_host: bool) -> void:
	if not is_migrating:
		return
	if i_am_new_host:
		if EosManager.can_host_of(EosManager.product_user_id):
			# ⑨自分がホストとして確定した時点でペナルティを報告する
			# (新ホストに昇格した端末だけが報告する。friend-apiはpuidキーの単純上書きで
			# 冪等なため、_migration_failed()側の全員報告フォールバックと重複しても安全)
			_report_pending_host_penalty()
			_promote_self_to_host()
		elif await EosManager.handoff_if_incapable():
			# Web版等ホストになれない端末が昇格した場合。can_host=1の別メンバーへ委譲済みで、
			# 再度host_migratedが発火するのを待つ
			_update_migration_status("別のプレイヤーへホストを引き継いでいます…")
			_start_migration_timeout(MIGRATION_OWNER_WAIT_SEC)
		else:
			_migration_failed("ホストを引き継げるプレイヤーがいませんでした")
	else:
		_update_migration_status("新しいホストの準備を待っています…")
		# ⑨オーナー確定待ち(15秒)のタイムアウトがまだ有効なままだと、新ホストの
		# トンネル確立を待っている最中(最大30秒)に誤って_migration_failed()してしまう。
		# 世代カウンタを進めて古いタイムアウトを無効化してから再接続待ちに入る
		_start_migration_timeout(MIGRATION_RECONNECT_WAIT_SEC)
		_reconnect_as_client()


func _promote_self_to_host() -> void:
	_update_migration_status("あなたが新しいホストになりました。準備しています…")
	_reset_for_migration()
	mode = Mode.HOST
	session_kind = SessionKind.ONLINE
	public_address = _resolve_lan_address()
	if not public_address.is_empty():
		public_address_ready.emit(public_address)
	_start_migration_timeout(MIGRATION_RECONNECT_WAIT_SEC)
	get_tree().change_scene_to_file(WORLD_SCENE)


## ⑨新ホストがhost_addr属性を更新するまでポーリングする
## (EosManager.await_host_addr()を長い待ち時間で再利用)
func _reconnect_as_client() -> void:
	var addr := await EosManager.await_host_addr(
		EosManager.current_lobby_id, int(MIGRATION_RECONNECT_WAIT_SEC / 0.5), 0.5)
	if not is_migrating:
		return  # 待っている間にタイムアウト等で既に処理済み
	if addr.is_empty():
		_migration_failed("新しいホストに接続できませんでした")
		return
	_reset_for_migration()
	start_client(addr)


## leave()のサブセット。GameManagerの試合状態はクリアするが、マイグレーション中は
## ロビー離脱・タイトル遷移をしない(それをするとマッチング自体が成立しなくなる)
func _reset_for_migration() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	GameManager.reset()


func _migration_failed(reason: String) -> void:
	if not is_migrating:
		return
	last_error = reason
	# ⑨新ホストが決まらなかった場合、生存者全員が独立に報告する(friend-apiは
	# puidキーの単純上書きで冪等なため、複数人が同じ値を送っても壊れない)
	_report_pending_host_penalty()
	is_migrating = false
	_hide_migration_overlay()
	leave()


func _report_pending_host_penalty() -> void:
	if _pending_host_penalty.is_empty():
		return
	var s: Dictionary = _pending_host_penalty
	_pending_host_penalty = {}
	# 固定値1500ではなく、reset()前にsnapshot_for_host_disconnect_penalty()が
	# 確保しておいた実際の相手陣営レートを使う(apply_match_end()と同じ修正)
	var delta := RankingManager.calculate_rating_delta(
		s.was_runner, false, s.survival, s.hunter_count, false, s.self_rating,
		int(s.get("opponent_avg_rating", 1500)))
	FriendManager.report_disconnect_penalty(s.puid, delta)


## SceneTreeTimerは後から止められないため、世代カウンタ(_migration_token)で
## 「発火時点でまだこの段階を待っているか」を確認してから_migration_failed()を呼ぶ
func _start_migration_timeout(seconds: float) -> void:
	_migration_token += 1
	var token := _migration_token
	get_tree().create_timer(seconds).timeout.connect(
		func() -> void:
			if is_migrating and token == _migration_token:
				_migration_failed("ホストの引き継ぎがタイムアウトしました")
	)


func _update_migration_status(text: String) -> void:
	if _migration_overlay != null:
		_migration_overlay.set_text(text)
	migration_status_changed.emit(text)


func _show_migration_overlay(text: String) -> void:
	if _migration_overlay == null:
		var scene: PackedScene = load(MIGRATION_OVERLAY_SCENE)
		_migration_overlay = scene.instantiate()
		get_tree().root.add_child(_migration_overlay)
	_update_migration_status(text)


func _hide_migration_overlay() -> void:
	if _migration_overlay != null:
		_migration_overlay.queue_free()
		_migration_overlay = null


## world.gd._ready()から、新ホストのシーン起動完了(is_server()分岐の末尾)または
## クライアントの新ホストへの接続確立(connected_to_server)のタイミングで呼ばれる。
## マイグレーション中でなければ無害(通常の新規参加時にも無条件で呼ばれるため)
func finish_migration_if_active() -> void:
	if not is_migrating:
		return
	is_migrating = false
	_hide_migration_overlay()
