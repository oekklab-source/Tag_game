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

    タイムアウトで強制終了した場合は、シーンロード失敗・awaitのハング等
    「何かがおかしい」サインとして exit code 124 を返す。
    テスト出力に失敗マーカーが見つかった場合は exit code 1 を返す。

.PARAMETER ScenePath
    実行する res://tests/<name>.tscn のパス（例: res://tests/net_roles.tscn）。

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
    pwsh tools/run_headless_test.ps1 res://tests/net_roles.tscn -TimeoutSec 60
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

    # このリポジトリのテストが使っている失敗マーカー。書式は3系統あり、
    # どれも「失敗した時だけ」出る(成功時は [OK] / ALL OK / ALL PASSED):
    #   [FAIL]            … _assert() 系ヘルパ(test_phase*.gd 等19ファイル)
    #   SOME TESTS FAILED … 同系統の末尾サマリ
    #   「N FAILED」/「: FAILED」… failures カウンタ系
    #                       (player_facing / player_look / respawn_penalty /
    #                        slide_gameplay / perimeter_rim)
    #   FAIL=<1以上>      … PASS=%d, FAIL=%d のサマリ行(FAIL=0 は成功なので除外)
    # SCRIPT ERROR は意図的に含めていない。tests/debug_controls.tscn に
    # 既存の未修正エラーがあり、無関係なテストを巻き込んで赤くするため。
    $failPattern = '\[FAIL\]|SOME TESTS FAILED|FAIL=[1-9]|[1-9][0-9]* FAILED|: FAILED'
    $combined = "$outText`n$errText"
    if ($combined -match $failPattern) {
        Write-Host "=> 失敗マーカーを検出したため exit 1 を返す (検出: '$($Matches[0])')" -ForegroundColor Red
        exit 1
    }

    # ここまで来れば「タイムアウトせず、失敗マーカーも無い」。
    # $proc.ExitCode は上記3.の理由で参照しない
    exit 0
}
finally {
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
}
