# 公開用スクリーンショット 撮影・選定仕様

## 概要
itch.io掲載用のスクリーンショット。**生成物ではなく実機の撮影物**のため、
画像生成ツールへは委譲せずClaude Codeが既存の`tests/uishot.tscn`から自給する。

## 撮影手段
```
godot --path . res://tests/uishot.tscn -- --shots <出力先フォルダ>
```
**headless不可・windowed必須**(CLAUDE.mdの「テストの流し方」の但し書きどおり、
`_shot()`が`RenderingServer.frame_post_draw`を待つため)。

出力される9枚: title / lobby / lobby_picked / playing / emote / result /
ranking_dialog / room_match_dialog / migration_overlay
([tests/uishot.gd](../../../tests/uishot.gd)参照)。

## 枚数・選定案
itch.io推奨は3〜5枚。候補:

1. タイトル画面(`title.png`)
2. ロビー(`lobby.png` または `lobby_picked.png`、役割が決まっている見た目)
3. 鬼視点の追跡または逃走者視点(`playing.png`)
4. エモート(`emote.png`、連携要素が伝わる)
5. リザルト(`result.png`)

## 写り込みの禁止事項(公開前に必ず確認)
- 招待リンク行(`InviteRow`)に実トンネルURL(`?s=xxxx.trycloudflare.com`)が写っていないか
- 実プレイヤー名・EOSのID・フレンドコードが写っていないか
- `tests/uishot.gd`の標準実行では`NetworkManager.public_address`を設定しないため
  `lobby.png`に招待リンク行自体が出ない想定だが、撮影時に目視で再確認すること

## 出力・コミット手順
`tests/shots/`は`.gitignore`対象のため、公開用に選んだものだけを
`docs/concept/store/screenshots/`へコピーしてコミットする。

## 既知の制約
ホバー/フォーカス時の見た目は、合成マウス座標を使わない限り撮影できない
(過去の切断事故のため使わない方針、[[feedback_gui_automation_this_project]])。
ストア用スクリーンショットには静止状態の画で十分なため、この制約は問題にならない。
