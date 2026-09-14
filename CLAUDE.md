# Tag_Game

まず [README.md](README.md) を読むこと。特に `## 構成`（ファイル一覧と役割）と
`## マルチプレイの権威モデル`（改造時に守るべき前提）は、この2つを読まずにコードへ触ると
高確率で壊す。このリポジトリはコードコメントも実質の設計書なので、既存のコメントは削除せず、
「なぜそうなっているか（WHY）」が書かれているコメントは特に維持すること。

## テストの流し方

**推奨: `tools/run_headless_test.ps1` を使う**（下記の罠を機械的に回避し、ハング時は
OSレベルのタイムアウトで自動的に強制終了する。自分が起動した子プロセスのPIDのみを
対象にするため、無関係なプロセスを誤って巻き込むこともない）。

```powershell
pwsh tools/run_headless_test.ps1 res://tests/<name>.tscn
```

素の `godot` コマンドを直接使う場合は、以下の罠に注意すること:

```powershell
godot --headless --path . res://tests/<name>.tscn -- --quit-after 600
```

- 常駐プロセス名は `godot.exe` ではなく `Godot_v4.7.2-stable_win64.exe`。
- ヘッドレス実行の出力をパイプすると、90秒以上「空のまま生きている」ように見えることがある。
  すぐには殺さないこと。
- **`--quit-after` は `--` より前（エンジン側オプション）に置くこと。** `--`より後ろに
  置くと `OS.get_cmdline_user_args()` 側のユーザー引数として渡ってしまい、エンジンには
  一切効かない。これを間違えると、`RenderingServer.frame_post_draw` を待つような
  一時スクリプト（headlessでは永久に発火しない）と組み合わさってプロセスが
  際限なく生き続ける事故につながる（実際に複数回発生している）。
- シーンのロード自体が失敗すると `--quit-after` を付けていてもプロセスが終了せず、
  メインシーンにフォールバックして走り続けることがある。単体実行し、実行後は明示的に止めること。
- `tests/*.tscn` のうち `--headless` 不可なもの（PNG書き出し系: `uishot.tscn`,
  `screenshot.tscn`, `shot_stamina.tscn` 等）はエディタで実行する。

## RPC を変更するときの鉄則

RPC のメソッド名・シグネチャ・**ノードパス**を変えると旧クライアントと通信できなくなる。
変えたら `autoload/game/version_gate.gd` の `PROTOCOL_VERSION` を必ず上げ、
README の「マルチプレイの権威モデル」節と整合させる。
