extends Node

## Player Data Storage(クラウドセーブ)用の高レベルラッパー。
## このアドオン(epic-online-services-godot 2.3.0)にはhleaderboards.gd等と異なり
## PlayerDataStorage用のH*ラッパーがバンドルされていないため、Phase 4で手動追加した
## 非公式ファイル(アドオン本体のアップデートで同名ファイルが追加された場合は要確認)。

#region Signals

#endregion


#region Public vars

#endregion


#region Private vars

var _log = HLog.logger("HPlayerDataStorage")

const DEFAULT_CHUNK_BYTES := 4096

## PDS転送(write/read/query)の同時実行を防ぐロック。EOS Player Data Storageは
## 同一ファイルへの転送を同時に1件しか受け付けないため(AlreadyPendingで失敗する)、
## このプロジェクトが扱うファイルは1つ(profile.json)なのでファイル名非依存の
## グローバルロックで十分。
var _pds_busy := false
signal _pds_lock_released

#endregion


#region Built-in methods

func _ready() -> void:
	pass

#endregion


#region Public methods

## 指定ファイルをEOS Player Data Storageへ書き込む。成功したらtrue。
## WriteFileOptions.dataに全バッファを渡す方式で、write_file_data_callback
## (チャンク要求)への応答はネイティブ側が自動処理する前提。この前提が誤りだった
## 場合はwrite_file_callbackの待機がタイムアウトする形で顕在化するはず。
## PDS転送ロックで直列化される(実機検証で判明したAlreadyPending競合対策)。
func write_file_async(filename: String, data: PackedByteArray) -> bool:
	await _pds_acquire()
	var result := await _write_file_impl(filename, data)
	await _pds_release()
	return result


func _write_file_impl(filename: String, data: PackedByteArray) -> bool:
	_log.debug("Writing file: filename=%s size=%d" % [filename, data.size()])
	var opts = EOS.PlayerDataStorage.WriteFileOptions.new()
	opts.filename = filename
	opts.data = data
	opts.chunk_length_bytes = DEFAULT_CHUNK_BYTES

	var handle = EOS.PlayerDataStorage.PlayerDataStorageInterface.write_file(opts)
	if handle == null:
		_log.error("write_file() did not return a transfer handle: filename=%s" % filename)
		return false

	var ret = await IEOS.playerdatastorage_interface_write_file_callback
	if not EOS.is_success(ret):
		_log.error("Failed to write file: filename=%s result_code=%s" % [filename, EOS.result_str(ret)])
		return false

	_log.debug("Wrote file successfully: filename=%s" % filename)
	return true


## 指定ファイルをEOS Player Data Storageから読み込む。未存在/失敗時は空のPackedByteArray。
## read_file_data_callbackはチャンク単位で複数回発火しうるため、一時接続でバッファへ
## 蓄積し、完了シグナル(read_file_callback)到着後に切断する。
## PDS転送ロックで直列化される(実機検証で判明したAlreadyPending競合対策)。
func read_file_async(filename: String) -> PackedByteArray:
	await _pds_acquire()
	var result := await _read_file_impl(filename)
	await _pds_release()
	return result


func _read_file_impl(filename: String) -> PackedByteArray:
	_log.debug("Reading file: filename=%s" % filename)
	var buffer := PackedByteArray()

	var opts = EOS.PlayerDataStorage.ReadFileOptions.new()
	opts.filename = filename
	opts.read_chunk_length_bytes = DEFAULT_CHUNK_BYTES

	var handle = EOS.PlayerDataStorage.PlayerDataStorageInterface.read_file(opts)
	if handle == null:
		_log.error("read_file() did not return a transfer handle: filename=%s" % filename)
		return buffer

	var on_data_chunk := func(chunk_info: Dictionary) -> void:
		if chunk_info.get("filename", filename) != filename:
			return  # 他ファイルの並行転送分は無視(念のための防御)
		var chunk: PackedByteArray = chunk_info.get("data_chunk", PackedByteArray())
		buffer.append_array(chunk)

	IEOS.playerdatastorage_interface_read_file_data_callback.connect(on_data_chunk)
	var ret = await IEOS.playerdatastorage_interface_read_file_callback
	IEOS.playerdatastorage_interface_read_file_data_callback.disconnect(on_data_chunk)

	if not EOS.is_success(ret):
		if EOS.result_str(ret) != "NotFound":
			_log.error("Failed to read file: filename=%s result_code=%s" % [filename, EOS.result_str(ret)])
		return PackedByteArray()

	_log.debug("Read file successfully: filename=%s size=%d" % [filename, buffer.size()])
	return buffer


enum FileQueryStatus { FOUND, NOT_FOUND, ERROR }


## ファイルの存在有無をクエリし、見つかった/見つからない/クエリ自体が失敗した、を区別して返す。
## 呼び出し側が「未存在と確認できた場合」と「一時的な障害で確認できなかった場合」を
## 区別する必要がある場合(例: クラウドセーブの初回判定)はこちらを使うこと。
## PDS転送ロックで直列化される(実機検証で判明したAlreadyPending競合対策)。
func query_file_status_async(filename: String) -> FileQueryStatus:
	await _pds_acquire()
	var result: FileQueryStatus = await _query_file_status_impl(filename)
	await _pds_release()
	return result


func _query_file_status_impl(filename: String) -> FileQueryStatus:
	var opts = EOS.PlayerDataStorage.QueryFileOptions.new()
	opts.filename = filename
	EOS.PlayerDataStorage.PlayerDataStorageInterface.query_file(opts)

	var ret = await IEOS.playerdatastorage_interface_query_file_callback
	if EOS.is_success(ret):
		return FileQueryStatus.FOUND
	if EOS.result_str(ret) == "NotFound":
		return FileQueryStatus.NOT_FOUND
	_log.error("Failed to query file: filename=%s result_code=%s" % [filename, EOS.result_str(ret)])
	return FileQueryStatus.ERROR


## ファイルのメタデータをローカルキャッシュへ問い合わせる(copy_file_metadata_by_filenameの前提)。
func query_file_async(filename: String) -> bool:
	return await query_file_status_async(filename) == FileQueryStatus.FOUND


## ファイルの最終更新時刻(UNIX秒)。未存在/失敗時は0。
## copy_file_metadata_by_filenameは同期APIだが、事前にquery_file_asyncで
## ローカルキャッシュを更新しておく必要がある(EOS公式のQuery→Copyパターン)。
func get_file_timestamp_async(filename: String) -> int:
	if not await query_file_async(filename):
		return 0

	var opts = EOS.PlayerDataStorage.CopyFileMetadataByFilenameOptions.new()
	opts.filename = filename
	var ret: Dictionary = EOS.PlayerDataStorage.PlayerDataStorageInterface.copy_file_metadata_by_filename(opts)
	if not EOS.is_success(ret):
		if EOS.result_str(ret) != "NotFound":
			_log.error("Failed to copy file metadata: filename=%s result_code=%s" % [filename, EOS.result_str(ret)])
		return 0

	# copy_file_metadata_by_filenameはresult_codeと同階層ではなく
	# metadataキーの下にFileMetadataの中身(last_modified_time等)をネストして返す
	var metadata: Dictionary = ret.get("metadata", {})
	return int(metadata.get("last_modified_time", 0))

#endregion


#region Private methods

## PDS転送ロックを取得する(既に使用中ならawaitで空くまで待つ)。
func _pds_acquire() -> void:
	while _pds_busy:
		await _pds_lock_released
	_pds_busy = true


## PDS転送ロックを解放する。ネイティブSDK側のtransfer-handle解放が
## コールバック発火(=このawait chainの解決)よりわずかに遅れる可能性への
## 保険として、解放前に短い猶予を置く(実機検証でAlreadyPendingが確認済みのため)。
func _pds_release() -> void:
	await get_tree().create_timer(0.2).timeout
	_pds_busy = false
	_pds_lock_released.emit()

#endregion
