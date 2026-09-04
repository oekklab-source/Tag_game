extends Control

## ランキング（Leaderboard）ダイアログ。
## EOS Leaderboards からのグローバルランキング、自身の現在順位、レート情報を表示。

signal closed

@onready var rank_list_container: VBoxContainer = $Panel/VBox/Scroll/ListContainer
@onready var my_rank_val: Label = $Panel/VBox/MyStats/Grid/MyRankVal
@onready var my_name_val: Label = $Panel/VBox/MyStats/Grid/MyNameVal
@onready var my_rating_val: Label = $Panel/VBox/MyStats/Grid/MyRatingVal
@onready var status_label: Label = $Panel/VBox/StatusLabel
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
	status_label.text = "ランキングを取得中..."
	my_name_val.text = ProfileManager.player_name
	my_rating_val.text = "%s %d" % [RankingManager.tier_name(ProfileManager.rating), ProfileManager.rating]
	my_rank_val.text = "-"
	EosManager.request_leaderboard()


func _on_leaderboard_loaded(entries: Array) -> void:
	status_label.text = "最新ランキングを取得しました"
	for child in rank_list_container.get_children():
		child.queue_free()
		
	if entries.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "ランキングデータがまだありません。"
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		rank_list_container.add_child(empty_lbl)
		return
		
	var my_rank_found := false
	for entry in entries:
		var rank = int(entry.get("rank", 0))
		var p_name = str(entry.get("name", "Unknown"))
		var score = int(entry.get("score", 0))
		
		var row := HBoxContainer.new()
		row.theme_override_constants.separation = 16
		
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
		tier_lbl.text = "[%s]" % RankingManager.tier_name(score)
		tier_lbl.add_theme_color_override("font_color", RankingManager.tier_color(score))

		var name_lbl := Label.new()
		name_lbl.text = p_name
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var score_lbl := Label.new()
		score_lbl.text = "%d Pt" % score
		score_lbl.add_theme_color_override("font_color", Color(0.35, 0.85, 1))

		# row の中身は常に組み立てる（自分の行だけ後でハイライト用パネルに包む）
		row.add_child(rank_lbl)
		row.add_child(tier_lbl)
		row.add_child(name_lbl)
		row.add_child(score_lbl)

		# 自身のデータならハイライト
		if p_name == ProfileManager.player_name:
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
		my_rank_val.text = "圏外"


func _on_close_pressed() -> void:
	closed.emit()
	hide()
