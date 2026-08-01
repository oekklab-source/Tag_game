extends Node

## 置き物アイテム（バナナ・ブロック）が実際に生成されるかを確かめる。
##
##   godot --headless --path . res://tests/item_drop.tscn --quit-after 900
##
## 本物の world.tscn を current_scene に据えて動かす。
## GameManager.request_drop が current_scene 経由で spawn_dropped_item を呼ぶので、
## ここを差し替えると経路を実際には検証できなくなる。
##
## ラウンド外（WAITING）でも置けることを見るのが要点。
## 以前ここが PLAYING 限定で、？ブロック側には状態の判定が無かったため、
## マップを歩き回って試すとアイテムだけ消えて何も置かれなかった。


func _ready() -> void:
	# root は _ready の最中に子を追加できないので1フレーム待つ
	await get_tree().process_frame
	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world
	for i in 20:
		await get_tree().physics_frame

	var player: Node = world.get_node_or_null("Players/1")
	if player == null:
		print("FAIL: プレイヤーがスポーンしていない")
		get_tree().quit()
		return
	var items: Node = world.get_node("Items")

	print("--- state=WAITING（ラウンド外）---")
	await _drop_all(player, items)
	GameManager.state = GameManager.State.PLAYING
	GameManager.head_start_left = 0.0
	print("--- state=PLAYING ---")
	await _drop_all(player, items)

	# ？ブロックから受け取れるかも見る（触れた時と同じ経路を通す）
	var qblock: Node = world.get_node_or_null("NavRegion/Gimmicks/QuestionBlock0")
	if qblock == null:
		print("FAIL: ？ブロックが無い")
	else:
		player.item = Player.Item.NONE
		qblock._on_touch(player)
		await get_tree().physics_frame
		print("  question block -> item %d  %s"
			% [player.item, "OK" if player.item != Player.Item.NONE else "FAIL"])

	print("--- InputMap ---")
	for a in InputMap.get_actions():
		if String(a).begins_with("ui_"):
			continue
		var keys := PackedStringArray()
		for e in InputMap.action_get_events(a):
			if e is InputEventKey:
				keys.append(OS.get_keycode_string(e.physical_keycode))
			elif e is InputEventMouseButton:
				keys.append("Mouse%d" % e.button_index)
		print("  %-14s %s" % [a, ", ".join(keys)])
	get_tree().quit()


func _drop_all(player: Node, items: Node) -> void:
	for kind in [Player.Item.BANANA, Player.Item.BLOCK]:
		var before := items.get_child_count()
		player.item = kind
		player._use_item()
		await get_tree().physics_frame
		var after := items.get_child_count()
		print("  item %d: %d -> %d  %s"
			% [kind, before, after, "OK" if after > before else "FAIL"])
		if after > before:
			var drop: Node3D = items.get_child(after - 1)
			var layer: int = drop.collision_layer if drop is CollisionObject3D else -1
			print("    %s  layer=%d  script=%s" % [drop.name, layer,
				drop.get_script().resource_path.get_file() if drop.get_script() else "-"])
