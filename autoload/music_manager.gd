extends Node

## タイトル/ロビー系画面(タイトル・きせかえ・ショップ・フレンド・設定)で流れるBGMを
## 管理するAutoload。これらの画面は scenes/title.gd 等が change_scene_to_file() で
## 互いに切り替えるため、シーンの子としてAudioStreamPlayerを置くと画面遷移のたびに
## 再生が止まってしまう。Autoloadに持たせることでシーンをまたいで鳴り続けさせる。
##
## 音量は追加の配線をせず、Masterバス経由でSettingsManagerのマスター音量スライダーが
## そのまま効く(現状Masterバス1本のみ。docs/concept/audio/title_bgm/SPEC.md 参照。
## docs/ 配下は .gdignore で Godot のリソース対象外なので、res:// では読めない
## ドキュメント専用の置き場である。Phase 3 L-11)。
##
## 対戦中(world.tscn)は鳴らさない。NetworkManager.start_host() / start_client() で
## stop_lobby_bgm()、leave() で play_lobby_bgm() を呼び、対戦の開始/終了と連動させる。
## ただしこの連動は NetworkManager を経由したときだけ効く。READMEのデバッグ起動
## (godot --path . res://scenes/world.tscn の直起動)は start_host() を通らないため、
## _ready() で無条件に再生すると対戦中もロビーBGMが鳴り続ける(C-07 T-8 / RV-16)。
## そのため起動時の再生開始だけは「現在シーンが world.tscn でないこと」を見て判断する。

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

	# Autoload の _ready() はメインシーンより先に走るので、この時点では
	# get_tree().current_scene がまだ null。1フレーム待ってから判定する
	await get_tree().process_frame
	_play_unless_in_match()


## 起動時の再生開始のみ。world.tscn を直起動したデバッグ実行では鳴らさない
## (ヘッダのコメント参照)。通常起動(title.tscn)では従来どおり即座に鳴り始める
func _play_unless_in_match() -> void:
	var scene := get_tree().current_scene
	if scene != null and scene.scene_file_path == NetworkManager.WORLD_SCENE:
		return
	play_lobby_bgm()


func play_lobby_bgm() -> void:
	if not _player.playing:
		_player.play()


func stop_lobby_bgm() -> void:
	if _player.playing:
		_player.stop()
