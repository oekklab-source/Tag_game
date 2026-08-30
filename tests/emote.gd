extends Node

## 2ピアをつないで「エモートが相手に届き、勝手に消えるか」を確かめる。
##
##   ホスト:     godot --headless --path . res://tests/emote.tscn -- host
##   クライアント: godot --headless --path . res://tests/emote.tscn -- client 127.0.0.1
##
## 見ているのは3点:
##   1. 権威ピアが出したエモートが sync_emote として相手に届く
##   2. EMOTE_TIME 後に必ず 0 へ戻る（ここが抜けると吹き出しが出っぱなしになる）
##   3. 0 を挟むので**同じエモートを続けて出しても** ON_CHANGE の同期が再度発火する
##      （ここが壊れると2回目以降が相手の画面に出ない。値で比べる同期の罠）
##
## 入力は実際の経路（Input.action_press("emote")）で押す。_start_emote() を
## 直接呼ぶと、キー割り当てとクールダウンの検証にならない。

const SETTLE := 0.4  # 同期が届くのを待つ余裕


func _ready() -> void:
	var is_host := NetworkManager.mode != NetworkManager.Mode.CLIENT
	await get_tree().process_frame
	var world: Node = load("res://scenes/world.tscn").instantiate()
	get_tree().root.add_child(world)
	get_tree().current_scene = world

	if is_host:
		await _run_host(world)
	else:
		await _run_client(world)
	get_tree().quit()


func _run_host(world: Node) -> void:
	if not await _wait_peer():
		print("HOST: FAIL クライアントが接続してこなかった")
		return
	var me: Node3D = world.get_node_or_null("Players/1")
	# 1回目: 待機中なので「ナイス」
	await _press_emote()
	print("HOST: 1回目 sync_emote=%d（期待 %d = ナイス）" % [me.sync_emote, Player.Emote.NICE])
	await _wait(Player.EMOTE_TIME + SETTLE)
	print("HOST: 時間切れ後 sync_emote=%d（期待 0）" % me.sync_emote)
	# クールダウンが明けるのを待って2回目。同じ値をもう一度出す
	await _wait(Player.EMOTE_COOLDOWN)
	await _press_emote()
	print("HOST: 2回目 sync_emote=%d" % me.sync_emote)
	# ホストが先に落ちるとクライアント側は world ごと切断処理で消えるので、
	# クライアントの観測窓（_run_client の limit）より長く生かしておく
	await _wait(Player.EMOTE_TIME + SETTLE + 6.0)


## ホストのプレイヤーは自分にとって非権威。そこへ届いた sync_emote を覗く
func _run_client(world: Node) -> void:
	var players: Node = world.get_node("Players")
	var remote: Node3D = null
	var waited := 0.0
	while remote == null and waited < 20.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
		remote = players.get_node_or_null("1")
	if remote == null:
		print("CLIENT: FAIL ホストのプレイヤーが出てこない")
		return

	# 立ち上がり・0 への復帰・2回目の立ち上がりを、順に取りこぼさず数える
	var bursts := 0
	var seen: Array[int] = []
	var prev: int = remote.sync_emote
	var cleared_after_first := false
	var t := 0.0
	var limit := Player.EMOTE_TIME * 2.0 + Player.EMOTE_COOLDOWN + 6.0
	while t < limit:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		if not is_instance_valid(remote):
			break  # ホストが先に落ちた（切断でシーンごと消える）
		var now: int = remote.sync_emote
		if now == prev:
			continue
		if now != Player.Emote.NONE:
			bursts += 1
			seen.append(now)
		elif bursts == 1:
			cleared_after_first = true
		prev = now

	print("CLIENT: 受信したエモート %s（立ち上がり %d 回）" % [seen, bursts])
	print("CLIENT: 1回目が自動で消えた: %s" % cleared_after_first)
	# 2回目が届かない = 同じ値を続けて書いて ON_CHANGE が発火しなかった状態
	var ok := bursts == 2 and cleared_after_first and seen.all(
		func(e: int) -> bool: return e == Player.Emote.NICE)
	print("CLIENT: %s" % ("OK" if ok else "FAIL エモートが正しく同期されていない"))


func _wait_peer() -> bool:
	var waited := 0.0
	while multiplayer.get_peers().is_empty() and waited < 20.0:
		await get_tree().physics_frame
		waited += get_physics_process_delta_time()
	return not multiplayer.get_peers().is_empty()


## _unhandled_input を通す必要があるので、押して離すまでを数フレームかける
func _press_emote() -> void:
	Input.action_press("emote")
	await _wait(0.1)
	Input.action_release("emote")
	await _wait(SETTLE)


func _wait(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
