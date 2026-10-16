<#
.SYNOPSIS
    Windows 版を書き出し、eos_credentials.cfg に不備があれば成果物を消して失敗させる。

.DESCRIPTION
    素の `godot --headless --export-release "Windows Desktop" ...` は、eos_credentials.cfg が
    無くても空欄でも黙って完走し、「EOS に一切つながらない exe」を作る（Phase 3 L-08）。

    addons/tag_game_export_guard/ のエクスポートプラグインが不備を検出すると
    "[TagGameExportGuard] BLOCKED" を出力するが、Godot 4.7.2 ではプラグインから
    書き出しそのものを中断する手段が無い（option warning も add_message(ERROR) も
    実測で書き出しを止めず、終了コードも 0 のまま。詳細は export_guard.gd の冒頭）。
    そこでこのラッパーが出力を走査し、目印があれば出来上がった exe を削除して exit 1 を返す。
    「壊れた exe が手元に残っていて、うっかり butler push する」事故を防ぐため、
    警告ではなく削除にしている。

    意図的に EOS なしの版を作るときは、書き出しプリセットの
    tag_game/require_eos_credentials を false にする（このラッパーの引数では切らない。
    判断を export_presets.cfg の差分に残すため）。

    もう1つ、配布物に開発用のファイルが入っていないかも検査する（KAN-30）。
    プリセットの exclude_filter が空だった頃の exe には、tests/shots の確認用 PNG
    （開発機の実プロフィールが写り込んだ前例がある）や service/*/node_modules まで
    500件以上入っていた。exclude_filter は誰かが消しても書き出しは黙って通るので、
    出力の savepack 行（pck に入れたファイルを1件ずつ出す。2026-10-16 に pck の
    ディレクトリを直接読んで全件一致することを確認済み）を走査し、禁止パスがあれば
    exe を消して失敗させる。禁止パスは $ForbiddenPackPaths（exclude_filter と揃えること）。

    終了コード: 0 = 成功 / 1 = ガードが不備を検出、配布物に禁止パスが入っていた、
    または exe が出力されなかった / 124 = タイムアウト。
    Godot の終了コードそのものは判定に使わない（run_headless_test.ps1 と同じ方針）。

.PARAMETER OutputPath
    書き出し先（既定: export/windows/TagGame.exe。README の手順と同じ）。

.PARAMETER GodotExe
    Godotエディタ実行ファイルのフルパス。既定値は $DefaultGodotExe。

.PARAMETER TimeoutSec
    このタイムアウト（壁時計秒）を過ぎたら強制終了する（既定 600 秒。書き出しは数分かかる）。

.EXAMPLE
    pwsh tools/export_windows.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputPath = 'export/windows/TagGame.exe',
    [string]$GodotExe,
    [int]$TimeoutSec = 600
)

# この開発機でのデフォルトパス（run_headless_test.ps1 と同じ）
$DefaultGodotExe = 'C:\dev\godot47\Godot_v4.7.2-stable_win64.exe'
# addons/tag_game_export_guard/export_guard.gd の BLOCK_MARKER と一致させること
$BlockMarker = '[TagGameExportGuard] BLOCKED'
# 配布物に入っていてはいけないパス（正規表現。export_presets.cfg の exclude_filter と揃えること）。
# tools/ は serve.ps1 だけを include_filter で同梱するので、それ以外を禁止にする
# （exclude_filter は include_filter の後に効くため、tools/* を丸ごと除外すると serve.ps1 まで消える）
$ForbiddenPackPaths = @(
    '^res://(tests|export|service|server|docs)/',
    'node_modules',
    '^res://tools/(?!serve\.ps1$)',
    '^res://skills-lock\.json$'
)

$ErrorActionPreference = 'Stop'

if (-not $GodotExe) { $GodotExe = $DefaultGodotExe }
if (-not (Test-Path $GodotExe)) {
    Write-Error "Godot実行ファイルが見つからない: $GodotExe (-GodotExe で指定するか `$DefaultGodotExe を書き換えること)"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$outFull = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $repoRoot $OutputPath }
New-Item -ItemType Directory -Force (Split-Path -Parent $outFull) | Out-Null

# 前回の exe が残っていると「今回出力されたか」を判定できないので先に消す
Remove-Item $outFull -ErrorAction SilentlyContinue

$allArgs = @('--headless', '--path', "`"$repoRoot`"", '--export-release', '"Windows Desktop"', "`"$outFull`"")
Write-Host "実行: $GodotExe $($allArgs -join ' ')" -ForegroundColor Cyan

$outFile = New-TemporaryFile
$errFile = New-TemporaryFile
try {
    $proc = Start-Process -FilePath $GodotExe -ArgumentList $allArgs `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        Write-Warning "タイムアウト(${TimeoutSec}秒)。プロセス(PID $($proc.Id))を強制終了する。"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Remove-Item $outFull -ErrorAction SilentlyContinue
        exit 124
    }

    $outText = Get-Content $outFile -Raw
    $errText = Get-Content $errFile -Raw
    $allText = "$outText`n$errText"

    # 進捗行（savepack のファイル一覧）は数百行あるので出さず、エラー系だけ見せる。
    # add_message() の複数行メッセージは1行目にしか ERROR が付かないので、
    # 問題点を1行にまとめてある目印の行も併せて出す
    ($allText -split "`r?`n") | Where-Object { $_ -cmatch 'ERROR|WARNING' -or $_.Contains($BlockMarker) } | ForEach-Object { Write-Host $_ -ForegroundColor DarkYellow }

    if ($allText.Contains($BlockMarker)) {
        Remove-Item $outFull -ErrorAction SilentlyContinue
        Write-Host "=> eos_credentials.cfg に不備があるため、書き出した exe を削除して exit 1 を返す" -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path $outFull)) {
        Write-Host "=> exe が出力されなかったため exit 1 を返す（上のエラーを確認）" -ForegroundColor Red
        exit 1
    }

    # savepack 行の文言はエディタの表示言語で変わる（日本語なら「ファイルの保存中: res://…」）ので、
    # 行頭の段階名 savepack と res:// 以降のパスだけを拾う。
    # パスの直後には ANSI の色コード（ESC[39m）が付いているので、ESC の手前で切る
    # （\S+ だと色コードまで取り込み、serve.ps1 が「serve.ps1 以外の tools/」と誤判定される）
    $packedFiles = @(($allText -split "`r?`n") | Where-Object { $_ -match 'savepack' } |
        ForEach-Object { if ($_ -match '(res://[^\s\x1b]+)') { $Matches[1] } })
    if ($packedFiles.Count -eq 0) {
        # 一覧が取れないまま「禁止パスなし」と判定すると検査が素通りになるので、失敗扱いにする
        Remove-Item $outFull -ErrorAction SilentlyContinue
        Write-Host "=> 出力から pck の中身一覧（savepack 行）が読めなかったため、exe を削除して exit 1 を返す" -ForegroundColor Red
        exit 1
    }
    $forbidden = @($packedFiles | Where-Object { $f = $_; $ForbiddenPackPaths | Where-Object { $f -match $_ } })
    if ($forbidden.Count -gt 0) {
        $forbidden | Select-Object -First 20 | ForEach-Object { Write-Host "  禁止パス: $_" -ForegroundColor DarkYellow }
        Remove-Item $outFull -ErrorAction SilentlyContinue
        Write-Host "=> 配布物に開発用ファイルが $($forbidden.Count) 件入っていたため、exe を削除して exit 1 を返す（export_presets.cfg の exclude_filter を確認）" -ForegroundColor Red
        exit 1
    }
    Write-Host "=> pck の中身 $($packedFiles.Count) 件に禁止パスなし" -ForegroundColor Green

    Write-Host "=> 書き出し成功: $outFull" -ForegroundColor Green
    exit 0
}
finally {
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
}
