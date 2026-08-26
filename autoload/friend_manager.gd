extends Node

## ④Steam Friends API のラッパー Autoload。SteamManager と同じ方針
## （Steam無効時はモックデータでフォールバックし、クラッシュを防ぐ）に倣う。
##
## 実装注意: 以下で使う Steam.* API 名（getFriendCount / getFriendByIndex /
## getFriendPersonaName / getFriendPersonaState / inviteUserToLobby）は
## GodotSteam の一般的なバインディング名。addons/godotsteam はコンパイル済み
## GDExtensionのためテキスト検索で事前確認できておらず、導入バージョン(4.22)の
## 実際のメソッド一覧をGodotエディタのオートコンプリートで確認し、名称が異なる
## 場合はここだけ調整すること。

## GodotSteam の EFriendFlags 相当。フレンドのみを列挙する（k_EFriendFlagImmediate）
const FRIEND_FLAG_IMMEDIATE := 4

## EPersonaState 相当。0=Offline
const PERSONA_STATE_OFFLINE := 0


## ④フレンド一覧を返す。各要素: {steam_id, name, online, state}
func get_friends() -> Array[Dictionary]:
	if SteamManager.is_steam_available and Engine.has_singleton("Steam"):
		return _get_friends_from_steam()
	return _mock_friends()


func _get_friends_from_steam() -> Array[Dictionary]:
	var steam = Engine.get_singleton("Steam")
	var out: Array[Dictionary] = []
	var count: int = steam.getFriendCount(FRIEND_FLAG_IMMEDIATE)
	for i in range(count):
		var friend_id: int = steam.getFriendByIndex(i, FRIEND_FLAG_IMMEDIATE)
		var state: int = steam.getFriendPersonaState(friend_id)
		out.append({
			"steam_id": friend_id,
			"name": steam.getFriendPersonaName(friend_id),
			"online": state != PERSONA_STATE_OFFLINE,
			"state": state,
		})
	out.sort_custom(func(a, b):
		if a.online != b.online:
			return a.online
		return String(a.name) < String(b.name)
	)
	return out


## Steam無効時、④のUIをオフラインでも確認できるようにするモックフレンド一覧
func _mock_friends() -> Array[Dictionary]:
	return [
		{"steam_id": 900001, "name": "SpeedMaster", "online": true, "state": 1},
		{"steam_id": 900002, "name": "Ninja_Shadow", "online": false, "state": 0},
		{"steam_id": 900003, "name": "ChillRunner", "online": true, "state": 1},
	]


## ④自分がロビー中の場合のみ、フレンドをロビーに招待する
func invite_to_lobby(friend_steam_id: int) -> bool:
	if SteamManager.current_lobby_id == 0:
		return false
	if SteamManager.is_steam_available and Engine.has_singleton("Steam"):
		var steam = Engine.get_singleton("Steam")
		return steam.inviteUserToLobby(SteamManager.current_lobby_id, friend_steam_id)
	# オフラインモック: 招待自体は成功したことにする（UI確認用）
	return true
