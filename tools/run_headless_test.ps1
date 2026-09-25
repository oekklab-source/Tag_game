<#
.SYNOPSIS
    Godotシーンをheadlessで実行し、必ずタイムアウトで強制終了する安全なラッパー。

.DESCRIPTION
    tests/*.tscn を --headless で流すときに何度も踏んでいる、2つの既知の罠を
    機械的に防ぐ:

      1. --quit-after は「--」より前（エンジン側オプション）に置かないと
         OS.get_cmdline_user_args() 側のユーザー引数として渡ってしまい、
         エンジンには一切効かない。このスクリプトは常に正しい位置に組み立てるので、
         呼び出し側がこの順序を意識する必要が無い。
      2. RenderingServer.frame_post_draw を待つ一時スクリプト等は headless では
         永久に発火せず、1.の罠と重なるとプロセスが際限なく生き続ける。
         このスクリプトは Godot自身の終了（--quit-after）に頼らず、
         Start-Process + WaitForExit(timeout) で OS レベルの安全網を必ず掛ける。
         強制終了する対象は Start-Process -PassThru で取得した「自分が起動した
         子プロセスのPID」のみで、CPU使用量等の状況証拠で無関係なプロセスを
         巻き込むことは無い。

      3. Godot 4.7.2(win64)の headless は get_tree().quit(code) を呼んでも
         プロセスの終了コードが常に -1 になり、テストの成否を一切伝えない
         (quit(0)/quit(3)/quit(7) のいずれでも -1 になることを実測で確認済み。
         Phase 3 L-12)。そのためこのスクリプトは終了コードを信用せず、
         テストの標準出力に出る失敗マーカー([FAIL] / SOME TESTS FAILED /
         「N FAILED」/ FAIL=1以上)を走査して成否を判定する。
         SCRIPT ERROR も失敗扱い(途中で中断したテストの偽PASSを防ぐため)。

    タイムアウトで強制終了した場合は、シーンロード失敗・awaitのハング等
    「何かがおかしい」サインとして exit code 124 を返す。
    テスト出力に失敗マーカーが見つかった場合は exit code 1 を返す。

.PARAMETER ScenePath
    実行する res://tests/<name>.tscn のパス（例: res://tests/debug_controls.tscn）。
    1プロセスで完結するテスト専用。net_roles / net_anim / net_live 等の
    ホスト+クライアント2プロセスが要るテストは、このラッパー単体では
    必ず「相手がつながらなかった」で失敗する（過去にこれを既存の不具合と誤認した）。
    それらは各テストのヘッダにある手順で2つ起動すること。

.PARAMETER GodotExe
    Godotエディタ実行ファイルのフルパス。既定値は $DefaultGodotExe。
    自分の環境のパスと違う場合は -GodotExe で指定するか、この既定値を書き換える。

.PARAMETER TimeoutSec
    このタイムアウト（壁時計秒）を過ぎたら強制終了する（既定 90 秒）。
    通常のテストは数秒〜十数秒で終わる想定。長時間かかるテストは明示的に広げること。

.PARAMETER GodotArgs
    Godotエンジンへ渡す追加の引数（--quit-after以外）。文字列配列で渡す。

.EXAMPLE
    pwsh tools/run_headless_test.ps1 res://tests/test_phase5_persistence.tscn
.EXAMPLE
    pwsh tools/run_headless_test.ps1 res://tests/test_phase7_stability.tscn -TimeoutSec 180
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScenePath,
    [string]$GodotExe,
    [int]$TimeoutSec = 90,
    [string[]]$GodotArgs = @()
)

# この開発機でのデフォルトパス。他の環境では -GodotExe で上書きするか、ここを書き換える
$DefaultGodotExe = 'C:\dev\godot47\Godot_v4.7.2-stable_win64.exe'

$ErrorActionPreference = 'Stop'

if (-not $GodotExe) { $GodotExe = $DefaultGodotExe }
if (-not (Test-Path $GodotExe)) {
    Write-Error "Godot実行ファイルが見つからない: $GodotExe (-GodotExe で指定するか `$DefaultGodotExe を書き換えること)"
}

$repoRoot = Split-Path -Parent $PSScriptRoot

# --quit-after は必ず「--」より前（エンジンオプション側）に置く。
# ここより後ろに置くとエンジンには一切効かない（本文.DESCRIPTION参照、既知の罠）。
# 600フレームは大半のheadlessテストが数秒で終わる前提での余裕値で、
# 実際にプロセスを止めるのは基本的に下のWaitForExitタイムアウトの役目
$allArgs = @('--headless', '--path', $repoRoot, $ScenePath, '--quit-after', '600') + $GodotArgs

Write-Host "実行: $GodotExe $($allArgs -join ' ')" -ForegroundColor Cyan
Write-Host "(タイムアウト ${TimeoutSec}秒。ハングした場合は自動的に強制終了する)" -ForegroundColor DarkGray

$outFile = New-TemporaryFile
$errFile = New-TemporaryFile
try {
    $proc = Start-Process -FilePath $GodotExe -ArgumentList $allArgs `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $finished = $proc.WaitForExit($TimeoutSec * 1000)

    if (-not $finished) {
        Write-Warning "タイムアウト(${TimeoutSec}秒)。プロセス(PID $($proc.Id))をハングとみなし強制終了する。"
        Write-Warning "(シーンロード失敗、またはawaitが永久に解決しない一時スクリプト等が疑わしい)"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }

    $outText = Get-Content $outFile -Raw
    $errText = Get-Content $errFile -Raw

    if ($outText) { Write-Host $outText }
    if ($errText) { Write-Host $errText -ForegroundColor DarkYellow }

    if (-not $finished) {
        exit 124
    }

    # tests/*.gd の失敗出力は書式が統一されていない。実際に使われているものだけでも
    #   [FAIL] %s / FAIL: %s / FAIL（%s） / FAIL ホスト… / N FAILED /
    #   SOME TESTS FAILED / PASS=%d, FAIL=%d
    # と5系統以上ある。個別に列挙すると必ず取りこぼす(実際、最初の実装は
    # tests/quit_menu.gd の「ラベル: FAIL」形式を拾えていなかった)ので、
    # 「大文字の FAIL が出力に現れたら失敗」という単純な規則にする。
    #
    # 唯一の例外が成功時にも必ず出る "FAIL=0"(PASS=%d, FAIL=%d のサマリ行)なので、
    # 走査の前にそこだけ取り除く。
    #
    # -cmatch(大文字小文字を区別)である点が重要。エンジンが出す
    # "Failed to load script" 等の混在表記まで拾うと、無関係な警告で赤くなる。
    #
    # SCRIPT ERROR も失敗扱いにする。GDScript は実行時エラーでその関数を中断するので、
    # テストが結果行(FAIL を含む)を出す前に止まると「FAIL が無い＝成功」と誤判定される。
    # 実際 tests/debug_controls.tscn は消えた定数 NetworkManager.MAIN_SCENE を参照して
    # 最終判定の手前で止まり、長期間偽PASSしていた。当初はこのエラーが既存の未修正
    # 不具合だったために判定から外していたが、2026-09-25 に修正し、headless 対応の
    # 全テストで SCRIPT ERROR が0件になったことを確認したうえで判定に加えた。
    $scan = ("$outText`n$errText") -replace 'FAIL=0', ''
    if ($scan -cmatch 'FAIL') {
        Write-Host "=> 出力に FAIL があるため exit 1 を返す" -ForegroundColor Red
        exit 1
    }
    if ($scan -cmatch 'SCRIPT ERROR') {
        Write-Host "=> 出力に SCRIPT ERROR があるため exit 1 を返す(テストが途中で中断した可能性)" -ForegroundColor Red
        exit 1
    }

    # ここまで来れば「タイムアウトせず、失敗マーカーも無い」。
    # $proc.ExitCode は上記3.の理由で参照しない
    exit 0
}
finally {
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
}
