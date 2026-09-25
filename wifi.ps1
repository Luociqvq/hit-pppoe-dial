# 一键连接 HIT-WLAN 并完成 ePortal 门户认证（不开浏览器）
# 用法: wifi.ps1 [-Action connect|disconnect|status|logout|install|uninstall] [-Quiet]

param(
    [ValidateSet('connect', 'disconnect', 'status', 'logout', 'install', 'uninstall')]
    [string]$Action = 'connect',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$Self = $PSCommandPath
$Root = Split-Path -Parent $Self
$Ini = Join-Path $Root 'config.ini'
$Log = Join-Path $Root 'wifi.log'
$PsExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$ProbeUrl = 'http://www.msftconnecttest.com/redirect'
$OnlineMark = 'go.microsoft.com/fwlink'

$script:Profile = 'HIT-WLAN'
$script:Alias = ''
$script:User = ''
$script:Pass = ''
$script:Base = 'http://202.118.253.94:8080'

function Write-Log([string]$Msg) {
    try { Add-Content -LiteralPath $Log -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Msg) -Encoding UTF8 } catch { }
}

function Say([string]$Msg) {
    Write-Log $Msg
    Write-Host $Msg
}

function Report([string]$Msg, [switch]$Bad) {
    Say $Msg
    if ($Quiet) { return }
    Add-Type -AssemblyName System.Windows.Forms
    $icon = if ($Bad) { [System.Windows.Forms.MessageBoxIcon]::Error } else { [System.Windows.Forms.MessageBoxIcon]::Information }
    [void][System.Windows.Forms.MessageBox]::Show($Msg, '校园网 WiFi', [System.Windows.Forms.MessageBoxButtons]::OK, $icon)
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $Ini)) { throw "找不到配置文件 $Ini" }
    $map = @{}
    foreach ($line in (Get-Content -LiteralPath $Ini -Encoding UTF8)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith(';')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $map[$t.Substring(0, $i).Trim().ToUpperInvariant()] = $t.Substring($i + 1).Trim()
    }
    if ($map['WLAN_PROFILE']) { $script:Profile = $map['WLAN_PROFILE'] }
    if ($map['WLAN_ALIAS']) { $script:Alias = $map['WLAN_ALIAS'] }
    if ($map['EPORTAL_BASE']) { $script:Base = $map['EPORTAL_BASE'] }
    # 无线认证默认复用宽带账号密码；想分开就在 config.ini 里加 WLAN_ACCOUNT / WLAN_PASSWORD
    if ($map['WLAN_ACCOUNT']) { $script:User = $map['WLAN_ACCOUNT'] } else { $script:User = $map['ACCOUNT'] }
    if ($map['WLAN_PASSWORD']) { $script:Pass = $map['WLAN_PASSWORD'] } else { $script:Pass = $map['PASSWORD'] }
    if (-not $script:Alias) {
        $w = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN' } | Select-Object -First 1)
        if ($w.Count -eq 0) { throw '找不到无线网卡' }
        $script:Alias = $w[0].Name
    }
    if (@('connect', 'logout') -contains $Action) {
        if (-not $script:User -or -not $script:Pass -or $script:User -like '*你的*') {
            throw '请先在 config.ini 里填好 ACCOUNT 和 PASSWORD（或 WLAN_ACCOUNT / WLAN_PASSWORD）'
        }
    }
}

function Get-WlanIp {
    $ni = @(Get-NetIPInterface -InterfaceAlias $script:Alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.ConnectionState -eq 'Connected' } | Select-Object -First 1)
    if ($ni.Count -eq 0) { return $null }
    @(Get-NetIPAddress -InterfaceIndex $ni[0].ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1)[0].IPAddress
}

function Invoke-Curl([string[]]$CurlArgs) {
    # 门户应答的 JSON 里带中文，curl 输出是 UTF-8，得把控制台解码临时切成 UTF-8，否则 GBK 下会变乱码
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $a = @('--silent', '--show-error', '--max-time', '10')
        $ip = Get-WlanIp
        if ($ip) { $a += @('--interface', $ip) }
        $all = $a + $CurlArgs
        & curl.exe @all 2>&1 | Out-String
    } finally {
        [Console]::OutputEncoding = $prev
    }
}

function Get-PortalState {
    $body = Invoke-Curl @($ProbeUrl)
    if (-not $body) { return [pscustomobject]@{ Authenticated = $false; Portal = $null } }
    if ($body -match [regex]::Escape($OnlineMark)) {
        return [pscustomobject]@{ Authenticated = $true; Portal = $null }
    }
    $urls = [regex]::Matches($body, '''([^'']*)''|"([^"]*)"') | ForEach-Object {
        if ($_.Groups[1].Value) { $_.Groups[1].Value } else { $_.Groups[2].Value }
    }
    $portal = @($urls | Where-Object { $_ -match 'eportal/index\.jsp' } | Select-Object -First 1)
    $url = if ($portal.Count) { $portal[0] } else { $null }
    [pscustomobject]@{ Authenticated = $false; Portal = $url }
}

function Connect-Wifi {
    $null = & netsh wlan connect "name=$($script:Profile)" 2>&1 | Out-String
    Write-Log "netsh wlan connect 返回 $LASTEXITCODE"
    for ($i = 0; $i -lt 25; $i++) {
        if (Get-WlanIp) { return $true }
        Start-Sleep -Seconds 1
    }
    $false
}

function Invoke-PortalLogin([string]$PortalUrl) {
    $qs = ''
    if ($PortalUrl -and $PortalUrl.Contains('?')) { $qs = $PortalUrl.Substring($PortalUrl.IndexOf('?') + 1) }
    $body = Invoke-Curl @(
        '-X', 'POST', "$($script:Base)/eportal/InterFace.do?method=login",
        '-H', 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8',
        '--data-urlencode', "userId=$($script:User)",
        '--data-urlencode', "password=$($script:Pass)",
        '--data-urlencode', 'service=',
        '--data-urlencode', "queryString=$qs",
        '--data-urlencode', 'operatorPwd=',
        '--data-urlencode', 'operatorUserId=',
        '--data-urlencode', 'validcode=',
        '--data-urlencode', 'passwordEncrypt=false'
    )
    Write-Log "门户应答：$($body.Trim())"
    if ($body -match '"result"\s*:\s*"success"') { return [pscustomobject]@{ Ok = $true; Msg = '认证成功' } }
    if ($body -match '"message"\s*:\s*"([^"]*)"') { return [pscustomobject]@{ Ok = $false; Msg = $matches[1] } }
    [pscustomobject]@{ Ok = $false; Msg = '门户没有正常应答（也许已经不需要认证，或者认证地址变了）' }
}

function Invoke-PortalLogout {
    $body = Invoke-Curl @('-X', 'POST', "$($script:Base)/eportal/InterFace.do?method=logout",
        '-H', 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8', '--data', '')
    Write-Log "登出应答：$($body.Trim())"
    if ($body -match '"result"\s*:\s*"success"') { return '已登出校园网' }
    if ($body -match '已不在线') { return '本来就不在线' }
    '登出请求已发出（未确认）'
}

function Install-Shortcut {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '校园网WiFi.lnk'
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $s.TargetPath = $PsExe
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Self`""
    $s.WorkingDirectory = $Root
    $s.Description = '连接 HIT-WLAN 并自动完成门户认证'
    $s.Save()
    Report "已在桌面创建「校园网WiFi」快捷方式：`n$lnk"
}

try {
    Read-Config

    switch ($Action) {
        'install' { Install-Shortcut }
        'uninstall' {
            $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '校园网WiFi.lnk'
            if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
            Report '已移除「校园网WiFi」快捷方式。'
        }
        'status' {
            $ip = Get-WlanIp
            if (-not $ip) { Report "无线未连上 $($script:Profile)（或还没拿到 IP）"; break }
            $st = Get-PortalState
            if ($st.Authenticated) { Report "已连接并通过认证`n$($script:Alias) = $ip" }
            elseif ($st.Portal) { Report "已连上无线但没认证`n门户：$($st.Portal)" }
            else { Report "已连上无线但探测不到门户`n$($script:Alias) = $ip" }
        }
        'disconnect' {
            $null = & netsh wlan disconnect 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) { Say '无线已断开' } else { Report '无线断开失败' -Bad }
        }
        'logout' {
            $r = Invoke-PortalLogout
            $null = & netsh wlan disconnect 2>&1 | Out-String
            Say "$r，无线已断开"
        }
        'connect' {
            if (-not (Connect-Wifi)) {
                Report "连不上 $($script:Profile)`n检查范围内有没有这个 SSID、无线网卡是否已启用" -Bad
                break
            }
            Start-Sleep -Seconds 2
            $st = Get-PortalState
            if ($st.Authenticated) { Say "已连接 $($script:Profile)，本来就已通过认证（$($script:Alias) = $(Get-WlanIp)）"; break }
            $r = Invoke-PortalLogin $st.Portal
            if ($r.Ok) {
                Start-Sleep -Seconds 2
                if ((Get-PortalState).Authenticated) { Say "已连接 $($script:Profile) 并通过门户认证 ✓（$($script:Alias) = $(Get-WlanIp)）" }
                else { Report "门户说成功了，但复检没放行`n$($r.Msg)" -Bad }
            } else {
                Report "认证失败：$($r.Msg)" -Bad
            }
        }
    }
} catch {
    Report "出错了：$($_.Exception.Message)" -Bad
}
