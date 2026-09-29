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

.PARAMETER HostAddrFile
    ②EOSロビー経由の参加者へホスト名を伝えるため、確立したトンネルの
    ホスト名をこのファイルへ書き出す。Godot 側（network_manager.gd の
    _launch_tunnel）が渡す。手動実行時は省略してよい。

.PARAMETER ParentPid
    ゲーム（Godot ホスト）から窓なしで起動されたときに、ゲーム自身の PID が渡される。
    これがあると「ゲーム連動モード」で動く:
      - cloudflared の出力はログファイルへ流し、画面にもクリップボードにも何も出さない
        （窓が見えないのにクリップボードだけ黙って上書きされるのを避ける。
        ゲーム内にコピーボタンがある）
      - ゲームのプロセスが消えたら（強制終了・クラッシュを含む）cloudflared を止めて終わる。
        ゲームが正常に終わるときはゲーム側（network_manager.gd の _stop_tunnel）が止めるが、
        タスクマネージャでの強制終了やクラッシュでは GDScript が一切走らないため、
        こちら側でもゲームの生死を見張る二重構えにしている
      - 起動に失敗したら理由を ErrorFile に書く（窓が見えないので Write-Error では誰にも届かない）
    手動実行時は省略する（従来どおり前面で動き、Ctrl+C で止める）。

.PARAMETER PidFile
    ゲーム連動モードで cloudflared の PID を書き出す先。ゲーム側はこの PID を直接止める
    （Windows ではこのスクリプトの PowerShell を止めても子の cloudflared は道連れにならないため）。
    前回の PID が残っていて、それがまだ cloudflared として生きていれば孤児とみなして止める。

.PARAMETER ErrorFile
    ゲーム連動モードで起動に失敗したときに、理由のコードを1行目に書き出す先。
    not_found = cloudflared が見つからない / exited = cloudflared が途中で終了した。
    2行目以降は調査用の詳細（cloudflared のログの末尾など）。

.EXAMPLE
    pwsh tools/serve.ps1
.EXAMPLE
    pwsh tools/serve.ps1 -PagesUrl https://oekklab-source.github.io/Tag_game
#>
[CmdletBinding()]
param(
    [string]$PagesUrl,
    [int]$Port = 9999,
    [string]$HostAddrFile,
    [int]$ParentPid = 0,
    [string]$PidFile,
    [string]$ErrorFile
)

# GitHub Pages の URL（末尾のスラッシュ無し）
$DefaultPagesUrl = 'https://oekklab-source.github.io/Tag_game'

$ErrorActionPreference = 'Stop'

if (-not $PagesUrl) { $PagesUrl = $DefaultPagesUrl }
$PagesUrl = $PagesUrl.TrimEnd('/')

$cloudflared = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source

# 失敗時にホストが拾ってしまわないよう、api.trycloudflare.com（quick tunnel を払い出す API。
# 失敗時のエラー行に現れる）は除外する
$TunnelHostPattern = 'https://(?!api\.)([a-z0-9-]+\.trycloudflare\.com)'

if ($ParentPid -gt 0) {
    # ---- ゲーム連動モード（.PARAMETER ParentPid 参照）。ここから先は画面に何も出さない ----
    $ErrorActionPreference = 'Continue'
    function Write-TunnelError([string]$Code, [string]$Detail) {
        if ($ErrorFile) {
            try { Set-Content -Path $ErrorFile -Value "$Code`n$Detail" -Encoding utf8 } catch {}
        }
    }
    if (-not $PidFile) { $PidFile = Join-Path ([IO.Path]::GetTempPath()) 'tag_game_cloudflared.pid' }

    # 前回の孤児を止める（ゲームとこのスクリプトが両方まとめて落ちた等で、cloudflared だけが
    # 残っている場合）。PID は別プロセスに再利用されうるので、名前が cloudflared のときだけ止める
    if (Test-Path $PidFile) {
        $oldPid = 0
        if ([int]::TryParse(([string](Get-Content $PidFile -Raw)).Trim(), [ref]$oldPid)) {
            Get-Process -Id $oldPid -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessName -eq 'cloudflared' } |
                Stop-Process -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $PidFile -ErrorAction SilentlyContinue
    }

    # 親は PID ではなくプロセスオブジェクト（ハンドル）で見張る。PID は終了後に別プロセスへ
    # 再利用されうるので、毎回 Get-Process -Id で引き直すと別物を「まだ生きている」と誤認しうる
    $parent = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
    if (-not $parent) { exit }
    if (-not $cloudflared) {
        Write-TunnelError 'not_found' 'cloudflared が PATH に見つからない（winget install --id Cloudflare.cloudflared）'
        exit
    }

    # 出力はファイルへ流す。パイプで受けて読むのをやめると詰まって止まるが、ファイルならその心配が無い
    $logFile = [IO.Path]::ChangeExtension($PidFile, '.log')
    $outFile = [IO.Path]::ChangeExtension($PidFile, '.out.log')
    $proc = Start-Process -FilePath $cloudflared `
        -ArgumentList @('tunnel', '--url', "http://localhost:$Port", '--no-autoupdate') `
        -NoNewWindow -PassThru -RedirectStandardError $logFile -RedirectStandardOutput $outFile
    Set-Content -Path $PidFile -Value $proc.Id -NoNewline

    $tunnelHost = $null
    try {
        while (-not $parent.HasExited) {
            if ($proc.HasExited) {
                $tail = (Get-Content $logFile -Tail 20 -ErrorAction SilentlyContinue) -join "`n"
                Write-TunnelError 'exited' $tail
                break
            }
            if (-not $tunnelHost) {
                $m = Select-String -Path $logFile -Pattern $TunnelHostPattern -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($m) {
                    $tunnelHost = $m.Matches[0].Groups[1].Value
                    if ($HostAddrFile) {
                        try { Set-Content -Path $HostAddrFile -Value $tunnelHost -NoNewline -Encoding utf8 } catch {}
                    }
                }
            }
            Start-Sleep -Milliseconds 500
        }
    } finally {
        # ゲームが消えた・cloudflared が落ちた・このスクリプトが Ctrl+C 等で止められた、のいずれでも
        # cloudflared を残さない（TerminateProcess で殺された場合はここに来ないので、
        # その場合はゲーム側が PidFile の PID を直接止める）
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item $PidFile -ErrorAction SilentlyContinue
    }
    exit
}

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
# 2>&1 でマージすると PowerShell が ErrorRecord に包むため、文字列化してから照合する。
# $ErrorActionPreference='Stop' のままだと、cloudflared が起動時に出す通常のバナー
# (起動失敗ではない) すら ErrorRecord として終端エラー扱いになり、肝心の
# trycloudflare.com のホスト名行に到達する前にパイプラインが止まってしまう。
# トンネルはこの後 Ctrl+C まで動き続け、この先で他のコマンドは走らないので
# 元の値へ戻す必要はない
$tunnelHost = $null
$ErrorActionPreference = 'Continue'
& $cloudflared tunnel --url "http://localhost:$Port" --no-autoupdate 2>&1 | ForEach-Object {
    $line = $_.ToString()
    Write-Host $line -ForegroundColor DarkGray
    if (-not $tunnelHost -and $line -match $TunnelHostPattern) {
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

        # ②EOSロビー経由の参加者が実際のホストへ繋げるよう、Godot 側に
        # ホスト名を渡す（network_manager.gd がこのファイルをポーリングしている）
        if ($HostAddrFile) {
            try { Set-Content -Path $HostAddrFile -Value $tunnelHost -NoNewline -Encoding utf8 }
            catch { Write-Host "  （ホスト名の書き出しに失敗: $_）" -ForegroundColor Yellow }
        }
    }
}
