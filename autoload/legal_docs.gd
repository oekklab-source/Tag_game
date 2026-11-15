class_name LegalDocs
extends RefCounted

## 法務3文書（利用規約・プライバシーポリシー・特定商取引法に基づく表記）の公開URLと、
## 初回起動の同意画面の版を1か所にまとめる（KAN-19 / KAN-20 / KAN-21 / KAN-27）。
##
## URL は公開先が決まる（KAN-19）まで空にしておく。空の間は、タイトルの同意画面・
## クレジット画面とショップのリンクを**出さない**。リンク切れや、まだ読めない文書への
## 同意を求めるのを避けるため。公開したらここの3つを埋めるだけで全部の導線が出る。

const TERMS_URL := ""
const PRIVACY_URL := ""
const TOKUSHOHO_URL := ""

## 同意画面の版。文書の中身を変えて同意を取り直したいときに上げると、次の起動でもう一度出す
## （同意した版は ProfileManager.legal_agreed_version に残る）
const VERSION := 1

const KINDS: Array[StringName] = [&"terms", &"privacy", &"tokushoho"]

## テスト用。空でない URL を差し込んで、公開後の見た目と動きを確かめる
static var url_override := {}


static func url(kind: StringName) -> String:
	if url_override.has(kind):
		return String(url_override[kind])
	match kind:
		&"terms":
			return TERMS_URL
		&"privacy":
			return PRIVACY_URL
		&"tokushoho":
			return TOKUSHOHO_URL
	return ""


## 画面に出す名前。tr() で英訳する
static func title(kind: StringName) -> String:
	match kind:
		&"terms":
			return TranslationServer.translate("利用規約")
		&"privacy":
			return TranslationServer.translate("プライバシーポリシー")
		&"tokushoho":
			return TranslationServer.translate("特定商取引法に基づく表記")
	return ""


## 3つとも公開済みか。1つでも欠けていれば導線は出さない（一部だけ出すと、読めない文書への同意になる）
static func published() -> bool:
	for k in KINDS:
		if url(k).is_empty():
			return false
	return true


static func needs_consent() -> bool:
	return published() and ProfileManager.legal_agreed_version < VERSION


static func agree() -> void:
	ProfileManager.legal_agreed_version = VERSION
	ProfileManager.save_profile()


static func open(kind: StringName) -> void:
	var u := url(kind)
	if not u.is_empty():
		OS.shell_open(u)
