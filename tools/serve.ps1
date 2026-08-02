<#
.SYNOPSIS
    ゲームサーバ（Godot ホスト）を Cloudflare Tunnel でインターネットに公開し、
    友達へ渡す参加リンクを組み立てる。

.DESCRIPTION
    先に Godot 側で HOST を押しておくこと（ポート 9999 で待ち受ける）。
    このスクリプトは cloudflared を起動し、割り当てられた trycloudflare.com の
    ホスト名を拾って

        https://<PagesURL>/?s=<tunnel host>

    という参加リンクを表示・クリップボードにコピーする。
    Ctrl+C で終了するとトンネルも閉じる。

    Cloudflare を挟む理由:
      - https で配信された Web ビルドからは ws:// が mixed content でブロックされる。
        トンネルが TLS を終端するので wss:// になる
      - 自宅回線のポート開放が不要（cloudflared は外向き接続しか張らない）

.PARAMETER PagesUrl
    Web ビルドを置いた GitHub Pages の URL。既定値は $DefaultPagesUrl。
    自分の URL に書き換えておくと引数なしで使える。

.PARAMETER Port
    Godot ホストが待ち受けているポート（network_manager.gd の PORT と合わせる）。

.EXAMPLE
    pwsh tools/serve.ps1
.EXAMPLE
    pwsh tools/serve.ps1 -PagesUrl https://oekklab-source.github.io/Tag_game
#>
[CmdletBinding()]
param(
    [string]$PagesUrl,
    [int]$Port = 9999
)

# GitHub Pages の URL（末尾のスラッシュ無し）
$DefaultPagesUrl = 'https://oekklab-source.github.io/Tag_game'

$ErrorActionPreference = 'Stop'

if (-not $PagesUrl) { $PagesUrl = $DefaultPagesUrl }
$PagesUrl = $PagesUrl.TrimEnd('/')

$cloudflared = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
if (-not $cloudflared) {
    Write-Error @'
cloudflared が見つからない。先にインストールする:
    winget install --id Cloudflare.cloudflared
インストール後は PowerShell を開き直すこと（PATH の反映のため）。
'@
}

# Godot 側が待ち受けていないとトンネルは張れても接続が全部 502 になるので先に確かめる
$listening = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
if (-not $listening) {
    Write-Warning "ポート $Port で待ち受けているプロセスが無い。先に Godot で HOST を押すこと。"
}

Write-Host "cloudflared を起動中 (localhost:$Port を公開)..." -ForegroundColor Cyan

# quick tunnel の URL は標準エラーへバナーとして出るので、そこから拾う。
# 2>&1 でマージすると PowerShell が ErrorRecord に包むため、文字列化してから照合する
$tunnelHost = $null
& $cloudflared tunnel --url "http://localhost:$Port" --no-autoupdate 2>&1 | ForEach-Object {
    $line = $_.ToString()
    Write-Host $line -ForegroundColor DarkGray
    if (-not $tunnelHost -and $line -match '([a-z0-9-]+\.trycloudflare\.com)') {
        $tunnelHost = $Matches[1]
        $link = "$PagesUrl/?s=$tunnelHost"

        Write-Host ''
        Write-Host '  ===================== 参加リンク =====================' -ForegroundColor Green
        Write-Host "   $link" -ForegroundColor Green
        Write-Host '  ======================================================' -ForegroundColor Green
        try { Set-Clipboard -Value $link; Write-Host '  （クリップボードにコピー済み）' -ForegroundColor Green }
        catch { Write-Host "  （クリップボードへのコピーに失敗: $_）" -ForegroundColor Yellow }
        Write-Host '  このウィンドウを閉じる / Ctrl+C でトンネルが切れる。' -ForegroundColor Yellow
        Write-Host ''
    }
}
