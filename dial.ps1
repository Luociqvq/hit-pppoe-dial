# 一键 PPPoE 拨号/断开/断线自动重连
# 用法: dial.ps1 [-Action toggle|dial|hangup|status|watch|config|install|uninstall] [-Quiet]

param(
    [ValidateSet('toggle', 'dial', 'hangup', 'status', 'watch', 'config', 'install', 'uninstall')]
    [string]$Action = 'toggle',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$Self = $PSCommandPath
$Root = Split-Path -Parent $Self
$Ini = Join-Path $Root 'config.ini'
$Log = Join-Path $Root 'dial.log'
$PsExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$script:Entry = ''
$script:User = ''
$script:Pass = ''
$script:Retry = 20
$script:WatchOn = $true

$RasErrors = @{
    623 = '电话簿里找不到这个连接名，检查 config.ini 的 ENTRY'
    633 = '拨出端口不可用（网卡没插好 / 光猫没就绪）'
    676 = '线路忙'
    678 = '远程计算机无响应（光猫、网线或运营商侧问题）'
    680 = '没有拨号音'
    691 = '账号或密码错误（也可能是欠费、或账号已在线被占用）'
    629 = '远程计算机关闭了连接'
    630 = '端口被断开'
    720 = '没有为该连接配置网络组件'
    734 = '链路控制协议被远程终止'
}

function ErrText($Code) {
    $t = $RasErrors[[int]$Code]
    if ($t) { return "$t（错误码 $Code）" }
    return "未知错误（错误码 $Code，详细信息看 dial.log）"
}

function Write-Log([string]$Msg) {
    try { Add-Content -LiteralPath $Log -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Msg) -Encoding UTF8 } catch { }
}

function Say([string]$Msg) {
    Write-Log $Msg
    Write-Host $Msg
}

function Report([string]$Msg, [switch]$Bad) {
    Write-Log $Msg
    Write-Host $Msg
    if ($Quiet) { return }
    Add-Type -AssemblyName System.Windows.Forms
    $icon = if ($Bad) { [System.Windows.Forms.MessageBoxIcon]::Error } else { [System.Windows.Forms.MessageBoxIcon]::Information }
    [void][System.Windows.Forms.MessageBox]::Show($Msg, '宽带拨号', [System.Windows.Forms.MessageBoxButtons]::OK, $icon)
}

function Read-Config([switch]$NeedCred) {
    if (-not (Test-Path -LiteralPath $Ini)) { throw "找不到配置文件 $Ini" }
    $map = @{}
    foreach ($line in (Get-Content -LiteralPath $Ini -Encoding UTF8)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith(';')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $map[$t.Substring(0, $i).Trim().ToUpperInvariant()] = $t.Substring($i + 1).Trim()
    }
    $script:Entry = $map['ENTRY']
    $script:User = $map['ACCOUNT']
    $script:Pass = $map['PASSWORD']
    if ($map['RETRY_SECONDS']) { $script:Retry = [int]$map['RETRY_SECONDS'] }
    if ($map['WATCHER']) { $script:WatchOn = ($map['WATCHER'] -ne '0') }
    if (-not $script:Entry) { $script:Entry = '宽带连接' }
    if ($NeedCred -and (-not $script:User -or -not $script:Pass -or $script:User -like '*你的*' -or $script:Pass -like '*你的*')) {
        throw '请先在 config.ini 里填好 ACCOUNT 和 PASSWORD'
    }
}

function Get-State {
    # 部分 Windows 上 PPPoE 接口在 Get-NetAdapter / Win32_NetworkAdapter 里查不到，
    # 只有 Get-NetIPInterface 认它，所以在线状态以它为准（用 Get-NetAdapter 会误报"未连接"）。
    $ni = @(Get-NetIPInterface -InterfaceAlias $script:Entry -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($ni.Count -eq 0 -or $ni[0].ConnectionState -ne 'Connected') {
        return [pscustomobject]@{ Connected = $false; Ip = $null }
    }
    $ip = @(Get-NetIPAddress -InterfaceIndex $ni[0].ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1)
    [pscustomobject]@{ Connected = $true; Ip = $ip[0].IPAddress }
}

function Invoke-Rasdial([string[]]$RasArgs) {
    $out = & rasdial @RasArgs 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out.Trim() }
}

function Find-Watcher {
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'dial\.ps1' -and $_.CommandLine -match '\bwatch\b' })
}

function Stop-Watcher {
    Find-Watcher | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Start-Watcher {
    if (-not $script:WatchOn) { return }
    if ((Find-Watcher).Count -gt 0) { return }
    Start-Process -FilePath $PsExe -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $Self, '-Action', 'watch', '-Quiet') | Out-Null
    Write-Log '后台自动重连监控已拉起'
}

function Invoke-Dial {
    if ((Get-State).Connected) { return 0 }
    $r = Invoke-Rasdial @($script:Entry, $script:User, $script:Pass)
    Write-Log "rasdial 返回 code=$($r.Code) $($r.Text)"
    $r.Code
}

function Watch-Loop {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\Qoder-PppoeDial-Watch')
    if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); return }
    Write-Log "自动重连监控已启动，检查间隔 $($script:Retry)s"
    try {
        $fails = 0
        while ($true) {
            $nap = $script:Retry
            if (-not (Get-State).Connected) {
                $code = Invoke-Dial
                if ($code -eq 0 -and (Get-State).Connected) {
                    $fails = 0
                    Write-Log '掉线后已自动重连成功'
                } else {
                    $fails++
                    Write-Log "自动重连失败：$(ErrText $code)"
                    $nap = [Math]::Min($script:Retry * 3, 300)
                    if ($fails -ge 5) { Write-Log '连续 5 次重连失败，停止后台监控（检查账号密码或线路后重新双击拨号）'; return }
                }
            }
            Start-Sleep -Seconds $nap
        }
    } finally {
        [void]$mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Install-Shortcut {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '宽带拨号.lnk'
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $s.TargetPath = $PsExe
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Self`""
    $s.WorkingDirectory = $Root
    $s.IconLocation = "$env:SystemRoot\System32\rasdlg.dll,0"
    $s.Description = '一键拨号 / 已连接时再点一次断开'
    $s.Save()
    Report "已在桌面创建「宽带拨号」快捷方式：`n$lnk`n`n双击即拨号，已连接时双击则断开。"
}

function Uninstall-Shortcut {
    Stop-Watcher
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '宽带拨号.lnk'
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
    Report '已移除桌面快捷方式并停止后台重连监控。'
}

try {
    if (@('toggle', 'dial', 'watch') -contains $Action) { Read-Config -NeedCred } else { Read-Config }

    if ($Action -eq 'toggle') {
        $Action = if ((Get-State).Connected) { 'hangup' } else { 'dial' }
        Write-Log "toggle -> $Action"
    }

    switch ($Action) {
        'config' { Start-Process notepad.exe "`"$Ini`"" }
        'install' { Install-Shortcut }
        'uninstall' { Uninstall-Shortcut }
        'status' {
            $st = Get-State
            if ($st.Connected) { Report "已连接：$($script:Entry)`nIP：$($st.Ip)" } else { Report "未连接：$($script:Entry)" }
        }
        'dial' {
            $st = Get-State
            if ($st.Connected) { Start-Watcher; Say "已经处于连接状态`nIP：$($st.Ip)`n后台重连监控已确保开启"; break }
            $code = Invoke-Dial
            if ($code -eq 0 -and (Get-State).Connected) {
                Start-Watcher
                $w = if ($script:WatchOn) { "，后台自动重连监控已开启（掉线每 $($script:Retry)s 重试）" } else { '' }
                Say "拨号成功 ✓$w"
            } else {
                Report "拨号失败：$(ErrText $code)" -Bad
            }
        }
        'hangup' {
            Stop-Watcher
            if (-not (Get-State).Connected) { Say '当前本来就是未连接状态（后台重连监控已停止）'; break }
            $r = Invoke-Rasdial @($script:Entry, '/d')
            Write-Log "断开返回 code=$($r.Code) $($r.Text)"
            Start-Sleep -Seconds 1
            if ((Get-State).Connected) { Report '断开失败，请重试' -Bad } else { Say '已断开，后台重连监控已停止' }
        }
        'watch' { Watch-Loop }
    }
} catch {
    Report "出错了：$($_.Exception.Message)" -Bad
    if (@('dial', 'toggle') -contains $Action -and (Test-Path -LiteralPath $Ini)) { Start-Process notepad.exe "`"$Ini`"" }
}
