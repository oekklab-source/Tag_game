# 3D Chase Game（Godot 4 / WebSocket オンライン鬼ごっこ MVP）

PC がホスト（WebSocket サーバ）、Web ブラウザがクライアントとして参加する
3D 三人称視点のオンライン・チェイスゲームのプロトタイプ。

## ルール

- ラウンド開始時に全員から **Runner（逃げ）1人** をランダム選出。残り全員が **Hunter（鬼）**
- 開始直後は **20秒のヘッドスタート**: 鬼（人間・CPU とも）は動けず、Runner だけ逃げられる
- ヘッドスタート後 **3分間** 逃げ切れば Runner の勝ち。Hunter が **1.5m 以内** に近づくとタッチ成立で Hunter の勝ち
- **索敵情報の非対称**:
  - Hunter は「Runner がいる **色エリア名**」だけ分かる（方向・距離・マーカーは無し）
  - Runner は **全体の2Dマップ**（右上）で鬼全員の位置が見え、最寄りの鬼への**赤矢印＋距離**も表示される
- 鬼の人数による速度補正: 鬼1人 = **100%** / 2人 = **90%** / 3人以上 = **80%**
- 結果表示の5秒後、役割を再抽選して自動で次ラウンド開始
- **ソロモード**: ホスト1人だけで Enter を押すと自分が Runner になり、**CPU の鬼が3人**出現する。
  CPU はナビメッシュで経路追跡し、壁・段差・スロープでは**ジャンプして登り**、
  ジャンプしないと届かない場所（1m のジャンプ台の上など）にいる Runner も捕まえに来る

## マップ

60×60m。エリアごとに **地面の標高自体が異なる段丘構造** で、色分けされている:

| エリア | 色 | 地面の高さ | 特徴 |
| --- | --- | --- | --- |
| 中央 | 灰 | 0m | ハブ。各エリアへのスロープが集まる |
| 東 | 赤 | 1m | 大型ブロック・裏路地・ジャンプ台 |
| 西 | 青 | 3m | 最も高い台地（中央から大スロープで接続） |
| 南 | 緑 | 0m | 迷路状の壁と高さ2.5mの物見台 |
| 北 | 黄 | 2m | 高台の上にさらにタワー（頂上4m）とジグザグ壁 |

1m の段差はジャンプで直接登れる（CPU も跳んで追ってくる）。2m 以上はスロープ経由。

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
| [scenes/cpu_hunter.gd](scenes/cpu_hunter.gd) | CPU の速度・ジャンプ頻度・直接追跡に切り替える距離 |
| [autoload/game_manager.gd](autoload/game_manager.gd) | タッチ距離・制限時間・ヘッドスタート秒数・CPU数・速度補正 |
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
autoload/game_manager.gd     役割抽選・速度補正・タイマー・ヘッドスタート・タッチ判定・ソロモード
scenes/main.tscn(.gd)        ロビー（HOST / JOIN）
scenes/world.tscn(.gd)       段丘マップ（4色ゾーン）・ナビメッシュ・スポーン管理
scenes/player.tscn(.gd)      移動・ダッシュ・TPSカメラ・位置同期
scenes/cpu_hunter.tscn(.gd)  CPU 鬼（NavigationAgent3D 追跡 + ジャンプ + 近距離直接追跡）
scenes/humanoid.tscn(.gd)    人型モデル（KayKit Knight, CC0）とアニメーション制御
scenes/hud.tscn(.gd)         スタミナ・タイマー・ゾーン表示・2Dマップ・結果表示
assets/kaykit/               Knight.glb（KayKit Adventurers, CC0ライセンス同梱）
```

キャラクターモデルは [KayKit Adventurers](https://kaylousberg.itch.io/kaykit-adventurers)
の Knight（CC0）。Idle / Walking_A / Running_A / Jump_Idle を速度に応じて再生する。
※ もしキャラが進行方向と逆を向いて走る場合は `humanoid.tscn` の Model ノードの
`rotation.y`（180°）を 0 にする。
