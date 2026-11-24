<#
.SYNOPSIS
    リリース版用の eos_credentials.cfg（deployment_id だけを Live Deployment に替えたもの）を、
    GitHub の environment secret EOS_CREDENTIALS_CFG_B64 に登録する（KAN-35）。

.DESCRIPTION
    開発機の eos_credentials.cfg は、Live サンドボックスの中の「DevDeployment」を指している。
    リリース版は同じサンドボックスの「Live Deployment」に切り替えると決めた（KAN-35、2026-11-11）。
    開発中のデータ（自分たちのレート、クラウドセーブ、テストが書き込んだ値など）と、
    本番のプレイヤーのデータを分けるため。開発機と2台目の PC の cfg は DevDeployment のままにする。

    そこで、このスクリプトは開発機の cfg を読み、deployment_id の値だけを差し替えた内容をメモリ上で作り、
    base64 にして標準入力から `gh secret set` へ渡す。
      - 差し替えた cfg はディスクに書かない（git 管理外の場所でも、置き忘れて配布物や共有に紛れるのを防ぐ）
      - 値は画面に出さない。確認用に ID の先頭8文字だけを出す（チャットやログへ貼られても困らない長さ）
      - Live Deployment の ID は Portal のコピーボタンで写し、クリップボード経由で受け取る。
        スクリーンショットからの読み取りは使わない（I / l / 1 の取り違えの前例がある）

    deployment_id 以外の行が1文字でも変わっていたら、登録せずに失敗する
    （ほかの値を壊した cfg を登録すると、CI のビルドが「EOS につながらない exe」になるため）。

    windows-release.yml はこの secret から cfg を復元して書き出す。登録したら Actions の
    「Windows release」を手動実行（push_to_itch はオフ）して、Restore と Smoke test が緑になるのを確かめる。

    終了コード: 0 = 成功（DryRun では検査の成功）/ 1 = 入力・cfg・gh のどれかに問題がある。

.PARAMETER DeploymentId
    Live Deployment の ID（32桁の16進）。省略するとクリップボードから読む。

.PARAMETER CfgPath
    元にする cfg（既定: リポジトリ直下の eos_credentials.cfg）。

.PARAMETER Repo
    登録先のリポジトリ（既定: oekklab-source/Tag_game）。

.PARAMETER Environment
    登録先の environment（既定: release。windows-release.yml の environment と揃える）。

.PARAMETER DryRun
    差し替えと検査だけを行い、gh には何も送らない。

.EXAMPLE
    # Portal で Live Deployment の ID をコピーしてから
    pwsh tools/set_release_eos_secret.ps1 -DryRun
    pwsh tools/set_release_eos_secret.ps1
#>
[CmdletBinding()]
param(
    [string]$DeploymentId,
    [string]$CfgPath,
    [string]$Repo = 'oekklab-source/Tag_game',
    [string]$Environment = 'release',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Fail([string]$msg) {
    Write-Host "FAIL: $msg" -ForegroundColor Red
    exit 1
}

function Short([string]$id) { return $id.Substring(0, 8) + '…' }

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $CfgPath) { $CfgPath = Join-Path $repoRoot 'eos_credentials.cfg' }
if (-not (Test-Path -LiteralPath $CfgPath)) { Fail "cfg が見つからない: $CfgPath" }

# --- Live Deployment の ID ---
if (-not $DeploymentId) {
    $DeploymentId = Get-Clipboard -Raw
    if (-not $DeploymentId) { Fail 'クリップボードが空。Portal で Live Deployment の ID をコピーしてから実行する' }
}
$DeploymentId = $DeploymentId.Trim()
# -cnotmatch: Portal の ID は小文字。大文字が来たら手で打ち直した可能性が高いので、そのまま通さない
if ($DeploymentId -cnotmatch '^[0-9a-f]{32}$') {
    # 値そのものは出さない（クリップボードに別の秘密が入っていた場合に画面へ出さないため）
    Fail "Live Deployment の ID の形ではない（32桁の小文字16進を期待。長さ $($DeploymentId.Length)）"
}

# --- cfg を読む（BOM の有無を保ったまま書き戻せるように、バイト列から読む） ---
$bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $CfgPath))
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$utf8 = New-Object System.Text.UTF8Encoding($false)
$text = if ($hasBom) { $utf8.GetString($bytes, 3, $bytes.Length - 3) } else { $utf8.GetString($bytes) }

$pattern = '(?m)^(?<pre>[ \t]*deployment_id[ \t]*=[ \t]*")(?<id>[0-9a-fA-F]{32})(?<post>".*)$'
$found = [regex]::Matches($text, $pattern)
if ($found.Count -ne 1) { Fail "cfg の deployment_id 行がちょうど1つではない（$($found.Count) 個）" }
$currentId = $found[0].Groups['id'].Value
if ($currentId -ieq $DeploymentId) {
    Fail "受け取った ID が今の cfg と同じ（$(Short $currentId)）。Dev ではなく Live Deployment の ID をコピーする"
}

$newText = [regex]::Replace($text, $pattern, { param($m) $m.Groups['pre'].Value + $DeploymentId + $m.Groups['post'].Value })

# --- deployment_id 以外が変わっていないことを行ごとに確かめる ---
$oldLines = $text -split "`r?`n"
$newLines = $newText -split "`r?`n"
if ($oldLines.Count -ne $newLines.Count) { Fail '差し替えで行数が変わった' }
$changedKeys = @()
for ($i = 0; $i -lt $oldLines.Count; $i++) {
    if ($oldLines[$i] -cne $newLines[$i]) {
        $key = if ($oldLines[$i] -match '^\s*([A-Za-z_]+)\s*=') { $Matches[1] } else { "（$($i + 1) 行目）" }
        $changedKeys += $key
    }
}
if ($changedKeys.Count -ne 1 -or $changedKeys[0] -ne 'deployment_id') {
    Fail "deployment_id 以外も変わった: $($changedKeys -join ', ')"
}

$keys = $newLines | Where-Object { $_ -match '^\s*([A-Za-z_]+)\s*=' } | ForEach-Object { ($_ -split '=')[0].Trim() }
Write-Host "元の cfg       : $CfgPath（BOM: $hasBom）"
Write-Host "キー           : $($keys -join ', ')"
Write-Host "deployment_id  : $(Short $currentId) → $(Short $DeploymentId)（ほかの行は同一）"

$outBytes = $utf8.GetBytes($newText)
if ($hasBom) { $outBytes = [byte[]](0xEF, 0xBB, 0xBF) + $outBytes }
$b64 = [Convert]::ToBase64String($outBytes)

if ($DryRun) {
    Write-Host "DryRun: gh には送っていない（登録先は $Repo の environment '$Environment' の EOS_CREDENTIALS_CFG_B64）"
    exit 0
}

# --- 登録 ---
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Fail 'gh が見つからない' }
# environment が無いまま --env を付けると、gh のエラーが分かりにくいので先に確かめる
gh api "repos/$Repo/environments/$Environment" --silent 2>$null
if ($LASTEXITCODE -ne 0) {
    Fail "environment '$Environment' が $Repo に無い（README「初回の設定」の手順3で先に作る）"
}
# --body で渡すとコマンドラインに値が残る（プロセス一覧から見える）ので、標準入力で渡す
$b64 | gh secret set EOS_CREDENTIALS_CFG_B64 --env $Environment --repo $Repo
if ($LASTEXITCODE -ne 0) { Fail 'gh secret set に失敗した' }
Write-Host "登録した: $Repo / environment '$Environment' / EOS_CREDENTIALS_CFG_B64（deployment_id = $(Short $DeploymentId)）"
Write-Host '次: Actions の「Windows release」を手動実行（push_to_itch はオフ）して緑になるのを確かめる'
exit 0
