extends RefCounted

## eos_credentials.cfg の中身の検証（純ロジック、副作用なし）。
## 実行時の EosManager._load_credentials() と、書き出し時の
## addons/tag_game_export_guard/export_guard.gd（tools/export_windows.ps1 が目印を拾う）の
## 両方から preload して使う。
## 「どの項目が空なら未設定扱いか」を1か所に置き、両者の判定がずれないようにするため。
##
## class_name を付けないのは、エディタの export プラグイン（@tool）からも
## Autoload の初期化順序やグローバルクラス登録に依存せず読めるようにするため
## （preload した Script の static 関数を呼ぶだけで完結する）。
##
## 【平文同梱は意図どおり】このファイルは Windows 版の .pck へ平文のまま同梱される
## （export_presets.cfg の include_filter）。Client Secret を含むが、Client Policy が
## GameClient 型である限り「クライアントバイナリに埋め込む前提」の認証情報であり
## （Epic 公式 dev-portal/client-credentials、2026-09-20 確認）、encryption_key も
## 全クライアントが同じ値を持つ必要があるため原理的に秘匿できない。
## 守るべきは「漏れないこと」ではなく「空のまま黙って出荷しないこと」（Phase 3 L-08）。

const REQUIRED_KEYS: PackedStringArray = [
	"product_id", "sandbox_id", "deployment_id", "client_id", "client_secret",
]

## Player Data Storage 用の 256bit キー（64桁の16進数）
const ENCRYPTION_KEY_HEX_LEN := 64


## 実行時に EOS を初期化してよいか（必須5項目がすべて埋まっているか）。
## encryption_key は見ない。空でもロビー/ランキングは動くので、従来どおり
## 起動は許す（クラウドセーブだけが失敗する。出荷前には find_problems() で弾く）。
static func is_runtime_usable(cfg: ConfigFile) -> bool:
	for key in REQUIRED_KEYS:
		if str(cfg.get_value("eos", key, "")).is_empty():
			return false
	return true


## 書き出してよいかの検査。問題点を人が読める文で返す（空配列なら問題なし）。
## is_runtime_usable() より厳しく、encryption_key の空欄・形式違いも問題として返す
## （空のまま出荷するとクラウドセーブが常に黙って失敗し、気付けないため）。
static func find_problems(path: String) -> PackedStringArray:
	var problems := PackedStringArray()
	if not FileAccess.file_exists(path):
		problems.append("%s が存在しない（eos_credentials.cfg.example をコピーして作る）" % path)
		return problems

	var cfg := ConfigFile.new()
	var err := cfg.load(path)
	if err != OK:
		problems.append("%s を読み込めない（error %d）" % [path, err])
		return problems

	for key in REQUIRED_KEYS:
		if str(cfg.get_value("eos", key, "")).is_empty():
			problems.append("[eos] %s が空" % key)

	var encryption_key := str(cfg.get_value("eos", "encryption_key", ""))
	if encryption_key.is_empty():
		problems.append("[eos] encryption_key が空（クラウドセーブが常に失敗する）")
	elif encryption_key.length() != ENCRYPTION_KEY_HEX_LEN or not _is_plain_hex(encryption_key):
		problems.append("[eos] encryption_key が%d桁の16進数ではない（%d文字）" \
				% [ENCRYPTION_KEY_HEX_LEN, encryption_key.length()])
	return problems


## 0-9a-fA-F だけで構成されているか。String.is_valid_hex_number() は先頭の符号を
## 許すので使わない（"-" 付き64文字を通してしまう）。
static func _is_plain_hex(s: String) -> bool:
	for c in s:
		if not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f") or (c >= "A" and c <= "F")):
			return false
	return true
