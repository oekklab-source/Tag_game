<#
.SYNOPSIS
    tests/*.tscn の回帰テストをまとめて流し、結果を集計する（KAN-66）。

.DESCRIPTION
    tests/*.tscn は次の4種類が混ざっている。このスクリプトは 1 と 2 を流し、3 と 4 は
    「流さなかったもの」として一覧に出すだけにする。分類は下の $TwoProcess / $Windowed /
    $LiveEos に名前で書く。どれにも書いていないシーンは 1 として流す（新しく足したテストが
    黙って対象外になるのを防ぐため。headless で流せないものを足したら、ここに書き足すこと）。

      1. headless の1プロセスで完結するもの
         → tools/run_headless_test.ps1 を1本ずつ呼ぶ。成否はその終了コードで見る
           （0 = PASS / 1 = FAIL / 124 = TIMEOUT。Godot 自身の終了コードは信用できないが、
           run_headless_test.ps1 は出力の FAIL / SCRIPT ERROR で判定して自分の終了コードを返す）
      2. ホストとクライアントの2プロセスが要るもの（net_roles / net_anim / net_live / emote）
         → 各テストのヘッダどおり「-- host」と「-- client 127.0.0.1」を同時に起動し、
           2つの出力を合わせて run_headless_test.ps1 と同じ規則で判定する
           （単独で起動すると必ず「相手がつながらなかった」で失敗する。不具合ではない）
      3. ウィンドウ表示が要るもの（PNG 書き出し。headless では描画が来ず終わらない）
         → エディタか、ウィンドウ有りで手動実行する
      4. 実際の EOS につなぐもの（test_eos_live_*）
         → 実クレデンシャルと実バックエンドへの副作用があるので、ヘッダの手順で手動実行する

    各テストの出力は $LogDir に1本ずつ残す（既定は %TEMP%\tag_game_tests\<日時>）。
    最後に「run_all_tests 結果: PASS=… FAIL=… TIMEOUT=…」を出し、全部通れば exit 0、
    1本でも落ちれば exit 1 を返す。

    実セーブの保護: tests/*.gd は全部 tests/save_guard.gd で実セーブを退避・復元し、
    クラウドセーブ同期も止めている（CLAUDE.md「テストの流し方」）。2プロセス系は
    同じ user:// を2つのプロセスが同時に退避・復元するが、どちらも元のファイルを
    退避して書き戻すだけなので結果は変わらない。

.PARAMETER Filter
    流すテストの名前を絞るワイルドカード（例: 'test_phase*'）。既定は全部。

.PARAMETER TimeoutSec
    1本あたりのタイムアウト（既定 240 秒）。test_phase7_stability のように10ラウンド回すものが
    あるので、run_headless_test.ps1 の既定（90 秒）より長くしている。

.PARAMETER SkipTwoProcess
    2プロセス系を流さない（ポート 9999 を使うので、ゲームでホスト中の PC では付ける）。

.PARAMETER List
    流さずに分類だけを表示する。

.PARAMETER GodotExe
    Godot 実行ファイル。省略時は run_headless_test.ps1 と同じ既定値。

.EXAMPLE
    pwsh tools/run_all_tests.ps1
.EXAMPLE
    pwsh tools/run_all_tests.ps1 -Filter 'test_phase*'
.EXAMPLE
    pwsh tools/run_all_tests.ps1 -List
#>
[CmdletBinding()]
param(
    [string]$Filter = '*',
    [int]$TimeoutSec = 240,
    [switch]$SkipTwoProcess,
    [switch]$List,
    [string]$GodotExe,
    [string]$LogDir
)

$DefaultGodotExe = 'C:\dev\godot47\Godot_v4.7.2-stable_win64.exe'

# ---- 分類（名前は tests/ の中の .tscn から拡張子を除いたもの）----
$TwoProcess = @('net_roles', 'net_anim', 'net_live', 'emote')
$Windowed = @('uishot', 'screenshot', 'shot_stamina', 'basketball_preview', 'overalls_preview', 'shadow_ninja_preview')
$LiveEos = @('test_eos_live_smoke', 'test_eos_live_lobby_p2p')

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $PSScriptRoot 'run_headless_test.ps1'
if (-not $GodotExe) { $GodotExe = $DefaultGodotExe }
if (-not (Test-Path $GodotExe)) {
    Write-Error "Godot実行ファイルが見つからない: $GodotExe (-GodotExe で指定すること)"
}

function Get-Kind([string]$name) {
    if ($TwoProcess -contains $name) { return 'two-process' }
    if ($Windowed -contains $name) { return 'windowed' }
    if ($LiveEos -contains $name) { return 'live-eos' }
    return 'headless'
}

# run_headless_test.ps1 と同じ判定規則（大文字の FAIL か SCRIPT ERROR があれば失敗。
# 成功時にも出る "FAIL=0" だけは除く）。規則の理由は run_headless_test.ps1 のコメント参照
function Test-OutputFailed([string]$text) {
    $scan = $text -replace 'FAIL=0', ''
    return ($scan -cmatch 'FAIL') -or ($scan -cmatch 'SCRIPT ERROR')
}

function Invoke-TwoProcessTest([string]$name, [string]$logBase) {
    $scene = "res://tests/$name.tscn"
    $common = @('--headless', '--path', $repoRoot, $scene, '--')
    $hostOut = "$logBase.host.out.txt"; $hostErr = "$logBase.host.err.txt"
    $cliOut = "$logBase.client.out.txt"; $cliErr = "$logBase.client.err.txt"
    $h = Start-Process -FilePath $GodotExe -ArgumentList ($common + @('host')) -NoNewWindow -PassThru `
        -RedirectStandardOutput $hostOut -RedirectStandardError $hostErr
    # ホストが listen するまで少し待ってからクライアントを起動する（先に繋ぎに行くと即失敗する）
    Start-Sleep -Seconds 2
    $c = Start-Process -FilePath $GodotExe -ArgumentList ($common + @('client', '127.0.0.1')) -NoNewWindow -PassThru `
        -RedirectStandardOutput $cliOut -RedirectStandardError $cliErr
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $timedOut = $false
    foreach ($p in @($h, $c)) {
        $left = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
        if (-not $p.WaitForExit($left)) { $timedOut = $true }
    }
    if ($timedOut) {
        # 止めるのは自分が起動した2つの PID だけ（run_headless_test.ps1 と同じ方針）
        foreach ($p in @($h, $c)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        return 'TIMEOUT'
    }
    $text = (@($hostOut, $hostErr, $cliOut, $cliErr) | ForEach-Object { Get-Content $_ -Raw -ErrorAction SilentlyContinue }) -join "`n"
    if (Test-OutputFailed $text) { return 'FAIL' }
    return 'PASS'
}

$scenes = Get-ChildItem (Join-Path $repoRoot 'tests') -Filter '*.tscn' |
    Where-Object { $_.BaseName -like $Filter } | Sort-Object BaseName
$plan = $scenes | ForEach-Object { [pscustomobject]@{ Name = $_.BaseName; Kind = (Get-Kind $_.BaseName) } }

if ($List) {
    $plan | Group-Object Kind | ForEach-Object {
        Write-Host "[$($_.Name)] $($_.Count) 本" -ForegroundColor Cyan
        Write-Host ("  " + (($_.Group | ForEach-Object Name) -join ', '))
    }
    exit 0
}

if (-not $LogDir) {
    $LogDir = Join-Path ([IO.Path]::GetTempPath()) ("tag_game_tests\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Force $LogDir | Out-Null
Write-Host "ログ: $LogDir" -ForegroundColor DarkGray

$results = @()
foreach ($t in $plan) {
    $logBase = Join-Path $LogDir $t.Name
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $result = switch ($t.Kind) {
        'headless' {
            & pwsh -NoProfile -File $runner "res://tests/$($t.Name).tscn" -TimeoutSec $TimeoutSec -GodotExe $GodotExe *> "$logBase.txt"
            switch ($LASTEXITCODE) { 0 { 'PASS' } 124 { 'TIMEOUT' } default { 'FAIL' } }
        }
        'two-process' {
            if ($SkipTwoProcess) { 'SKIPPED' } else { Invoke-TwoProcessTest $t.Name $logBase }
        }
        default { 'NOT RUN' }
    }
    $sw.Stop()
    $color = switch ($result) { 'PASS' { 'Green' } 'NOT RUN' { 'DarkGray' } 'SKIPPED' { 'DarkGray' } default { 'Red' } }
    Write-Host ("{0,-36} {1,-12} {2,-8} {3,6:N1}s" -f $t.Name, $t.Kind, $result, $sw.Elapsed.TotalSeconds) -ForegroundColor $color
    $results += [pscustomobject]@{ Name = $t.Name; Kind = $t.Kind; Result = $result }
}

$notRun = @($results | Where-Object { $_.Result -in @('NOT RUN', 'SKIPPED') })
if ($notRun.Count -gt 0) {
    Write-Host "`n流さなかったもの（手動で確認する。手順は各テストのヘッダ）:" -ForegroundColor Yellow
    $notRun | Group-Object Kind | ForEach-Object {
        Write-Host ("  [{0}] {1}" -f $_.Name, (($_.Group | ForEach-Object Name) -join ', '))
    }
}

$pass = @($results | Where-Object Result -eq 'PASS').Count
$fail = @($results | Where-Object Result -eq 'FAIL').Count
$timeout = @($results | Where-Object Result -eq 'TIMEOUT').Count
$bad = @($results | Where-Object { $_.Result -in @('FAIL', 'TIMEOUT') })
if ($bad.Count -gt 0) {
    Write-Host "`n失敗したもの（ログは $LogDir）:" -ForegroundColor Red
    $bad | ForEach-Object { Write-Host "  $($_.Name) ($($_.Result))" -ForegroundColor Red }
}
Write-Host ("`nrun_all_tests 結果: PASS={0}, FAIL={1}, TIMEOUT={2}, 流さなかった={3}" -f $pass, $fail, $timeout, $notRun.Count)
if ($bad.Count -gt 0) { exit 1 }
exit 0
