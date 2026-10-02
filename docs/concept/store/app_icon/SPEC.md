# アプリアイコン 制作仕様書

## 概要
`project.godot`の`config/icon`(エディタ・Web版ファビコン)、および Windows exe の
アイコンとして使うアプリアイコン。現行の[icon.svg](../../../icon.svg)は128x128の
単純なプレースホルダー図形(297バイト)で、本格制作の対象。

## 規格
- (a) 1024x1024 PNG または SVG(元絵)
- (b) Windows用`icon.ico`(256/128/64/48/32/16の多重サイズを内包)

## 適用経路(実測済み、`export_presets.cfg`セッションの結果を前提)
`export_presets.cfg`の`[preset.1.options]`(Windows Desktop)は
`application/modify_resources=true`にした上で`application/icon`が空欄のままなので、
現状は`project.godot`の`config/icon`(`res://icon.svg`)にフォールバックしている。
本格的なアイコンを適用する本筋は、`res://icon.ico`を新規に置いて
`project.godot`に`config/windows_native_icon="res://icon.ico"`を追加する経路
(`export_presets.cfg`の`application/icon`を使う手もあるが、いずれも
`modify_resources=true`でないと反映されない点は共通)。

## 視認性の要件
**16x16に縮小したときにシルエットで判別できること。** 現行アイコンの実際の問題点は、
「緑丸・赤丸・横棒」という構成が小さく縮小すると潰れて見分けがつかなくなること。
新規制作では、タスクバー・ファイルエクスプローラーの小アイコン表示を想定して
16x16での視認性を検証すること。

## 配色(正本)
[cover_image/SPEC.md](../cover_image/SPEC.md)と同じ配色正本を踏襲する:
背景`#2b3a67`(紺)、逃走者`#4ade80`(緑)、鬼`#ef4444`(赤)、連結線`#ffffff`(白)。

## 出力先とレビューゲート
生成物は`docs/concept/store/app_icon/`配下に置く。`REVIEW.md`でPASSと判定されるまで、
Claude Codeは`res://icon.ico`への組み込み・`project.godot`の変更を行わない。
