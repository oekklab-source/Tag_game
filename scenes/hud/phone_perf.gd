class_name PhonePerf
extends RefCounted

## スマホ(Web版をスマホのブラウザで開いたとき)だけ描画と処理を軽くするヘルパー。static 関数だけ。
##
## 2026-10-05: iPhone 15 Pro Max で遊ぶと本体が熱くなるとの報告を受けて追加した。
## project.godot は描画設定を何も上書きしていないので、Web 版はエンジン既定のまま動いていた:
## - hiDPI が有効なので、3D を端末の実ピクセルで描く(iPhone 15 Pro Max の横持ちで約 2796x1290)
## - フレームレートの上限が無い
## - グロー・2分割の影(4096・縁はソフト)
## Godot 自身の「スマホ向けの既定値」(project.godot の .mobile 上書き)は、ネイティブの
## Android/iOS 書き出しにしか効かず、ブラウザで開いたスマホには効かない。そのためここで実行時に入れる。
##
## **PC 版(exe・PC のブラウザ)には一切効かない。** 軽量化はすべて enabled() が true のときだけ行い、
## 呼び出し側も enabled() で分岐する。PC で困っていないので、PC の見た目と挙動は変えない方針
## (WebScreen と同じく、Web 以外では何もしない)。
##
## スマホはホストになれない(ブラウザでは TCPServer で待ち受けられない。network_manager.gd の
## start_host)ので、CPU AI・視界判定・ナビは元からスマホでは動いていない。
## 重いのは描画で、次がその順に効く: 3D の解像度 > フレームレート > グロー > 影の解像度。

## 3D を描く縦の画素数の目安(画面の短い辺)。UI は別に実解像度で描くので、文字はぼやけない
const TARGET_3D_HEIGHT := 720.0
## これより下げると、遠くの逃走者が数画素の染みになって見分けにくくなる
const MIN_SCALE := 0.5
## 物理の刻み(60Hz)は変えない。物理 delta が全ピアで固定値であることが、動く床の位相が
## ずれない前提になっている(README「マルチプレイの権威モデル」)。描画だけを間引く
const FPS_CAP := 30
## Godot がネイティブのスマホ書き出しで使う既定値(.mobile)に揃える
const SHADOW_ATLAS_SIZE := 2048

## PC からスマホ用の軽量化を確かめるための強制スイッチ
## (`godot --path . res://scenes/world.tscn -- --phone-perf`)。テストは force_for_test を使う
const CMDLINE_FLAG := "--phone-perf"

static var force_for_test := false
static var _cached := -1  # -1=未判定, 0=false, 1=true


## スマホのブラウザで動いているか。
## 機種は Godot の機能タグ web_ios / web_android で見る(navigator.userAgent の部分一致)。
## iPadOS の Safari は既定で Mac の UA を名乗るので web_ios にならない。Mac にタッチ画面は
## 無いので、「Mac を名乗っていてタッチ画面がある」を iPad とみなす
static func enabled() -> bool:
	if force_for_test:
		return true
	if _cached < 0:
		_cached = 1 if _detect() else 0
	return _cached == 1


static func _detect() -> bool:
	if CMDLINE_FLAG in OS.get_cmdline_user_args():
		return true
	if not OS.has_feature("web"):
		return false
	if OS.has_feature("web_ios") or OS.has_feature("web_android"):
		return true
	return OS.has_feature("web_macos") and DisplayServer.is_touchscreen_available()


## 3D の描画倍率。画面の短い辺が TARGET_3D_HEIGHT になるように縮め、拡大はしない(純関数)
static func scale_3d_for(short_side_px: int) -> float:
	if short_side_px <= 0:
		return 1.0
	return clampf(TARGET_3D_HEIGHT / float(short_side_px), MIN_SCALE, 1.0)


## アプリ全体の設定(起動時に1回、SettingsManager._ready から)
static func apply_global() -> void:
	if not enabled():
		return
	Engine.max_fps = FPS_CAP


## 対戦画面の描画を軽くする(world.gd の _ready から)。適用したら true を返す。
## 影は消さない。長い影が距離感の手がかりになっているため(README「ブラウザでの確認」)。
## 解像度と縁のぼかしだけを、Godot のスマホ向け既定値まで落とす
static func apply_world(world_env: WorldEnvironment, vp: Viewport) -> bool:
	if not enabled():
		return false
	# world.tscn の sub_resource を直接書き換えず、複製して差し替える
	# (同じリソースを読む別のシーンやテストへ書き換えが漏れないように)
	var env := world_env.environment.duplicate() as Environment
	# README の「Web で重い場合は glow を最初に切る」。ネオン材のにじみは消えるが、色と明るさは残る
	env.glow_enabled = false
	world_env.environment = env
	RenderingServer.directional_shadow_atlas_set_size(SHADOW_ATLAS_SIZE, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(
		RenderingServer.SHADOW_QUALITY_HARD)
	apply_3d_scale(vp)
	return true


## 画面の大きさに合わせて 3D の描画倍率を設定する。画面を回したときにも呼ぶ(world.gd)
static func apply_3d_scale(vp: Viewport) -> void:
	if not enabled():
		return
	# 物理ピクセルで測る。get_visible_rect() は stretch(canvas_items) 後の 1920x1080 基準なので使えない
	var size := (vp as Window).size if vp is Window else Vector2i.ZERO
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = scale_3d_for(mini(size.x, size.y))
