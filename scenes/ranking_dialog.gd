extends Control

## ランキング（Leaderboard）ダイアログ。
## EOS Leaderboards、または(C-03 R-6・USE_LIVE_RATING_BACKEND有効時)自前rating-apiの
## /leaderboard-top からグローバルランキング、自身の現在順位、レート情報を表示。

signal closed

## ranking_manager.gdと同じ理由(headless単体実行でclass_nameのグローバル登録が
## 更新されていないケースへの対処)でpreloadを使う
const _RatingBackendClientScript := preload("res://autoload/rating_backend_client.gd")

@onready var rank_list_container: VBoxContainer = $Panel/VBox/Scroll/ListContainer
@onready var my_rank_val: Label = $Panel/VBox/MyStats/Grid/MyRankVal
@onready var my_name_val: Label = $Panel/VBox/MyStats/Grid/MyNameVal
@onready var my_rating_val: Label = $Panel/VBox/MyStats/Grid/MyRatingVal
@onready var status_label: Label = $Panel/VBox/StatusRow/StatusLabel
@onready var spinner := $Panel/VBox/StatusRow/Spinner
@onready var refresh_btn: Button = $Panel/VBox/TopRow/RefreshButton
@onready var close_btn: Button = $Panel/VBox/BottomRow/CloseButton


func _ready() -> void:
	refresh_btn.pressed.connect(refresh)
	close_btn.pressed.connect(_on_close_pressed)
	EosManager.leaderboard_loaded.connect(_on_leaderboard_loaded)


func open() -> void:
	show()
	refresh()


func refresh() -> void:
	spinner.set_active(true)
	status_label.text = tr("ランキングを取得中...")
	my_name_val.text = ProfileManager.player_name
	my_rating_val.text = "%s %d" % [tr(RankingManager.tier_name(ProfileManager.rating)), ProfileManager.rating]
	my_rank_val.text = "-"
	# C-03 R-6: サーバーデプロイ後(USE_LIVE_RATING_BACKEND=true)はrating-apiを優先する。
	# false(現状)の間は他のR-4/R-5と同じゲート規約により、既存のEOS経路(本物+
	# オフラインモック+橙バナー)をそのまま維持する
	if BackendConfig.USE_LIVE_RATING_BACKEND and EosManager.is_eos_available:
		_refresh_from_rating_api()
	else:
		EosManager.request_leaderboard()


## C-03 R-6: rating-apiの/leaderboard-topから取得する経路。EosManager.leaderboard_loaded
## 経由の_on_leaderboard_loaded()とは呼び出し元が違う(シグナルではなくawait)ため別関数にするが、
## 行描画ロジック(_render_entries())は共有する。フォールバックはしない(失敗時はEOS経路へ
## 自動で切り替えない、他の全rating-apiエンドポイントの「失敗時は諦める」既存規約と同じ)
func _refresh_from_rating_api() -> void:
	var res := await _RatingBackendClientScript.get_leaderboard_top(self)
	spinner.set_active(false)
	if not (res.get("api_ok", false) and res.get("ok", false)):
		status_label.text = tr("ランキングの取得に失敗しました。時間をおいて再度更新してください。")
		status_label.add_theme_color_override("font_color", Color(1, 0.4, 0.3, 1))
		_render_entries([])
		return
	status_label.text = tr("最新ランキングを取得しました")
	status_label.remove_theme_color_override("font_color")
	_render_entries(convert_rating_api_entries(res.get("entries", [])))


## rating-apiの{rank,puid,rating,tier_id,tier_name,matches_played}形式を、
## _render_entries()が期待する{rank,name,score,puid}形式に変換する純粋関数。
## rating-apiはPUIDから表示名を解決していない(DBに保存していない)ため、他プレイヤーの
## nameは汎用"Player"に固定する――EOS経路も同じ制約で既に"Player"固定(eos_manager.gd:503-512
## のコメント参照)のため、これはrating-api切替による表示劣化ではない。自分の行の名前上書きは
## _render_entries()内の既存is_my_entryロジックがそのまま処理するためここでは何もしない。
## tier_id/tier_nameは使わない(クライアント側はRankingManager.tier_name(score)で再計算する)
static func convert_rating_api_entries(raw: Array) -> Array:
	var out: Array = []
	for e in raw:
		out.append({
			"rank": e.get("rank", 0),
			"name": "Player",
			"score": e.get("rating", 0),
			"puid": str(e.get("puid", "")),
		})
	return out


func _on_leaderboard_loaded(entries: Array) -> void:
	spinner.set_active(false)
	# EOS未接続時はrequest_leaderboard()がモックデータを返すため、本物と誤認しないよう明示する
	# (受信のたびに再チェックしないと、リスト到着時にこの注記が上の行で上書きされて消える)。
	# L-05付随修正: EOS接続済みでもタイムアウト/エラー(last_leaderboard_error)なら、
	# 「本当に0件」と区別できるよう専用のエラー文言を出す(以前は常に成功文言のまま誤表示していた)
	if EosManager.is_eos_available and not EosManager.last_leaderboard_error.is_empty():
		status_label.text = tr("ランキングの取得に失敗しました。時間をおいて再度更新してください。")
		status_label.add_theme_color_override("font_color", Color(1, 0.4, 0.3, 1))
	elif not EosManager.is_eos_available:
		status_label.text = tr("EOSに接続されていないため、ランキングはサンプル表示です。")
		status_label.add_theme_color_override("font_color", Color(1.0, 0.75, 0.4))
	else:
		status_label.text = tr("最新ランキングを取得しました")
		status_label.remove_theme_color_override("font_color")
	_render_entries(entries)


func _render_entries(entries: Array) -> void:
	for child in rank_list_container.get_children():
		child.queue_free()

	if entries.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = tr("ランキングデータがまだありません。")
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		rank_list_container.add_child(empty_lbl)

		var empty_refresh_btn := Button.new()
		empty_refresh_btn.text = tr("更新する")
		empty_refresh_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		empty_refresh_btn.pressed.connect(refresh)
		rank_list_container.add_child(empty_refresh_btn)
		return
		
	var my_rank_found := false
	for entry in entries:
		var rank = int(entry.get("rank", 0))
		var p_name = str(entry.get("name", "Unknown"))
		var score = int(entry.get("score", 0))
		var entry_puid = str(entry.get("puid", ""))
		
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		
		var rank_lbl := Label.new()
		rank_lbl.custom_minimum_size = Vector2(50, 0)
		rank_lbl.text = "#%d" % rank
		if rank == 1:
			rank_lbl.add_theme_color_override("font_color", Color(1, 0.85, 0.2)) # Gold
		elif rank == 2:
			rank_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9)) # Silver
		elif rank == 3:
			rank_lbl.add_theme_color_override("font_color", Color(0.85, 0.55, 0.3)) # Bronze

		# ②レート帯（ティア）バッジ
		var tier_lbl := Label.new()
		tier_lbl.custom_minimum_size = Vector2(72, 0)
		tier_lbl.text = "[%s]" % tr(RankingManager.tier_name(score))
		tier_lbl.add_theme_color_override("font_color", RankingManager.tier_color(score))

		# 着せ替え画面での名前変更はEOS Connectのログイン済みDisplayNameへ次回ログインまで
		# 反映されない(autoload/eos_manager.gd:_on_profile_updated_for_display_nameのコメント参照)。
		# そのためリーダーボードのnameは古いままの場合があり、自分の行の表示だけは常に
		# 最新の ProfileManager.player_name で上書きする
		var is_my_entry := not entry_puid.is_empty() and entry_puid == EosManager.product_user_id
		var display_name: String = ProfileManager.player_name if is_my_entry else p_name

		var name_lbl := Label.new()
		name_lbl.text = display_name
		name_lbl.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED  # プレイヤー名は利用者の入力(L-09)
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var score_lbl := Label.new()
		score_lbl.text = "%d Pt" % score
		score_lbl.add_theme_color_override("font_color", Color(0.35, 0.85, 1))

		# row の中身は常に組み立てる（自分の行だけ後でハイライト用パネルに包む）
		row.add_child(rank_lbl)
		row.add_child(tier_lbl)
		row.add_child(name_lbl)
		row.add_child(score_lbl)

		# 自身のデータか判定: puidが両方に入っていればそれで判定する(表示名の鮮度に
		# 依存しないため確実)。オフラインモック(puidが無い)では名前一致にフォールバックする
		var is_me := is_my_entry or (entry_puid.is_empty() and p_name == ProfileManager.player_name)
		if is_me:
			my_rank_val.text = "#%d" % rank
			my_rank_found = true
			var style := StyleBoxFlat.new()
			style.bg_color = Color(0.2, 0.4, 0.6, 0.4)
			style.set_corner_radius_all(8)
			var panel := PanelContainer.new()
			panel.add_theme_stylebox_override("panel", style)
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			panel.add_child(row)
			rank_list_container.add_child(panel)
		else:
			rank_list_container.add_child(row)
			
	if not my_rank_found:
		my_rank_val.text = tr("圏外")


func _on_close_pressed() -> void:
	closed.emit()
	hide()
