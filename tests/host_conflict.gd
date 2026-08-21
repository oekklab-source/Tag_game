extends Node

## 既にポート 9999 が使われているときに、ホストを始めようとしたらどうなるか。
##
##   godot --headless --path . res://tests/host_conflict.tscn --quit-after 600
##
## 前に起動した Godot が残っているとこれが起きる。以前は world.tscn へ移ってから
## 失敗し、画面はゲームなのに誰ともつながらない状態になっていた。しかも配った
## 参加リンクは生き残った古いホストへつながるので、参加者だけ進まない・
## こちらの操作が届かないという極めて分かりにくい症状になっていた。

func _ready() -> void:
	await get_tree().process_frame
	# 別プロセスの居座りを再現する
	var squatter := TCPServer.new()
	var err := squatter.listen(NetworkManager.PORT)
	if err != OK:
		print("FAIL: テストの準備に失敗（ポート %d を掴めない）" % NetworkManager.PORT)
		get_tree().quit()
		return

	var started: bool = NetworkManager.start_host()
	print("--- ポートが埋まっている状態で HOST ---")
	print("  始まってしまった: %s  %s" % [started, "FAIL" if started else "OK（弾けている）"])
	print("  理由: %s" % NetworkManager.last_error.replace("\n", " / "))
	print("  %s" % ("OK（理由が出ている）" if not NetworkManager.last_error.is_empty()
		else "FAIL（何も知らせていない）"))
	print("  シーン: %s  %s" % [get_tree().current_scene.name,
		"OK（移っていない）" if get_tree().current_scene.name != "World"
		else "FAIL（壊れたワールドへ入ってしまった）"])

	# 空いていれば始められることも見る。change_scene でこのノードは解放されるので、
	# quit() は先に予約しておく
	squatter.stop()
	NetworkManager.last_error = ""
	var tree := get_tree()
	print("--- ポートを空けてから HOST ---")
	print("  始まった: %s  %s" % [NetworkManager.start_host(),
		"OK" if NetworkManager.mode == NetworkManager.Mode.HOST else "FAIL"])
	tree.quit()
