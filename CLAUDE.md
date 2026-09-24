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
godot --headless --path . res://tests/<name>.tscn --quit-after 600
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
- **`tests/test_phase5_persistence.tscn` は開発機の実セーブ（`user://profile.json` /
  `user://settings.json`）を書き換える。** 2026-09-25 の Phase 3 L-12 で
  テスト自身に退避・復元（`_backup_saves()` / `_restore_saves()`）を入れたので
  そのまま流してよいが、このテストに手を入れるときは**必ず退避・復元を壊していないか
  確認する**こと（過去、実行のたびに名前・レート・ジェムが破壊されていた）。
- **Godotの終了コードは信用しないこと。** Godot 4.7.2(win64) の headless は
  `get_tree().quit(code)` に何を渡してもプロセスの終了コードが常に `-1` になる
  （実測確認済み）。`tools/run_headless_test.ps1` は終了コードではなく標準出力の
  失敗マーカー（`[FAIL]` / `SOME TESTS FAILED` / `N FAILED` / `FAIL=1以上`）を走査して
  exit 1 を返す。新しいテストを書くときは、この3系統のいずれかの書式で
  失敗を出力すること（`_assert()` ヘルパを踏襲するのが最も確実）。

## RPC を変更するときの鉄則

RPC のメソッド名・シグネチャ・**ノードパス**を変えると旧クライアントと通信できなくなる。
変えたら `autoload/game/version_gate.gd` の `PROTOCOL_VERSION` を必ず上げ、
README の「マルチプレイの権威モデル」節と整合させる。
