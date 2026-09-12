extends Node

## GameManager の子ノード。接続直後のプロトコル版数照合を持つ。
## PROTOCOL_VERSION 定数自体は単一の定数を分裂させないため GameManager 側に残し、
## ここからは GameManager.PROTOCOL_VERSION を直接参照する
## (v6でのGameManager分割時に切り出した。詳細はgame_manager.gdのバージョン履歴参照)。

## 参加者から版数の返事が来るのを待つ時間。古いビルドには ack_version 自体が
## 無いので、無反応もまた「食い違っている」ことの手がかりになる。
## ただし回線が遅いだけの可能性もあるので、無反応では蹴らず警告に留める
const VERSION_ACK_TIMEOUT := 10.0

var _awaiting_version := {}   # ホスト専用。peer_id -> 返事待ちの経過秒


## ホストのみ。接続直後に版数を送り、返事が来るまで見張る
func begin_version_check(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	_awaiting_version[peer_id] = 0.0
	check_version.rpc_id(peer_id, GameManager.PROTOCOL_VERSION)


## ホスト -> 参加者。**この2つのシグネチャだけは絶対に変えないこと。**
## 変えると照合そのものが食い違って、何も知らせられなくなる
@rpc("authority", "reliable")
func check_version(host_version: int) -> void:
	ack_version.rpc_id(1, GameManager.PROTOCOL_VERSION)
	if host_version == GameManager.PROTOCOL_VERSION:
		return
	NetworkManager.last_error = (
		"ゲームのバージョンが違います（ホスト v%d / あなた v%d）。
"
		+ "ブラウザなら再読み込み（Ctrl+Shift+R）、PC なら最新版で起動しなおしてください。"
	) % [host_version, GameManager.PROTOCOL_VERSION]
	NetworkManager.leave()


## 参加者 -> ホスト
@rpc("any_peer", "reliable")
func ack_version(peer_version: int) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	_awaiting_version.erase(id)
	if peer_version == GameManager.PROTOCOL_VERSION:
		return
	# 食い違いが確定した場合だけ切る。放っておくと「つながっているのに
	# 状態が同期しない」まま延々と続き、原因が分からない
	GameManager.notify_host("参加者のビルドが違います（あなた v%d / 相手 v%d）。
Web 版を再デプロイして、ブラウザを再読み込みしてもらってください。"
		% [GameManager.PROTOCOL_VERSION, peer_version])
	multiplayer.multiplayer_peer.disconnect_peer(id)


## 返事が来ない参加者を見張る。回線が遅いだけのこともあるので蹴らず警告に留める
func _tick_version_checks(delta: float) -> void:
	for id in _awaiting_version.keys():
		_awaiting_version[id] = _awaiting_version[id] + delta
		if _awaiting_version[id] < VERSION_ACK_TIMEOUT:
			continue
		_awaiting_version.erase(id)
		GameManager.notify_host("参加者 %d から応答がありません。
古いビルドで参加している可能性があります（Web 版の再デプロイと再読み込みを試してください）。" % id)
