class_name WebScreen
extends RefCounted

## ブラウザ(Web版)の画面まわりのヘルパー。static 関数だけ。
##
## JS 側の実体は export_presets.cfg の html/head_include に書いた window.tag* 関数
## (tagToggleFullscreen / tagSafeArea / tagJoinPaste)。Godot からは呼ぶだけにして、
## 「タップの直後でないと許可されない」ブラウザ API はなるべく JS 側で完結させる。
##
## Web 以外(PC版・headless テスト)では何もせず false やゼロを返すので、
## 呼び出し側で OS.has_feature("web") を毎回書かなくてよい。
##
## [iPhone について]
## iPhone の Safari(と同じ WebKit を使う iPhone の全ブラウザ)は、動画以外の要素を
## 全画面にする Fullscreen API を持たない(2026-09 時点。document.fullscreenEnabled が false)。
## 代わりに「ホーム画面に追加」したアイコンから起動すると、manifest の display:fullscreen で
## アドレスバー無しになる。is_standalone() はその起動のされ方を見分ける。


static func is_web() -> bool:
	return OS.has_feature("web")


static func _eval(js: String) -> Variant:
	if not is_web():
		return null
	return JavaScriptBridge.eval(js, true)


## Fullscreen API が使えるか(Android Chrome・iPad・PCブラウザ=true、iPhone=false)
static func fullscreen_enabled() -> bool:
	return _eval("!!document.fullscreenEnabled") == true


static func is_fullscreen() -> bool:
	return _eval("!!document.fullscreenElement") == true


## ホーム画面に追加したアイコンから起動されたか。
## navigator.standalone は iOS 独自、display-mode は manifest を解釈するブラウザ共通
static func is_standalone() -> bool:
	return _eval(
		"navigator.standalone === true"
		+ " || matchMedia('(display-mode: fullscreen)').matches"
		+ " || matchMedia('(display-mode: standalone)').matches") == true


## 全画面の入/切。横向きへの固定も JS 側で行う(tagToggleFullscreen)。
## Chrome はタップ直後(ユーザー操作の数秒以内)でないと全画面を許可しないので、
## ボタンの pressed(=指を離した瞬間)から直接呼ぶこと
static func toggle_fullscreen() -> void:
	_eval("window.tagToggleFullscreen && window.tagToggleFullscreen()")


## ノッチ・角の丸み・ホームバーを避ける余白(CSS px = dp)。
## iPhone を横持ちすると左右に約 50dp 入る。Web 以外・JS が無いときはすべて 0
static func safe_area_insets_dp() -> Dictionary:
	var zero := {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	var raw: Variant = _eval("window.tagSafeArea ? window.tagSafeArea() : ''")
	if typeof(raw) != TYPE_STRING or (raw as String).is_empty():
		return zero
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return zero
	var out := {}
	for k in zero:
		out[k] = maxf(float((parsed as Dictionary).get(k, 0.0)), 0.0)
	return out


## タイトル画面の「招待リンクを貼り付けて参加」ボタン(HTML のボタン)の表示切り替え。
## Godot の中のボタンにしないのは、Godot の入力処理は次のフレームになり、iPhone が
## クリップボードの読み取りに求める「タップの直後」を満たせないため。
## 文言は tr() 済みのものを渡す(翻訳を locale/en.po に一本化するため)
static func set_join_paste_button(show: bool, label := "", prompt_text := "") -> void:
	_eval("window.tagJoinPaste && window.tagJoinPaste(%s, %s, %s)" % [
		"true" if show else "false", JSON.stringify(label), JSON.stringify(prompt_text)])


## dp -> 画面の座標単位(1920x1080 基準の canvas 単位)の換算係数。
## screen_scale は devicePixelRatio(Web)、visible_size は get_viewport().get_visible_rect().size、
## window_size は get_window().size(物理ピクセル)。
## visible_size には文字サイズ設定(L-10)の content_scale_factor も入っているので、
## 文字サイズを変えてもタッチボタンの実寸は変わらない。
## 画面の高さが min_height_dp に満たない端末では、全体をその高さに収まるよう縮める
static func units_per_dp(screen_scale: float, visible_size: Vector2, window_size: Vector2i,
		min_height_dp := 340.0) -> float:
	if window_size.x <= 0 or window_size.y <= 0 or visible_size.y <= 0.0:
		return 1.0
	var k := maxf(screen_scale, 0.01) * visible_size.x / float(window_size.x)
	return minf(k, visible_size.y / min_height_dp)


## アンカーで画面の端に付いている Control の offset を、safe area の分だけ内側へずらした値を返す。
## アンカー 0 の辺は左(上)の余白を、アンカー 1 の辺は右(下)の余白を受け、
## 中央アンカー(0.5)は両方の中間になる。insets は画面の座標単位。
static func inset_offsets(anchors: Rect2, offsets: Rect2, insets: Dictionary) -> Rect2:
	# Rect2 を「left, top, right, bottom」の4値入れとして使う(position=左上, size=右下)
	var l: float = insets.get("left", 0.0)
	var t: float = insets.get("top", 0.0)
	var r: float = insets.get("right", 0.0)
	var b: float = insets.get("bottom", 0.0)
	return Rect2(
		offsets.position.x + l * (1.0 - anchors.position.x) - r * anchors.position.x,
		offsets.position.y + t * (1.0 - anchors.position.y) - b * anchors.position.y,
		offsets.size.x + l * (1.0 - anchors.size.x) - r * anchors.size.x,
		offsets.size.y + t * (1.0 - anchors.size.y) - b * anchors.size.y)
