extends Node

## タイトル/ロビー系画面(タイトル・きせかえ・ショップ・フレンド・設定)で流れるBGMを
## 管理するAutoload。これらの画面は scenes/title.gd 等が change_scene_to_file() で
## 互いに切り替えるため、シーンの子としてAudioStreamPlayerを置くと画面遷移のたびに
## 再生が止まってしまう。Autoloadに持たせることでシーンをまたいで鳴り続けさせる。
##
## 音量は追加の配線をせず、Masterバス経由でSettingsManagerのマスター音量スライダーが
## そのまま効く(現状Masterバス1本のみ。docs/concept/audio/title_bgm/SPEC.md 参照)。
##
## 対戦中(world.tscn)は鳴らさない。NetworkManager.start_host() / start_client() で
## stop_lobby_bgm()、leave() で play_lobby_bgm() を呼び、対戦の開始/終了と連動させる。

const LOBBY_BGM := preload("res://assets/audio/bgm/title_bgm.ogg")

var _player: AudioStreamPlayer


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.bus = "Master"
	add_child(_player)

	# レビュー済みの参考音源はファイル全体が1ループ分(docs/concept/audio/title_bgm/REVIEW.md
	# 第4版でPASS済み)。ループ開始点は指定せず、末尾から先頭へそのまま戻す。
	# constをas castした式へ直接プロパティ代入すると
	# 「Cannot assign a new value to a constant」になるため、一度ローカル変数へ受ける
	var bgm := LOBBY_BGM as AudioStreamOggVorbis
	if bgm:
		bgm.loop = true
	_player.stream = LOBBY_BGM

	play_lobby_bgm()


func play_lobby_bgm() -> void:
	if not _player.playing:
		_player.play()


func stop_lobby_bgm() -> void:
	if _player.playing:
		_player.stop()
