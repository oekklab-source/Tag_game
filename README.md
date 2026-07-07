# 3D Chase Game（Godot 4 / WebSocket オンライン鬼ごっこ MVP）

PC がホスト（WebSocket サーバ）、Web ブラウザがクライアントとして参加する
3D 三人称視点のオンライン・チェイスゲームのプロトタイプ。

## ルール

- ラウンド開始時に全員から **Runner（逃げ）1人** をランダム選出。残り全員が **Hunter（鬼）**
- **3分間** 逃げ切れば Runner の勝ち。Hunter が **1.5m 以内** に近づくとタッチ成立で Hunter の勝ち
- コンパス表示: **Hunter → Runner の方向（緑矢印）** / **Runner → 最寄りの鬼の方向（赤矢印）**、いずれも距離付き
- Hunter の画面にはさらに、壁越しに見える **光点マーカー** が Runner の頭上に表示される
- 鬼の人数による速度補正: 鬼1人 = **100%** / 2人 = **90%** / 3人以上 = **80%**
- 結果表示の5秒後、役割を再抽選して自動で次ラウンド開始
- **ソロモード**: ホスト1人だけで Enter を押すと自分が Runner になり、**CPU の鬼**（ナビメッシュ経路探索で追跡）が出現する

## マップ

60×60m。エリアは東西南北で色分けされている:

| エリア | 色 | 特徴 |
| --- | --- | --- |
| 東 | 赤 | 大型ブロックと裏路地 |
| 西 | 青 | 2段の高台（スロープで1.5m→3m） |
| 南 | 緑 | 迷路状の壁と高さ2.5mの物見台 |
| 北 | 黄 | 高さ3mのタワー（スロープ付き）とジグザグ壁 |

高低差とスロープはすべて CPU 鬼のナビメッシュでも通行可能。

## 操作

| 入力 | 動作 |
| --- | --- |
| W / A / S / D | 移動 |
| マウス | カメラ（クリックでキャプチャ、Esc で解放） |
| Shift（押しっぱなし） | ダッシュ（速度1.5倍、スタミナ消費） |
| Space | ジャンプ |
| Enter | ラウンド開始（**ホストのみ**。1人なら CPU 戦） |

## ローカルでの動作確認（PC のみ）

1. Godot 4.x エディタでこのフォルダの `project.godot` を開く
2. メニュー **デバッグ > 実行インスタンスをカスタマイズ** で複数インスタンス（2〜4）を有効化
3. F5 で実行し、1つのウィンドウで **HOST**、他は `127.0.0.1` のまま **JOIN**
4. ホスト画面で Enter を押すとラウンド開始

ソロモード（CPU 戦）は 1 インスタンスで **HOST → そのまま Enter** で開始できる。

## ブラウザ（Web エクスポート）での確認

1. **プロジェクト > エクスポート** で **Web** プリセットを追加
   （テンプレート未導入なら案内に従いダウンロード。**Thread Support はオフ**のまま = デフォルト）
2. `export/web/` などにエクスポートし、http で配信:
   ```
   python -m http.server 8000 --directory export/web
   ```
   ※ ページを **https で配信すると ws:// 接続がブロック**されるため、必ず http（localhost/LAN 内）で配信する
3. PC 側でゲームを起動（エディタ実行で可）し **HOST**
4. スマホ/別PCのブラウザで `http://<PCのIP>:8000` を開き、ホストの IP を入力して **JOIN**
5. つながらない場合は Windows ファイアウォールで **ポート 9999（TCP）** を許可する

## 調整用パラメータ

| 場所 | 定数 |
| --- | --- |
| [scenes/player.gd](scenes/player.gd) | 移動速度・ダッシュ倍率・スタミナ消費/回復・マウス感度 |
| [autoload/game_manager.gd](autoload/game_manager.gd) | タッチ距離・制限時間・結果表示時間・速度補正テーブル |
| [autoload/network_manager.gd](autoload/network_manager.gd) | ポート番号 |

## UI が英語表記な理由（日本語化する場合）

Godot 4 標準フォントに日本語グリフがなく、**Web エクスポートでは OS フォントへの
フォールバックも使えない**ため、ブラウザで日本語が「□（豆腐）」になる。日本語化するには:

1. [Noto Sans JP](https://fonts.google.com/noto/specimen/Noto+Sans+JP) の .ttf を `fonts/` に置く
2. プロジェクト設定 > GUI > テーマ > **Custom Font** に指定
3. 各 `.gd` / `.tscn` 内の UI 文字列を日本語に置換

## 構成

```
autoload/network_manager.gd  WebSocket 接続・切断・シーン遷移
autoload/game_manager.gd     役割抽選・速度補正・タイマー・タッチ判定・ソロモード（ホスト権威）
scenes/main.tscn(.gd)        ロビー（HOST / JOIN）
scenes/world.tscn(.gd)       マップ（4色ゾーン）・ナビメッシュ・スポーン管理
scenes/player.tscn(.gd)      移動・ダッシュ・TPSカメラ・位置同期
scenes/cpu_hunter.tscn(.gd)  ソロモード用 CPU 鬼（NavigationAgent3D で追跡）
scenes/humanoid.tscn(.gd)    ブロック調の人型モデル（プレイヤー/CPU共用、役割色を反映）
scenes/hud.tscn(.gd)         スタミナ・タイマー・コンパス・結果表示
```

キャラクターモデルはプリミティブ製の人型。差し替える場合は CC0 の glb
（Kenney / Quaternius など）を `humanoid.tscn` の各パーツと入れ替えればよい。
