#Requires -Version 5.1
<#
    打印机驱动备份与恢复工具 (Printer Migration Tool)
    文件: Printer_Migration.ps1
    入口: Printer_Migration.bat（双击运行）

    设计约束（与需求一致）:
      1. 只使用 Windows 自带组件: PowerShell / PnPUtil / PrintManagement 模块 / printui.dll。
      2. 只导出用户选中的打印机的驱动包，绝不全量导出。
      3. 无法准确定位驱动包时如实说明原因，绝不把"复制成功"当作"安装成功"。
      4. 不覆盖已有打印机、不改默认打印机、不删除其它驱动、不自动重启。
      5. 不使用 /force、不使用任何绕过驱动签名或安全策略的手段。
#>

[CmdletBinding()]
param(
    # 由两个入口 BAT 传入: 01_备份打印机.bat -> Backup, 02_恢复打印机.bat -> Restore
    [ValidateSet('None', 'Backup', 'Restore')]
    [string]$Action = 'None',
    [switch]$SelfTest
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# 兼容 PowerShell 7 测试环境：本工具的目标运行环境是 Windows PowerShell 5.1
if (Test-Path -LiteralPath 'Variable:PSNativeCommandUseErrorActionPreference') {
    $PSNativeCommandUseErrorActionPreference = $false
}

#region ---------------- 全局状态 ----------------

$script:ToolName      = '打印机驱动备份与恢复工具'
$script:ToolVersion   = '1.0.0'
$script:ManifestName  = 'Printers.json'
$script:SummaryName   = '配置清单.txt'
$script:BackupDirName = 'Printer_Backup'

$script:ScriptPath = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($script:ScriptPath)) { $script:ScriptPath = $MyInvocation.MyCommand.Path }
$script:BaseDir = ''
if (-not [string]::IsNullOrWhiteSpace($script:ScriptPath)) { $script:BaseDir = Split-Path -Parent $script:ScriptPath }
if ([string]::IsNullOrWhiteSpace($script:BaseDir)) { $script:BaseDir = (Get-Location).Path }
$script:BackupDir = Join-Path $script:BaseDir $script:BackupDirName

$script:LogFile       = ''
$script:LogEncoding   = New-Object System.Text.UTF8Encoding($false)
$script:PnPUtilPath   = Join-Path $env:SystemRoot 'System32\pnputil.exe'
$script:Rundll32Path  = Join-Path $env:SystemRoot 'System32\rundll32.exe'
$script:IsElevated    = $false
$script:EmptyReads    = 0
$script:InputRedirected = $false
$script:DriverStoreCache = $null
$script:AuthSigAvailable = $null

#endregion

#region ---------------- 日志与输出 ----------------

function Write-LogFile {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($script:LogFile)) { return }
    try { [IO.File]::AppendAllText($script:LogFile, $Text + "`r`n", $script:LogEncoding) } catch { }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP', 'RAW')][string]$Level = 'INFO'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $tag = '信息'
    switch ($Level) {
        'OK'    { $tag = '成功' }
        'WARN'  { $tag = '警告' }
        'ERROR' { $tag = '错误' }
        'STEP'  { $tag = '步骤' }
    }
    $line = "[$stamp] [$tag] $Message"
    switch ($Level) {
        'OK'    { Write-Host $line -ForegroundColor Green }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'STEP'  { Write-Host ''; Write-Host $line -ForegroundColor Cyan }
        'RAW'   { Write-Host $Message }
        default { Write-Host $line }
    }
    Write-LogFile $line
}

function Start-LogFile {
    param([string]$Directory, [string]$Prefix)
    $target = $Directory
    for ($i = 0; $i -lt 2; $i++) {
        try {
            if (-not (Test-Path -LiteralPath $target)) {
                New-Item -ItemType Directory -Force -Path $target -ErrorAction Stop | Out-Null
            }
            $file = Join-Path $target ('{0}_{1}.log' -f $Prefix, (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
            [IO.File]::WriteAllBytes($file, [byte[]](0xEF, 0xBB, 0xBF))
            $script:LogFile = $file
            Write-LogFile ('=' * 70)
            Write-LogFile "开始日志: $($script:ToolName) v$($script:ToolVersion)"
            Write-LogFile "主机: $($env:COMPUTERNAME)  用户: $($env:USERNAME)  时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            Write-LogFile ('=' * 70)
            return $true
        } catch {
            $target = Join-Path $env:TEMP 'Printer_Migration_Logs'
        }
    }
    return $false
}

function Exit-Tool {
    param([int]$Code = 0)
    Write-LogFile ('-' * 70)
    Write-LogFile "结束时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  退出码: $Code"
    if (-not [string]::IsNullOrWhiteSpace($script:LogFile)) {
        Write-Host ''
        Write-Host "日志文件: $($script:LogFile)" -ForegroundColor DarkGray
    }
    exit $Code
}

function Initialize-Console {
    try {
        $script:InputRedirected = [Console]::IsInputRedirected
    } catch {
        $script:InputRedirected = $false
    }
    try {
        $cp = [Console]::OutputEncoding.CodePage
        $cjkCodePages = @(936, 950, 932, 949, 65001, 1200, 1201, 51936, 54936)
        if ($cp -ne 0 -and ($cjkCodePages -notcontains $cp)) {
            $chcp = Join-Path $env:SystemRoot 'System32\chcp.com'
            if (Test-Path -LiteralPath $chcp) { [void](Invoke-Native -FilePath $chcp -Arguments @('65001')) }
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        }
    } catch { }
    try { $global:OutputEncoding = [Console]::OutputEncoding } catch { }
    try { $Host.UI.RawUI.WindowTitle = "$($script:ToolName) v$($script:ToolVersion)" } catch { }
}

function Write-Banner {
    $mode = '（未指定模式）'
    if ($Action -eq 'Backup') { $mode = '【备份】 程序 A - 在旧电脑上使用' }
    elseif ($Action -eq 'Restore') { $mode = '【恢复】 程序 B - 在新电脑上使用' }
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host "        $($script:ToolName)  v$($script:ToolVersion)" -ForegroundColor Cyan
    Write-Host "        $mode" -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host "程序目录: $($script:BaseDir)"
    if ($Action -eq 'Backup') { Write-Host "备份输出: $($script:BackupDir)" }
}

# 统一的输入入口：防止在非交互（管道）环境下死循环
function Read-Input {
    param([string]$Prompt = '')
    $val = $null
    try { $val = Read-Host $Prompt } catch { $val = $null }
    if ($null -eq $val) { $val = '' }
    if ($val -eq '' -and $script:InputRedirected) {
        $script:EmptyReads++
        if ($script:EmptyReads -ge 3) {
            Write-Host ''
            Write-Log '检测到标准输入已结束（非交互运行），程序退出。' 'WARN'
            Exit-Tool 0
        }
    } elseif ($val -ne '') {
        $script:EmptyReads = 0
    }
    return $val
}

function Pause-Continue {
    param([string]$Prompt = '按回车键继续')
    [void](Read-Input $Prompt)
}

#endregion

#region ---------------- 通用工具 ----------------

function Invoke-Native {
    <#  统一调用外部程序：返回输出文本与退出码，不受 ErrorActionPreference 影响 #>
    param([string]$FilePath, [string[]]$Arguments)
    $result = [PSCustomObject]@{ ExitCode = -1; Output = '' }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if (-not (Test-Path -LiteralPath $FilePath)) {
            $result.Output = "找不到可执行文件: $FilePath"
            return $result
        }
        $out = & $FilePath @Arguments 2>&1 | Out-String
        $result.Output = [string]$out
        $result.ExitCode = $LASTEXITCODE
    } catch {
        $result.Output = "调用失败: $($_.Exception.Message)"
        $result.ExitCode = -1
    } finally {
        $ErrorActionPreference = $old
    }
    return $result
}

function Test-IsAdministrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-FreshSessionPolicy {
    <#  返回"新进程在不带 -ExecutionPolicy 参数时会生效的执行策略"。
        优先级: MachinePolicy > UserPolicy > CurrentUser > LocalMachine；全未设置时
        Windows 客户端的默认值是 Restricted（此时 .ps1 文件无法运行）。
        FromGpo=$true 表示由组策略设定（此时 -ExecutionPolicy 参数会被系统忽略）。 #>
    $r = [ordered]@{ Effective = 'Restricted'; FromGpo = $false; Found = $false }
    $map = @{}
    try {
        foreach ($x in @(Get-ExecutionPolicy -List -ErrorAction Stop)) { $map[[string]$x.Scope] = [string]$x.ExecutionPolicy }
    } catch {
        return $r   # 查不到就按最保守处理（需要最小权限回退）
    }
    foreach ($scope in 'MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') {
        if (-not $map.ContainsKey($scope)) { continue }
        $v = [string]$map[$scope]
        if ([string]::IsNullOrWhiteSpace($v) -or $v -eq 'Undefined') { continue }
        $r.Effective = $v
        $r.FromGpo = ($scope -eq 'MachinePolicy' -or $scope -eq 'UserPolicy')
        $r.Found = $true
        break
    }
    return $r
}

function Start-ElevatedSession {
    <#  以管理员身份重新启动本脚本（标准 UAC 请求）。
        不使用 -ExecutionPolicy Bypass: 只有在"本机没有配置过执行策略、处于 Windows
        默认 Restricted"时才退回最小限度的 -ExecutionPolicy RemoteSigned（仅对本进程
        生效，且只允许本地未签名脚本）。若策略由组策略设定，参数会被系统忽略。 #>
    param([string]$Action)
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
    $pol = Get-FreshSessionPolicy
    if ($pol.Found -and $pol.FromGpo -and ($pol.Effective -eq 'Restricted' -or $pol.Effective -eq 'AllSigned')) {
        Write-Log "本机执行策略由组策略设定为 $($pol.Effective)，提权后的新窗口同样无法运行脚本。" 'ERROR'
        Write-Host '提示: 请让 IT 放行脚本执行策略或以签名方式分发本脚本；本工具不会绕过该策略。' -ForegroundColor Yellow
        return $false
    }
    $argList = @('-NoProfile')
    if (-not $pol.Found -or $pol.Effective -eq 'Restricted') {
        Write-Log '本机执行策略为 Windows 默认的 Restricted，提权窗口将使用 -ExecutionPolicy RemoteSigned（仅本进程、只允许本地未签名脚本）。' 'WARN'
        $argList += @('-ExecutionPolicy', 'RemoteSigned')
    }
    $argList += @('-File', ('"{0}"' -f $script:ScriptPath), '-Action', $Action)
    Write-Log '正在请求管理员权限（系统会弹出 UAC 确认窗口）……' 'STEP'
    try {
        Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-Log "管理员权限请求被取消或失败: $($_.Exception.Message)" 'WARN'
        Write-Host '提示: 请在弹出的 UAC 窗口中选择"是"，或右键 Printer_Migration.bat 选择"以管理员身份运行"。' -ForegroundColor Yellow
        return $false
    }
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int]$Bytes)
}

function Test-ValidIPv4 {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($Value.Trim(), [ref]$ip)) { return $false }
    return ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork)
}

function Test-ValidPrinterAddress {
    <#  允许 IPv4 或主机名（TCP/IP 端口两种都支持） #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $v = $Value.Trim()
    if (Test-ValidIPv4 $v) { return $true }
    if ($v -match '^[A-Za-z0-9]([A-Za-z0-9\-_]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9\-_]{0,61}[A-Za-z0-9])?)*$') { return $true }
    return $false
}

function Test-AddressWorthWarning {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $v = $Value.Trim()
    if ($v -match '^127\.') { return '地址是回环地址(127.x)，无法用于网络打印。' }
    if ($v -match '^169\.254\.') { return '地址是自动专用地址(169.254.x)，通常表示打印机未获取到有效 IP。' }
    if ($v -match '^0\.') { return '地址是无效地址(0.x)。' }
    return ''
}

function ConvertTo-Selection {
    <#  解析多选输入：支持 "1 3 5" / "1,3,5" / "2-4" / "all" / "*"；非法输入返回 $null #>
    param([string]$Text, [int]$Max)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    if ($t -eq '*' -or $t -match '^(?i)all$' -or $t -eq '全部') {
        $all = New-Object System.Collections.Generic.List[int]
        for ($i = 1; $i -le $Max; $i++) { $all.Add($i) }
        return $all.ToArray()
    }
    $set = New-Object System.Collections.Generic.List[int]
    $parts = $t -split '[,，、;；\s]+'
    foreach ($p in $parts) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($p -match '^(\d+)\s*-\s*(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $tmp = $a; $a = $b; $b = $tmp }
            for ($i = $a; $i -le $b; $i++) { $set.Add($i) }
            continue
        }
        if ($p -match '^\d+$') { $set.Add([int]$p); continue }
        return $null
    }
    if ($set.Count -eq 0) { return $null }
    $uniq = @($set | Sort-Object -Unique)
    foreach ($n in $uniq) {
        if ($n -lt 1 -or $n -gt $Max) { return $null }
    }
    return $uniq
}

function Get-OSArchitecture {
    <#  返回操作系统架构: x64 / ARM64 / x86 #>
    $a = ''
    try { $a = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432', 'Process') } catch { $a = '' }
    if ([string]::IsNullOrWhiteSpace($a)) {
        try { $a = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Process') } catch { $a = '' }
    }
    if ([string]::IsNullOrWhiteSpace($a)) {
        if ([Environment]::Is64BitOperatingSystem) { return 'x64' }
        return 'x86'
    }
    switch ($a.ToUpperInvariant()) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'ARM64' }
        'X86'   { return 'x86' }
        default {
            if ([Environment]::Is64BitOperatingSystem) { return 'x64' }
            return 'x86'
        }
    }
}

function Get-OSInfo {
    $o = [ordered]@{
        Caption    = ''
        Version    = ''
        Build      = ''
        Architecture = ''
        Is64Bit    = $false
        PSVersion  = ''
    }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $o.Caption = [string]$os.Caption
        $o.Version = [string]$os.Version
        $o.Build = [string]$os.BuildNumber
    } catch {
        try { $o.Version = [string][Environment]::OSVersion.Version } catch { }
    }
    $o.Architecture = Get-OSArchitecture
    $o.Is64Bit = [bool][Environment]::Is64BitOperatingSystem
    try { $o.PSVersion = $PSVersionTable.PSVersion.ToString() } catch { }
    return [PSCustomObject]$o
}

#endregion

#region ---------------- 打印机与端口枚举 ----------------

function Get-PrinterPortTables {
    <#  缓存端口信息（本地端口 + TCP/IP 端口） #>
    $portMap = @{}
    try {
        foreach ($p in @(Get-PrinterPort -ErrorAction SilentlyContinue)) {
            $n = [string]$p.Name
            if (-not [string]::IsNullOrWhiteSpace($n)) { $portMap[$n] = $p }
        }
    } catch { }
    $tcpMap = @{}
    try {
        foreach ($p in @(Get-CimInstance -ClassName Win32_TCPIPPrinterPort -ErrorAction SilentlyContinue)) {
            $n = [string]$p.Name
            if (-not [string]::IsNullOrWhiteSpace($n)) { $tcpMap[$n] = $p }
        }
    } catch { }
    return @{ Ports = $portMap; Tcp = $tcpMap }
}

function Resolve-ConnectionType {
    <#  根据端口名/服务器名判断连接类型并提取地址信息 #>
    param(
        [string]$PortName,
        [string]$ServerName,
        [string]$ShareName,
        [bool]$Network,
        [bool]$Local,
        $PortInfo,
        $TcpPortInfo
    )
    $r = [ordered]@{
        Kind         = '本地打印机(本地端口)'
        IsUsb        = $false
        IsNetwork    = $false
        IsShared     = $false
        SharePath    = ''
        ServerName   = ''
        Address      = ''
        PortNumber   = 0
        Protocol     = ''
        LprQueueName = ''
        Note         = ''
    }
    $pn = ''
    if (-not [string]::IsNullOrWhiteSpace($PortName)) { $pn = $PortName.Trim() }

    if ($pn -match '^\\\\') {
        $r.Kind = '共享打印机(网络连接)'
        $r.IsShared = $true
        $r.IsNetwork = $true
        $r.SharePath = $pn
    } elseif (-not [string]::IsNullOrWhiteSpace($ServerName)) {
        $r.Kind = '共享打印机(网络连接)'
        $r.IsShared = $true
        $r.IsNetwork = $true
        $r.ServerName = $ServerName
        if (-not [string]::IsNullOrWhiteSpace($ShareName)) {
            $r.SharePath = '\\' + $ServerName + '\' + $ShareName
        } else {
            $r.SharePath = '\\' + $ServerName
        }
    } elseif ($pn -match '^(usb|dot4)') {
        $r.Kind = 'USB 本地打印机'
        $r.IsUsb = $true
    } elseif ($pn -match '^(lpt|com)\d') {
        $r.Kind = '本地打印机(并口/串口)'
    } elseif ($pn -match '^wsd') {
        $r.Kind = 'WSD 网络打印机'
        $r.IsNetwork = $true
        $r.Note = 'WSD 端口没有固定 IP，恢复时需重新搜索设备。'
    } elseif (($null -ne $TcpPortInfo) -or $pn -match '^ip_' -or (Test-ValidIPv4 $pn) -or $pn -match '^https?://') {
        $r.Kind = 'TCP/IP 网络打印机'
        $r.IsNetwork = $true
    } elseif ($pn -match '^(nul:|file:|portprompt:|shrfa|fax:)' -or $pn -match 'virtual|microsoft|pdf|xps|onenote') {
        $r.Kind = '本地/虚拟打印机'
    }

    if ($null -ne $TcpPortInfo) {
        if ($TcpPortInfo.PSObject.Properties['HostAddress'] -and $TcpPortInfo.HostAddress) { $r.Address = [string]$TcpPortInfo.HostAddress }
        if ($TcpPortInfo.PSObject.Properties['PortNumber'] -and $TcpPortInfo.PortNumber) { $r.PortNumber = [int]$TcpPortInfo.PortNumber }
        if ($TcpPortInfo.PSObject.Properties['Protocol'] -and $null -ne $TcpPortInfo.Protocol) {
            if ([int]$TcpPortInfo.Protocol -eq 2) { $r.Protocol = 'LPR' } else { $r.Protocol = 'RAW' }
        }
        # LPR 端口必须知道队列名(Queue)，否则恢复时不能自动建端口
        if ($TcpPortInfo.PSObject.Properties['Queue'] -and $TcpPortInfo.Queue) { $r.LprQueueName = [string]$TcpPortInfo.Queue }
    }
    if ($null -ne $PortInfo) {
        if ([string]::IsNullOrWhiteSpace($r.Address) -and $PortInfo.PSObject.Properties['PrinterHostAddress'] -and $PortInfo.PrinterHostAddress) {
            $r.Address = [string]$PortInfo.PrinterHostAddress
        }
        if ($r.PortNumber -eq 0 -and $PortInfo.PSObject.Properties['PortNumber'] -and $PortInfo.PortNumber) {
            $r.PortNumber = [int]$PortInfo.PortNumber
        }
        if ([string]::IsNullOrWhiteSpace($r.Protocol) -and $PortInfo.PSObject.Properties['Protocol'] -and $PortInfo.Protocol) {
            $r.Protocol = [string]$PortInfo.Protocol
        }
        if ([string]::IsNullOrWhiteSpace($r.LprQueueName) -and $PortInfo.PSObject.Properties['LprQueueName'] -and $PortInfo.LprQueueName) {
            $r.LprQueueName = [string]$PortInfo.LprQueueName
        }
        if ([string]::IsNullOrWhiteSpace($r.LprQueueName) -and $PortInfo.PSObject.Properties['Queue'] -and $PortInfo.Queue) {
            $r.LprQueueName = [string]$PortInfo.Queue
        }
    }
    if ($r.Protocol -match '^(?i)lpr' -and [string]::IsNullOrWhiteSpace($r.LprQueueName)) {
        $r.Note = '备份时未能取得 LPR 队列名，恢复时无法自动创建该端口。'
    }
    if ([string]::IsNullOrWhiteSpace($r.Address) -and (Test-ValidIPv4 $pn)) { $r.Address = $pn }
    if ([string]::IsNullOrWhiteSpace($r.Address) -and $pn -match '^IP_(.+)$') { $r.Address = $Matches[1].Trim() }
    return $r
}

function New-PrinterItem {
    param(
        [string]$Name,
        [string]$DriverName,
        [string]$PortName,
        [string]$ShareName,
        $Cim,
        $Tables
    )
    $serverName = ''
    $network = $false
    $isLocal = $true
    $isDefault = $false
    $status = ''
    $comment = ''
    $location = ''
    $cimPort = ''
    if ($null -ne $Cim) {
        if ($Cim.PSObject.Properties['ServerName'] -and $Cim.ServerName) { $serverName = [string]$Cim.ServerName }
        if ($Cim.PSObject.Properties['ShareName'] -and [string]::IsNullOrWhiteSpace($ShareName) -and $Cim.ShareName) { $ShareName = [string]$Cim.ShareName }
        if ($Cim.PSObject.Properties['Network']) { $network = [bool]$Cim.Network }
        if ($Cim.PSObject.Properties['Local']) { $isLocal = [bool]$Cim.Local }
        if ($Cim.PSObject.Properties['Default']) { $isDefault = [bool]$Cim.Default }
        if ($Cim.PSObject.Properties['PrinterStatus'] -and $null -ne $Cim.PrinterStatus) { $status = [string]$Cim.PrinterStatus }
        if ($Cim.PSObject.Properties['Comment'] -and $Cim.Comment) { $comment = [string]$Cim.Comment }
        if ($Cim.PSObject.Properties['Location'] -and $Cim.Location) { $location = [string]$Cim.Location }
        if ($Cim.PSObject.Properties['PortName'] -and $Cim.PortName) { $cimPort = [string]$Cim.PortName }
    }
    if ([string]::IsNullOrWhiteSpace($PortName) -and -not [string]::IsNullOrWhiteSpace($cimPort)) { $PortName = $cimPort }

    $portInfo = $null
    if (-not [string]::IsNullOrWhiteSpace($PortName) -and $Tables.Ports.ContainsKey($PortName)) { $portInfo = $Tables.Ports[$PortName] }
    $tcpInfo = $null
    if (-not [string]::IsNullOrWhiteSpace($PortName) -and $Tables.Tcp.ContainsKey($PortName)) { $tcpInfo = $Tables.Tcp[$PortName] }

    $conn = Resolve-ConnectionType -PortName $PortName -ServerName $serverName -ShareName $ShareName `
        -Network $network -Local $isLocal -PortInfo $portInfo -TcpPortInfo $tcpInfo

    return [PSCustomObject][ordered]@{
        Index          = 0
        Name           = $Name
        DriverName     = $DriverName
        PortName       = $PortName
        ShareName      = $ShareName
        ServerName     = $conn.ServerName
        ConnectionType = $conn.Kind
        IsUsb          = $conn.IsUsb
        IsNetwork      = $conn.IsNetwork
        IsShared       = $conn.IsShared
        SharePath      = $conn.SharePath
        Address        = $conn.Address
        PortNumber     = $conn.PortNumber
        Protocol       = $conn.Protocol
        LprQueueName   = $conn.LprQueueName
        Note           = $conn.Note
        Status         = $status
        Comment        = $comment
        Location       = $location
        IsDefault      = $isDefault
    }
}

function Get-PrinterInventory {
    <#  枚举本机打印机：优先 Get-Printer，失败时回退到 WMI Win32_Printer #>
    $tables = Get-PrinterPortTables
    $cimMap = @{}
    try {
        foreach ($c in @(Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue)) {
            $n = [string]$c.Name
            if (-not [string]::IsNullOrWhiteSpace($n)) { $cimMap[$n] = $c }
        }
    } catch { }

    $baseList = @()
    $usedWmi = $false
    try {
        Import-Module PrintManagement -ErrorAction SilentlyContinue
        $baseList = @(Get-Printer -ErrorAction Stop)
    } catch {
        $usedWmi = $true
    }
    if ($baseList.Count -eq 0 -and $cimMap.Count -gt 0) { $usedWmi = $true }

    $items = New-Object System.Collections.Generic.List[object]
    if (-not $usedWmi) {
        foreach ($p in $baseList) {
            $name = [string]$p.Name
            $cim = $null
            if ($cimMap.ContainsKey($name)) { $cim = $cimMap[$name] }
            $shareName = ''
            if ($p.PSObject.Properties['ShareName'] -and $p.ShareName) { $shareName = [string]$p.ShareName }
            $items.Add((New-PrinterItem -Name $name -DriverName ([string]$p.DriverName) -PortName ([string]$p.PortName) `
                        -ShareName $shareName -Cim $cim -Tables $tables))
        }
    } else {
        Write-Log 'PrintManagement 模块不可用，已改用 WMI (Win32_Printer) 读取打印机列表。' 'WARN'
        foreach ($c in @($cimMap.Values)) {
            $items.Add((New-PrinterItem -Name ([string]$c.Name) -DriverName ([string]$c.DriverName) -PortName ([string]$c.PortName) `
                        -ShareName ([string]$c.ShareName) -Cim $c -Tables $tables))
        }
    }

    $sorted = @($items | Sort-Object -Property Name)
    $idx = 1
    foreach ($it in $sorted) {
        $it.Index = $idx
        $idx++
    }
    return $sorted
}

function Show-PrinterList {
    param($Printers, [string]$Title = '本机已安装的打印机')
    Write-Host ''
    Write-Host ("-" * 66) -ForegroundColor DarkGray
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ("-" * 66) -ForegroundColor DarkGray
    if (@($Printers).Count -eq 0) {
        Write-Host ' (没有检测到任何打印机)' -ForegroundColor Yellow
        return
    }
    foreach ($p in $Printers) {
        Write-Host ("[{0}] {1}" -f $p.Index, $p.Name) -ForegroundColor White
        $drv = $p.DriverName
        if ([string]::IsNullOrWhiteSpace($drv)) { $drv = '(无驱动信息)' }
        Write-Host ("    驱动: {0}" -f $drv) -ForegroundColor Gray
        $port = $p.PortName
        if ([string]::IsNullOrWhiteSpace($port)) { $port = '(无端口信息)' }
        $line = "    端口: $port    类型: $($p.ConnectionType)"
        Write-Host $line -ForegroundColor Gray
        $extra = @()
        if (-not [string]::IsNullOrWhiteSpace($p.Address)) { $extra += "IP/主机: $($p.Address)" }
        if (-not [string]::IsNullOrWhiteSpace($p.SharePath)) { $extra += "共享路径: $($p.SharePath)" }
        if ($p.IsDefault) { $extra += '默认打印机' }
        if ($extra.Count -gt 0) { Write-Host ("    " + ($extra -join '  |  ')) -ForegroundColor DarkGray }
    }
    Write-Host ("-" * 66) -ForegroundColor DarkGray
}

#endregion

#region ---------------- 驱动包定位与导出 ----------------

function Get-DriverStorePackages {
    <#  读取 pnputil /enum-drivers 的第三方驱动包列表。
        不依赖本地化文本标签：只提取记录中的 *.inf 记号（oemNN.inf = 已发布名称）。 #>
    param([switch]$Force)
    if ($null -ne $script:DriverStoreCache -and -not $Force) { return $script:DriverStoreCache }
    $result = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $script:PnPUtilPath)) {
        Write-Log "找不到 pnputil.exe，无法枚举第三方驱动包。" 'WARN'
        $script:DriverStoreCache = @()
        return $script:DriverStoreCache
    }
    $r = Invoke-Native -FilePath $script:PnPUtilPath -Arguments @('/enum-drivers')
    $text = [string]$r.Output
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
        Write-Log "pnputil /enum-drivers 执行失败（退出码 $($r.ExitCode)），可能需要管理员权限。" 'WARN'
        Write-LogFile $text
        $script:DriverStoreCache = @()
        return $script:DriverStoreCache
    }
    $blocks = $text -split '\r?\n\s*\r?\n'
    foreach ($b in $blocks) {
        $infTokens = @([regex]::Matches($b, '[A-Za-z0-9_\-\.]+\.inf', 'IgnoreCase') | ForEach-Object { $_.Value } | Select-Object -Unique)
        if ($infTokens.Count -eq 0) { continue }
        $published = @($infTokens | Where-Object { $_ -match '^oem\d+\.inf$' })
        if ($published.Count -eq 0) { continue }
        $original = ''
        foreach ($t in $infTokens) {
            if ($t -notmatch '^oem\d+\.inf$') { $original = $t; break }
        }
        $ver = ''
        $date = ''
        $m = [regex]::Match($b, '(\d{2}/\d{2}/\d{4})\s+(\S+)')
        if ($m.Success) { $date = $m.Groups[1].Value; $ver = $m.Groups[2].Value }
        $result.Add([PSCustomObject]@{
            PublishedName = [string]$published[0]
            OriginalName  = $original
            DriverDate    = $date
            DriverVersion = $ver
        })
    }
    # 注意: Windows PowerShell 5.1 对 List[object] 直接使用 @() 会抛 "Argument types do not match"，必须转成数组
    $script:DriverStoreCache = $result.ToArray()
    return $script:DriverStoreCache
}

function Test-DriverVersionMatch {
    <#  比较两个驱动版本字符串，返回 'match' / 'mismatch' / 'unknown'。
        只做字符串规范化比较（pnputil 与 INF 的 DriverVer 版本部分格式一致）。 #>
    param([string]$Expected, [string]$Actual)
    $e = ([string]$Expected).Trim()
    $a = ([string]$Actual).Trim()
    if ([string]::IsNullOrWhiteSpace($e) -or [string]::IsNullOrWhiteSpace($a)) { return 'unknown' }
    if ($e -ieq $a) { return 'match' }
    $en = ($e -replace '\s', '')
    $an = ($a -replace '\s', '')
    if ($en -ieq $an) { return 'match' }
    return 'mismatch'
}

function Resolve-DriverPackageName {
    <#  把一个 INF 文件名解析为可导出的驱动包（oemNN.inf）。
        身份校验：既要求原始 INF 名称匹配，也要求驱动版本与打印机实际使用的 INF 一致；
        多个候选无法唯一确认时禁止自动导出（返回 '存在歧义' / '身份不符'）。
        -Packages 仅供自检注入，默认读取系统驱动库。 #>
    param(
        [string]$InfFileName,
        [string]$InfPath,
        [string]$ExpectedVersion = '',
        [string]$ExpectedDate = '',
        $Packages = $null
    )
    $r = [ordered]@{
        PublishedName = ''
        OriginalName  = $InfFileName
        IsExportable  = $false
        Status        = '无法定位'
        Message       = ''
        IdentityCheck = ''
        Candidates    = @()
    }
    if ([string]::IsNullOrWhiteSpace($InfFileName)) {
        $r.Message = '没有 INF 文件名信息。'
        return $r
    }
    $pkgs = @()
    if ($null -ne $Packages) { $pkgs = @($Packages) } else { $pkgs = @(Get-DriverStorePackages) }
    $expVer = ([string]$ExpectedVersion).Trim()
    $expDate = ([string]$ExpectedDate).Trim()

    # ---- 情况一: InfPath 本身就是已发布的 oemNN.inf，身份唯一 ----
    if ($InfFileName -match '^oem\d+\.inf$') {
        $hit = @($pkgs | Where-Object { [string]$_.PublishedName -ieq $InfFileName })
        if ($hit.Count -gt 1) {
            $r.Status = '存在歧义'
            $r.Candidates = @($hit | ForEach-Object { [string]$_.PublishedName })
            $r.Message = "系统驱动库中出现了重复的已发布名称 $InfFileName，无法唯一确认，已禁止自动导出。"
            return $r
        }
        if ($hit.Count -eq 1) {
            $r.PublishedName = [string]$hit[0].PublishedName
            $r.OriginalName = [string]$hit[0].OriginalName
            $r.IsExportable = $true
            $r.Status = '可导出'
            $vchk = Test-DriverVersionMatch -Expected $expVer -Actual ([string]$hit[0].DriverVersion)
            $r.IdentityCheck = "已发布驱动包名精确匹配 ($InfFileName)"
            if ($vchk -eq 'match') {
                $r.IdentityCheck += "，版本核对一致 ($expVer)"
            } elseif ($vchk -eq 'mismatch') {
                $r.IdentityCheck += "，但驱动库版本($($hit[0].DriverVersion))与驱动 INF 版本($expVer)不一致，已记录"
            }
            $r.Message = "已匹配到系统驱动包 $($hit[0].PublishedName)（原始 INF: $($hit[0].OriginalName)）。$($r.IdentityCheck)"
            return $r
        }
        $r.Status = '无法定位'
        $r.Message = "系统驱动库中没有找到 $InfFileName，无法确认可导出的驱动包。"
        return $r
    }

    # ---- 情况二: 按原始 INF 名称匹配 ----
    $hit = @($pkgs | Where-Object { [string]$_.OriginalName -ieq $InfFileName })
    if ($hit.Count -eq 0) {
        if ($InfFileName -match '^(prnms|ntprint|prnca|ntprint4|sti|usbprint|print)') {
            $r.Status = '系统内置'
            $r.Message = "该驱动属于 Windows 内置驱动 ($InfFileName)，随系统自带、无法也不需要单独导出。"
            return $r
        }
        if (-not [string]::IsNullOrWhiteSpace($InfPath) -and $InfPath -match 'FileRepository') {
            $r.Status = '系统内置'
            $r.Message = "该驱动未出现在 pnputil 第三方驱动列表中，判定为系统自带组件 ($InfFileName)，无需备份。"
            return $r
        }
        $r.Status = '无法定位'
        $r.Message = "未能把 $InfFileName 匹配到任何可导出的第三方驱动包。"
        return $r
    }

    $inboxHint = ''
    if ($InfFileName -match '^(prnms|ntprint|prnca|ntprint4|sti|usbprint)') {
        $inboxHint = ' 提示: 该驱动 Windows 通常也自带一份，新电脑上可能无需安装。'
    }
    $candText = (@($hit | ForEach-Object { "$($_.PublishedName)($($_.DriverVersion))" }) -join ', ')

    if ($hit.Count -eq 1) {
        $pick = $hit[0]
        $vchk = Test-DriverVersionMatch -Expected $expVer -Actual ([string]$pick.DriverVersion)
        if ($vchk -eq 'mismatch') {
            $r.Status = '身份不符'
            $r.Candidates = @([string]$pick.PublishedName)
            $r.Message = "驱动库里唯一同名候选 $($pick.PublishedName) 的版本($($pick.DriverVersion))与打印机实际驱动 INF 的版本($expVer)不一致，已禁止自动导出，避免备错驱动。"
            return $r
        }
        $r.PublishedName = [string]$pick.PublishedName
        $r.OriginalName = [string]$pick.OriginalName
        $r.IsExportable = $true
        $r.Status = '可导出'
        if ($vchk -eq 'match') {
            $r.IdentityCheck = "原始 INF 名称唯一匹配，版本核对一致 ($expVer)"
        } else {
            $r.IdentityCheck = "原始 INF 名称唯一匹配（未能核对版本: 备份侧或驱动库侧缺少版本信息）"
        }
        $r.Message = "已按原始 INF 名称匹配到驱动包 $($pick.PublishedName)。$($r.IdentityCheck)。$inboxHint"
        return $r
    }

    # 多个同名候选: 必须靠版本唯一确认
    if ([string]::IsNullOrWhiteSpace($expVer)) {
        $r.Status = '存在歧义'
        $r.Candidates = @($hit | ForEach-Object { [string]$_.PublishedName })
        $r.Message = "系统驱动库中有 $($hit.Count) 个同名原始 INF ($InfFileName) 的驱动包（$candText），且无法取得打印机实际驱动的版本用于核对，已禁止自动导出。"
        return $r
    }
    $byVer = @($hit | Where-Object { (Test-DriverVersionMatch -Expected $expVer -Actual ([string]$_.DriverVersion)) -eq 'match' })
    if ($byVer.Count -eq 1) {
        $pick = $byVer[0]
        $r.PublishedName = [string]$pick.PublishedName
        $r.OriginalName = [string]$pick.OriginalName
        $r.IsExportable = $true
        $r.Status = '可导出'
        $r.IdentityCheck = "同名候选 $($hit.Count) 个，已用驱动版本唯一确认 ($expVer -> $($pick.PublishedName))"
        $r.Message = "已通过版本核对唯一确认驱动包 $($pick.PublishedName)（候选: $candText）。$inboxHint"
        return $r
    }
    if ($byVer.Count -eq 0) {
        $r.Status = '身份不符'
        $r.Candidates = @($hit | ForEach-Object { [string]$_.PublishedName })
        $r.Message = "有 $($hit.Count) 个同名原始 INF ($InfFileName) 的驱动包（$candText），但没有一个版本与打印机实际驱动 INF 的版本($expVer)一致，已禁止自动导出。"
        return $r
    }
    $r.Status = '存在歧义'
    $r.Candidates = @($byVer | ForEach-Object { [string]$_.PublishedName })
    $r.Message = "有 $($byVer.Count) 个同名同版本($expVer)的驱动包（$candText），无法唯一确认身份，已禁止自动导出；如确需备份，请手动执行 pnputil /export-driver <oemNN.inf> <目标目录>。"
    return $r
}

function Get-PrinterDriverDetail {
    <#  针对一台打印机，定位其打印驱动与可导出的 INF 包 #>
    param([string]$DriverName)
    $d = [PSCustomObject][ordered]@{
        ModelName        = $DriverName
        Environment      = ''
        InfPath          = ''
        InfFileName      = ''
        Version          = ''
        Provider         = ''
        DriverFilePath   = ''
        PublishedName    = ''
        OriginalName     = ''
        IsExportable     = $false
        Status           = '无法定位'
        Message          = ''
        ExpectedVersion  = ''
        ExpectedDate     = ''
        IdentityCheck    = ''
        Candidates       = @()
    }
    $baseName = ($DriverName -split ',')[0].Trim()
    if ([string]::IsNullOrWhiteSpace($baseName)) {
        $d.Message = '打印机没有记录驱动名称。'
        return $d
    }

    $match = @()
    try {
        $all = @(Get-PrinterDriver -ErrorAction SilentlyContinue)
        $match = @($all | Where-Object { [string]$_.Name -eq $DriverName })
        if ($match.Count -eq 0) {
            $match = @($all | Where-Object { ([string]$_.Name -split ',')[0].Trim() -eq $baseName })
        }
    } catch { }
    if ($match.Count -gt 0) {
        $pick = $match[0]
        if ([Environment]::Is64BitOperatingSystem) {
            $pref = @($match | Where-Object { [string]$_.PrinterEnvironment -eq 'Windows x64' })
            if ($pref.Count -gt 0) { $pick = $pref[0] }
        }
        $d.ModelName = [string]$pick.Name
        $d.Environment = [string]$pick.PrinterEnvironment
        $d.InfPath = [string]$pick.InfPath
        $d.Provider = [string]$pick.Manufacturer
    }

    if ([string]::IsNullOrWhiteSpace($d.InfPath)) {
        try {
            $cim = @(Get-CimInstance -ClassName Win32_PrinterDriver -ErrorAction SilentlyContinue |
                     Where-Object { ([string]$_.Name -split ',')[0].Trim() -eq $baseName })
            if ($cim.Count -gt 0) {
                $pick2 = $cim[0]
                if ([Environment]::Is64BitOperatingSystem) {
                    $pref2 = @($cim | Where-Object { [string]$_.SupportedPlatform -eq 'Windows x64' })
                    if ($pref2.Count -gt 0) { $pick2 = $pref2[0] }
                }
                if ([string]::IsNullOrWhiteSpace($d.Environment)) { $d.Environment = [string]$pick2.SupportedPlatform }
                $d.DriverFilePath = [string]$pick2.DriverPath
                if ($d.DriverFilePath -match '\.inf$') { $d.InfPath = $d.DriverFilePath }
                if (-not [string]::IsNullOrWhiteSpace([string]$pick2.InfName)) { $d.InfFileName = [string]$pick2.InfName }
            }
        } catch { }
    }

    if (-not [string]::IsNullOrWhiteSpace($d.InfPath)) {
        if ([string]::IsNullOrWhiteSpace($d.InfFileName)) { $d.InfFileName = Split-Path -Leaf $d.InfPath }
        # 用打印机实际使用的 INF 里的 DriverVer 作为身份基准，用于和驱动库候选包核对
        $realVer = [PSCustomObject]@{ DriverDate = ''; Version = '' }
        if (Test-Path -LiteralPath $d.InfPath) { $realVer = Get-InfDriverVersion -InfPath $d.InfPath }
        $d.ExpectedVersion = [string]$realVer.Version
        $d.ExpectedDate = [string]$realVer.DriverDate
        $res = Resolve-DriverPackageName -InfFileName $d.InfFileName -InfPath $d.InfPath `
                                         -ExpectedVersion $d.ExpectedVersion -ExpectedDate $d.ExpectedDate
        $d.PublishedName = $res.PublishedName
        $d.OriginalName = $res.OriginalName
        $d.IsExportable = [bool]$res.IsExportable
        $d.Status = $res.Status
        $d.Message = $res.Message
        $d.IdentityCheck = [string]$res.IdentityCheck
        $d.Candidates = @($res.Candidates)
        if (-not [string]::IsNullOrWhiteSpace($d.ExpectedVersion) -and -not $d.IsExportable -and $d.Status -ne '系统内置') {
            $d.Message = $d.Message + " (打印机实际驱动 INF 版本: $($d.ExpectedVersion))"
        }
    } else {
        $d.Status = '无法定位'
        if (-not [string]::IsNullOrWhiteSpace($d.DriverFilePath)) {
            $d.Message = "系统中没有该驱动的 INF 记录（仅找到驱动文件 $($d.DriverFilePath)），可能是厂商安装程序直接注册的旧式打印驱动，无法用 pnputil 导出。"
        } else {
            $d.Message = '系统中没有找到该驱动对应的 INF 文件或驱动文件。'
        }
    }
    return $d
}

function Export-DriverPackage {
    <#  用 pnputil /export-driver 导出指定的第三方驱动包到"暂存目录"，
        并在导出后核对 INF 原始名与驱动版本，确认身份一致才算成功。
        注意: 这里绝不删除已有备份目录，替换动作由 Publish-StagedDriverPackage 在验证通过后执行。 #>
    param(
        [string]$PublishedName,
        [string]$StagingRoot,
        [string]$ExpectedOriginalName = '',
        [string]$ExpectedVersion = ''
    )
    $res = [ordered]@{
        Ok             = $false
        StagingDir     = ''
        InfFiles       = @()
        FileCount      = 0
        TotalBytes     = 0
        Output         = ''
        Message        = ''
        IdentityNote   = ''
    }
    if ([string]::IsNullOrWhiteSpace($PublishedName)) {
        $res.Message = '没有可导出的驱动包名称。'
        return $res
    }
    $safe = $PublishedName -replace '[\\/:*?"<>|]', '_'
    $dest = Join-Path $StagingRoot ([IO.Path]::GetFileNameWithoutExtension($safe))
    try {
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction Stop }
        New-Item -ItemType Directory -Force -Path $dest -ErrorAction Stop | Out-Null
    } catch {
        $res.Message = "创建暂存导出目录失败: $($_.Exception.Message)"
        return $res
    }

    $n = Invoke-Native -FilePath $script:PnPUtilPath -Arguments @('/export-driver', $PublishedName, $dest)
    $res.Output = [string]$n.Output
    Write-LogFile "--- pnputil /export-driver $PublishedName ---"
    Write-LogFile $res.Output
    Write-LogFile "退出码: $($n.ExitCode)"

    $files = @(Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue)
    $infs = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue)
    if ($n.ExitCode -eq 0 -and $files.Count -gt 0 -and $infs.Count -gt 0) {
        # 导出后身份复核: 必须有期望原始名的 INF；若已知版本，版本必须一致
        $idOk = $true
        $idNotes = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrWhiteSpace($ExpectedOriginalName)) {
            $nameHit = @($infs | Where-Object { $_.Name -ieq $ExpectedOriginalName })
            if ($nameHit.Count -ge 1) {
                $idNotes.Add("INF 原始名核对一致 ($ExpectedOriginalName)")
            } else {
                $idOk = $false
                $idNotes.Add("导出内容里没有期望的 INF ($ExpectedOriginalName)，实际: $((@($infs.Name)) -join ', ')")
            }
        }
        $verInf = $null
        if ($idOk -and -not [string]::IsNullOrWhiteSpace($ExpectedVersion)) {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedOriginalName)) {
                $verInf = @($infs | Where-Object { $_.Name -ieq $ExpectedOriginalName })[0]
            } else {
                $verInf = $infs[0]
            }
            $v = Get-InfDriverVersion -InfPath $verInf.FullName
            $vchk = Test-DriverVersionMatch -Expected $ExpectedVersion -Actual ([string]$v.Version)
            if ($vchk -eq 'match') {
                $idNotes.Add("驱动版本核对一致 ($ExpectedVersion)")
            } elseif ($vchk -eq 'mismatch') {
                $idOk = $false
                $idNotes.Add("驱动版本不一致: 期望 $ExpectedVersion，实际 $($v.Version)")
            } else {
                $idNotes.Add("无法核对驱动版本（期望 $ExpectedVersion，实际 '$($v.Version)'）")
            }
        }
        $res.IdentityNote = ($idNotes -join '；')
        if (-not $idOk) {
            $res.Message = "导出内容身份复核失败: $($res.IdentityNote)"
            Write-LogFile "身份复核失败，已删除暂存目录: $dest"
            Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
            return $res
        }
        $res.Ok = $true
        $res.StagingDir = $dest
        $res.InfFiles = @($infs.FullName)
        $res.FileCount = $files.Count
        $res.TotalBytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
        $res.Message = "已导出 $($files.Count) 个文件（$((Format-Size $res.TotalBytes))），含 INF: $((@($infs.Name)) -join ', ')"
        if (-not [string]::IsNullOrWhiteSpace($res.IdentityNote)) { $res.Message += "；$($res.IdentityNote)" }
    } else {
        $res.Message = "pnputil 导出失败（退出码 $($n.ExitCode)），目录中文件数: $($files.Count)，INF 数: $($infs.Count)。"
        if ($files.Count -eq 0) {
            Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return $res
}

function Publish-StagedDriverPackage {
    <#  把已验证的暂存驱动包替换到备份目录。
        先验证、再改名旧目录、再就位；任何一步失败都回滚，绝不提前删除原有有效备份。 #>
    param([string]$StagingDir, [string]$TargetDir)
    $r = [ordered]@{ Ok = $false; Replaced = $false; Message = '' }
    if ([string]::IsNullOrWhiteSpace($StagingDir) -or -not (Test-Path -LiteralPath $StagingDir)) {
        $r.Message = "暂存目录不存在: $StagingDir"
        return $r
    }
    $sInfs = @(Get-ChildItem -LiteralPath $StagingDir -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue)
    $sFiles = @(Get-ChildItem -LiteralPath $StagingDir -Recurse -File -ErrorAction SilentlyContinue)
    if ($sInfs.Count -eq 0 -or $sFiles.Count -eq 0) {
        $r.Message = "暂存驱动包不完整（文件 $($sFiles.Count) 个，INF $($sInfs.Count) 个），未替换原有备份。"
        return $r
    }
    $stamp = Get-Date -Format 'yyyyMMddHHmmssfff'
    $backupOld = ''
    try {
        if (Test-Path -LiteralPath $TargetDir) {
            $backupOld = "$TargetDir.old_$stamp"
            Rename-Item -LiteralPath $TargetDir -NewName ([IO.Path]::GetFileName($backupOld)) -ErrorAction Stop
        }
        Move-Item -LiteralPath $StagingDir -Destination $TargetDir -ErrorAction Stop
        $tInfs = @(Get-ChildItem -LiteralPath $TargetDir -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue)
        if ($tInfs.Count -eq 0) {
            throw "替换后目标目录里没有 INF 文件"
        }
        $r.Ok = $true
        $r.Replaced = -not [string]::IsNullOrWhiteSpace($backupOld)
        if ($r.Replaced) {
            Remove-Item -LiteralPath $backupOld -Recurse -Force -ErrorAction SilentlyContinue
            $r.Message = "已用新导出的驱动包替换原有备份（旧目录已删除）。"
        } else {
            $r.Message = "已写入驱动包。"
        }
        return $r
    } catch {
        # 回滚: 恢复旧目录，报告失败
        try {
            if (Test-Path -LiteralPath $TargetDir) { Remove-Item -LiteralPath $TargetDir -Recurse -Force -ErrorAction SilentlyContinue }
            if (-not [string]::IsNullOrWhiteSpace($backupOld) -and (Test-Path -LiteralPath $backupOld)) {
                Rename-Item -LiteralPath $backupOld -NewName ([IO.Path]::GetFileName($TargetDir)) -ErrorAction Stop
                $r.Message = "写入新驱动包失败，已恢复原有备份: $($_.Exception.Message)"
            } else {
                $r.Message = "写入驱动包失败: $($_.Exception.Message)"
            }
        } catch {
            $r.Message = "写入新驱动包失败，且回滚也失败，请手工检查 $TargetDir 与 $backupOld : $($_.Exception.Message)"
        }
        return $r
    }
}

function Get-InfDriverVersion {
    param([string]$InfPath)
    $v = [ordered]@{ DriverDate = ''; Version = '' }
    try {
        $text = Get-Content -LiteralPath $InfPath -Raw -ErrorAction Stop
        $m = [regex]::Match([string]$text, '(?im)^\s*DriverVer\s*=\s*([^,\r\n]+)\s*,\s*([^\r\n]+)')
        if ($m.Success) {
            $v.DriverDate = $m.Groups[1].Value.Trim()
            $v.Version = $m.Groups[2].Value.Trim()
        }
    } catch { }
    return [PSCustomObject]$v
}

#endregion

#region ---------------- 备份清单（Printers.json） ----------------

function Save-BackupManifest {
    param([string]$Root, $Manifest)
    $path = Join-Path $Root $script:ManifestName
    $json = $Manifest | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($true)))
    return $path
}

function Read-BackupManifest {
    param([string]$Root)
    $res = [ordered]@{ Ok = $false; Manifest = $null; Path = ''; Message = '' }
    $path = Join-Path $Root $script:ManifestName
    if (-not (Test-Path -LiteralPath $path)) {
        $res.Message = "备份清单不存在: $path"
        return $res
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json
    } catch {
        $res.Message = "备份清单解析失败（文件可能损坏）: $($_.Exception.Message)"
        return $res
    }
    if ($null -eq $obj -or -not $obj.PSObject.Properties['Printers'] -or -not $obj.PSObject.Properties['FormatVersion']) {
        $res.Message = '备份清单格式不正确（可能不是本工具生成的备份）。'
        return $res
    }
    $res.Ok = $true
    $res.Manifest = $obj
    $res.Path = $path
    return $res
}

function Save-BackupSummaryText {
    <#  生成人工可读的 配置清单.txt #>
    param([string]$Root, $Manifest)
    $path = Join-Path $Root $script:SummaryName
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('============================================================')
    [void]$sb.AppendLine(" $($script:ToolName) - 备份配置清单")
    [void]$sb.AppendLine('============================================================')
    [void]$sb.AppendLine("工具版本   : $($Manifest.ToolVersion)")
    [void]$sb.AppendLine("备份时间   : $($Manifest.CreatedAt)")
    [void]$sb.AppendLine("来源计算机 : $($Manifest.SourceComputer)")
    [void]$sb.AppendLine("来源用户   : $($Manifest.SourceUser)")
    [void]$sb.AppendLine("来源系统   : $($Manifest.SourceOS.Caption) ($($Manifest.SourceOS.Version))  架构: $($Manifest.SourceOS.Architecture)")
    [void]$sb.AppendLine("打印机数量 : $(@($Manifest.Printers).Count)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('------------------------------------------------------------')
    [void]$sb.AppendLine(' 一、打印机列表')
    [void]$sb.AppendLine('------------------------------------------------------------')
    $i = 1
    foreach ($p in @($Manifest.Printers)) {
        [void]$sb.AppendLine("[$i] $($p.Name)")
        [void]$sb.AppendLine("    驱动名称 : $($p.DriverName)")
        [void]$sb.AppendLine("    驱动环境 : $($p.Environment)")
        [void]$sb.AppendLine("    连接类型 : $($p.ConnectionType)")
        [void]$sb.AppendLine("    端口     : $($p.PortName)")
        if (-not [string]::IsNullOrWhiteSpace($p.Address)) {
            [void]$sb.AppendLine("    IP/主机  : $($p.Address)   端口号: $($p.PortNumber)   协议: $($p.Protocol)")
            if ([string]$p.Protocol -match '(?i)lpr') {
                $q = [string]$p.LprQueueName
                if ([string]::IsNullOrWhiteSpace($q)) { $q = '(未取得，恢复时需手动填写)' }
                [void]$sb.AppendLine("    LPR 队列 : $q")
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($p.SharePath)) {
            [void]$sb.AppendLine("    共享路径 : $($p.SharePath)")
        }
        if (-not [string]::IsNullOrWhiteSpace($p.Location)) { [void]$sb.AppendLine("    位置     : $($p.Location)") }
        if (-not [string]::IsNullOrWhiteSpace($p.Comment)) { [void]$sb.AppendLine("    备注     : $($p.Comment)") }
        [void]$sb.AppendLine("    驱动状态 : $($p.DriverStatus)")
        if (-not [string]::IsNullOrWhiteSpace($p.DriverIdentityCheck)) { [void]$sb.AppendLine("    身份校验 : $($p.DriverIdentityCheck)") }
        if (-not [string]::IsNullOrWhiteSpace($p.DriverMessage)) { [void]$sb.AppendLine("    说明     : $($p.DriverMessage)") }
        if (-not [string]::IsNullOrWhiteSpace($p.PackageRelativePath)) {
            [void]$sb.AppendLine("    驱动包   : $($p.PackageRelativePath)")
        } else {
            [void]$sb.AppendLine("    驱动包   : (无 —— 本次没有备份任何驱动文件)")
        }
        [void]$sb.AppendLine("    备份结论 : $($p.BackupGrade)")
        if (-not [string]::IsNullOrWhiteSpace($p.GradeReason)) { [void]$sb.AppendLine("    结论说明 : $($p.GradeReason)") }
        [void]$sb.AppendLine('')
        $i++
    }
    [void]$sb.AppendLine('------------------------------------------------------------')
    [void]$sb.AppendLine(' 二、导出的驱动包')
    [void]$sb.AppendLine('------------------------------------------------------------')
    if (@($Manifest.DriverPackages).Count -eq 0) {
        [void]$sb.AppendLine(' (本次没有导出任何驱动包)')
    } else {
        foreach ($d in @($Manifest.DriverPackages)) {
            [void]$sb.AppendLine("$($d.PublishedName)  ->  $($d.RelativePath)")
            [void]$sb.AppendLine("    原始 INF : $($d.OriginalName)")
            [void]$sb.AppendLine("    版本     : $($d.DriverDate) $($d.DriverVersion)")
            [void]$sb.AppendLine("    文件数量 : $($d.FileCount)   总大小: $($d.TotalSizeText)")
            if (-not [string]::IsNullOrWhiteSpace($d.IdentityCheck)) { [void]$sb.AppendLine("    身份校验 : $($d.IdentityCheck)") }
            [void]$sb.AppendLine("    用于打印机: $((@($d.UsedBy)) -join ' / ')")
            [void]$sb.AppendLine('')
        }
    }
    [void]$sb.AppendLine('------------------------------------------------------------')
    [void]$sb.AppendLine(' 三、如何在新电脑上恢复')
    [void]$sb.AppendLine('------------------------------------------------------------')
    [void]$sb.AppendLine('1. 把整个 Printer_Backup 文件夹和 Printer_Migration.bat / .ps1 放到同一个目录；')
    [void]$sb.AppendLine('2. 双击 Printer_Migration.bat，选择【2】恢复打印机驱动；')
    [void]$sb.AppendLine('3. 按提示选择要恢复的打印机。TCP/IP 打印机可直接重建端口和队列；')
    [void]$sb.AppendLine('4. USB 打印机需要先插好线并开机；共享打印机需要公司网络权限，程序不会自动连接。')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")

    [IO.File]::WriteAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    return $path
}

#endregion

#region ---------------- 功能一：备份 ----------------

function Invoke-BackupFlow {
    Write-Log '开始【备份打印机驱动】' 'STEP'

    if (-not (Test-IsAdministrator)) {
        Write-Host ''
        Write-Log '导出驱动包需要管理员权限（pnputil 导出必须提权）。' 'WARN'
        $ans = Read-Input '是否现在请求管理员权限并重新打开窗口? (Y/N)'
        if ($ans -match '^(?i)y') {
            if (Start-ElevatedSession -Action 'Backup') {
                Write-Log '已在新的管理员窗口中继续执行备份，本窗口结束。' 'INFO'
                Exit-Tool 0
            }
        } else {
            Write-Log '未获得管理员权限，已取消备份。' 'ERROR'
        }
        return
    }

    $root = $script:BackupDir
    Start-LogFile -Directory (Join-Path $root 'Logs') -Prefix 'backup' | Out-Null
    Write-Log "备份目录: $root" 'INFO'

    # 1. 枚举打印机
    $printers = @(Get-PrinterInventory)
    if ($printers.Count -eq 0) {
        Write-Log '本机没有检测到任何打印机，无法备份。' 'ERROR'
        return
    }
    Write-Log "本机检测到 $($printers.Count) 台打印机。" 'OK'
    Show-PrinterList -Printers $printers -Title '本机已安装的打印机（请选择要备份的编号）'

    # 2. 选择打印机
    $selected = $null
    while ($null -eq $selected) {
        $text = Read-Input '请输入要备份的编号（多选示例: 1,3 或 1-3 或 all；直接回车取消）'
        if ([string]::IsNullOrWhiteSpace($text)) {
            Write-Log '用户取消备份。' 'WARN'
            return
        }
        $selected = ConvertTo-Selection -Text $text -Max $printers.Count
        if ($null -eq $selected) {
            Write-Host "输入无效，请输入 1 - $($printers.Count) 之间的编号。" -ForegroundColor Yellow
        }
    }
    $chosen = @($printers | Where-Object { $selected -contains $_.Index })
    Write-Log "已选择 $($chosen.Count) 台打印机: $((@($chosen | ForEach-Object { $_.Name })) -join ' / ')" 'OK'

    # 3. 逐台定位驱动包
    Write-Log '正在定位所选打印机的驱动包（只处理选中的打印机）……' 'STEP'
    $driverInfos = @{}
    foreach ($p in $chosen) {
        $info = Get-PrinterDriverDetail -DriverName $p.DriverName
        $driverInfos[$p.Name] = $info
        $lvl = 'WARN'
        if ($info.IsExportable -or $info.Status -eq '系统内置') { $lvl = 'INFO' }
        Write-Log ("打印机 [{0}] 驱动状态: {1}  ({2})" -f $p.Name, $info.Status, $info.Message) $lvl
    }

    $exportable = @($chosen | Where-Object { $driverInfos[$_.Name].IsExportable })
    if ($exportable.Count -eq 0) {
        Write-Host ''
        Write-Log '所选打印机都没有可独立导出的第三方驱动包（可能是系统内置驱动或无法定位的旧式驱动）。' 'WARN'
        Write-Log '将只保存配置信息，不会假装导出成功。' 'WARN'
    }

    Write-Host ''
    $ask = Read-Input '确认开始备份? (Y/N)'
    if (-not ($ask -match '^(?i)y')) {
        Write-Log '用户取消备份。' 'WARN'
        return
    }

    # 准备目录（暂存目录用于"先导出验证、后替换"，避免提前破坏原有备份）
    $stagingRoot = Join-Path $root ('Drivers\.staging_' + (Get-Date -Format 'yyyyMMddHHmmssfff'))
    try {
        foreach ($d in @($root, (Join-Path $root 'Drivers'), (Join-Path $root 'Logs'), $stagingRoot)) {
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null }
        }
    } catch {
        Write-Log "创建备份目录失败: $($_.Exception.Message)" 'ERROR'
        return
    }
    $driversRoot = Join-Path $root 'Drivers'
    # 清理上次异常中断遗留的暂存目录（暂存目录不是有效备份，可以安全删除）
    foreach ($stale in @(Get-ChildItem -LiteralPath $driversRoot -Directory -Force -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -like '.staging_*' -and $_.FullName -ne $stagingRoot })) {
        Remove-Item -LiteralPath $stale.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "已清理上次遗留的暂存目录: $($stale.Name)" 'WARN'
    }

    # 4. 逐个导出唯一驱动包（多台打印机共用同一个包时只导出一次）
    #    流程: 导出到暂存 -> 核对身份 -> 验证通过后才替换备份目录
    $packageMap = @{}
    $packageList = New-Object System.Collections.Generic.List[object]
    foreach ($p in $chosen) {
        $info = $driverInfos[$p.Name]
        if (-not $info.IsExportable) { continue }
        $pub = $info.PublishedName
        if ($packageMap.ContainsKey($pub)) {
            [void]$packageMap[$pub].UsedBy.Add($p.Name)
            continue
        }
        Write-Log "正在导出驱动包 $pub（供 $($p.Name) 使用）……" 'STEP'
        $exp = Export-DriverPackage -PublishedName $pub -StagingRoot $stagingRoot `
                                    -ExpectedOriginalName $info.OriginalName -ExpectedVersion $info.ExpectedVersion
        if ($exp.Ok) {
            Write-Log $exp.Message 'OK'
            # 注意: 必须先把 -replace 的结果赋给变量，否则会被解析成 GetFileNameWithoutExtension 的第 2 个参数
            $safePub = $pub -replace '[\\/:*?"<>|]', '_'
            $targetDir = Join-Path $driversRoot ([IO.Path]::GetFileNameWithoutExtension($safePub))
            $pubRes = Publish-StagedDriverPackage -StagingDir $exp.StagingDir -TargetDir $targetDir
            if (-not $pubRes.Ok) {
                Write-Log "驱动包 $pub 就位失败: $($pubRes.Message)" 'ERROR'
                $packageMap[$pub] = [PSCustomObject]@{ Failed = $true }
                continue
            }
            Write-Log $pubRes.Message 'OK'
            $rel = 'Drivers\' + [IO.Path]::GetFileName($targetDir)
            # 版本必须在"移动完成后的备份目录"里读取: 暂存目录已被移走，$exp.InfFiles 的旧路径已经不存在
            $movedInfs = @(Get-ChildItem -LiteralPath $targetDir -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue)
            $movedInf = $null
            if (-not [string]::IsNullOrWhiteSpace([string]$info.OriginalName)) {
                $hit = @($movedInfs | Where-Object { $_.Name -ieq [string]$info.OriginalName })
                if ($hit.Count -gt 0) { $movedInf = $hit[0] }
            }
            if ($null -eq $movedInf -and $movedInfs.Count -gt 0) { $movedInf = $movedInfs[0] }
            $verInfo = [PSCustomObject]@{ DriverDate = ''; Version = '' }
            if ($null -ne $movedInf) { $verInfo = Get-InfDriverVersion -InfPath $movedInf.FullName }
            if ([string]::IsNullOrWhiteSpace([string]$verInfo.Version)) {
                Write-Log "提示: 未能在备份目录中读取到 $pub 的驱动版本（$($movedInfs.Count) 个 INF）。" 'WARN'
            }
            # 可迁移性检查: 对已就位的驱动包做签名检查（决定能否在新电脑自动安装）
            $sig = Test-PackageSignature -Directory $targetDir
            $sigOk = [bool]$sig.Ok
            if ($sigOk -and -not $sig.HasValidCat -and @($sig.Unsigned).Count -gt 0) {
                # 没有任何有效目录签名，且存在未签名二进制 -> pnputil 会拒绝安装，按"需人工"处理
                $sigOk = $false
            }
            Write-Log "驱动包 $pub 签名检查: $($sig.Message)" $(if ($sigOk) { 'OK' } else { 'WARN' })
            $rec = [PSCustomObject]@{
                PublishedName     = $pub
                OriginalName      = $info.OriginalName
                RelativePath      = $rel
                SourceAbsolutePath = $targetDir
                DriverDate        = $verInfo.DriverDate
                DriverVersion     = $verInfo.Version
                InfFiles          = @($movedInfs | ForEach-Object { $_.Name })
                FileCount         = $exp.FileCount
                TotalBytes        = $exp.TotalBytes
                TotalSizeText     = (Format-Size $exp.TotalBytes)
                Environment       = $info.Environment
                IdentityCheck     = [string]$info.IdentityCheck
                SignatureVerified = $sigOk
                SignatureNote     = [string]$sig.Message
                ReplacedOld       = [bool]$pubRes.Replaced
                UsedBy            = (New-Object System.Collections.Generic.List[string])
            }
            $rec.UsedBy.Add($p.Name)
            $packageMap[$pub] = $rec
            $packageList.Add($rec)
        } else {
            Write-Log "驱动包 $pub 导出失败: $($exp.Message)" 'ERROR'
            $packageMap[$pub] = [PSCustomObject]@{ Failed = $true }
        }
    }
    # 清理暂存目录（其中剩余内容都是导出失败/未采用的包）
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 5. 组装清单（按"完整备份 / 部分备份 / 不可迁移"三级结论）
    $records = New-Object System.Collections.Generic.List[object]
    $complete = 0
    $partial = 0
    $notMigratable = 0
    foreach ($p in $chosen) {
        $info = $driverInfos[$p.Name]
        $pkgRel = ''
        $finalMessage = $info.Message
        $identityCheck = [string]$info.IdentityCheck
        $packageReady = $false
        $sigOk = $false

        if ($info.IsExportable) {
            $pub = $info.PublishedName
            if ($packageMap.ContainsKey($pub) -and -not $packageMap[$pub].PSObject.Properties['Failed']) {
                $pkgRel = $packageMap[$pub].RelativePath
                $packageReady = $true
                $sigOk = [bool]$packageMap[$pub].SignatureVerified
                $finalMessage = "驱动包 $pub 已导出到 $pkgRel。"
                if (-not [string]::IsNullOrWhiteSpace($identityCheck)) { $finalMessage += " 身份校验: $identityCheck。" }
            } else {
                $finalMessage = "驱动包 $pub 导出或身份复核失败，请查看日志；该打印机按不可迁移处理。"
            }
        }

        $gradeInfo = Get-PrinterBackupGrade -PackageReady $packageReady -DriverStatus $info.Status -SignatureOk $sigOk `
                                            -IsNetwork $p.IsNetwork -IsShared $p.IsShared `
                                            -HasValidAddress (Test-ValidPrinterAddress ([string]$p.Address)) `
                                            -Protocol ([string]$p.Protocol) -LprQueueName ([string]$p.LprQueueName)
        switch ($gradeInfo.Grade) {
            '完整备份' { $complete++ }
            '部分备份' { $partial++ }
            default    { $notMigratable++ }
        }
        $gradeReason = [string]$gradeInfo.Reason
        if ($info.Status -eq '系统内置' -and $gradeReason -like '本次没有驱动文件*') {
            $finalMessage = $info.Message
        } elseif ([string]::IsNullOrWhiteSpace($pkgRel)) {
            $finalMessage = "$finalMessage $gradeReason"
        }

        $records.Add([PSCustomObject][ordered]@{
            Name                = $p.Name
            DriverName          = $p.DriverName
            ModelName           = $info.ModelName
            Environment         = $info.Environment
            PortName            = $p.PortName
            ConnectionType      = $p.ConnectionType
            IsUsb               = $p.IsUsb
            IsNetwork           = $p.IsNetwork
            IsShared            = $p.IsShared
            SharePath           = $p.SharePath
            ServerName          = $p.ServerName
            Address             = $p.Address
            PortNumber          = $p.PortNumber
            Protocol            = $p.Protocol
            LprQueueName        = $p.LprQueueName
            IsDefault           = $p.IsDefault
            Comment             = $p.Comment
            Location            = $p.Location
            DriverStatus        = $info.Status
            DriverMessage       = $finalMessage
            DriverIdentityCheck = $identityCheck
            DriverExpectedVer   = $info.ExpectedVersion
            DriverPublishedName = $info.PublishedName
            DriverOriginalName  = $info.OriginalName
            DriverInfFile       = $info.InfFileName
            DriverEnvironment   = $info.Environment
            DriverFilePathRef   = $info.DriverFilePath
            PackageRelativePath = $pkgRel
            BackupGrade         = [string]$gradeInfo.Grade
            GradeReason         = $gradeReason
        })
    }

    # 6. 写清单文件
    $os = Get-OSInfo
    $overall = Get-OverallBackupResult -Complete $complete -Partial $partial -NotMigratable $notMigratable

    $manifest = [PSCustomObject][ordered]@{
        FormatVersion  = 3
        ToolName       = $script:ToolName
        ToolVersion    = $script:ToolVersion
        CreatedAt      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        SourceComputer = [string]$env:COMPUTERNAME
        SourceUser     = [string]$env:USERNAME
        SourceOS       = $os
        BackupFolder   = $script:BackupDirName
        DriverPackages = @($packageList | Select-Object -Property PublishedName, OriginalName, RelativePath, DriverDate, `
                                                DriverVersion, InfFiles, FileCount, TotalBytes, TotalSizeText, `
                                                Environment, IdentityCheck, SignatureVerified, SignatureNote, ReplacedOld, `
                                                @{ Name = 'UsedBy'; Expression = { @($_.UsedBy) } })
        Printers       = $records.ToArray()
        Summary        = [PSCustomObject][ordered]@{
            Total         = $chosen.Count
            Complete      = $complete
            Partial       = $partial
            NotMigratable = $notMigratable
            Result        = $overall
        }
    }

    $manifestPath = ''
    $summaryPath = ''
    try {
        $manifestPath = Save-BackupManifest -Root $root -Manifest $manifest
        $summaryPath = Save-BackupSummaryText -Root $root -Manifest $manifest
    } catch {
        Write-Log "写入备份清单失败: $($_.Exception.Message)" 'ERROR'
        return
    }

    # 7. 检查文件是否真实存在（驱动包 + 清单 + 逐台打印机的记录）
    Write-Log '正在校验备份结果（检查文件是否真实存在）……' 'STEP'
    $verifyOk = $true
    foreach ($rec in $packageList) {
        $full = Join-Path $root $rec.RelativePath
        $infs = @(Get-ChildItem -LiteralPath $full -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue)
        $files = @(Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction SilentlyContinue)
        if ($infs.Count -ge 1 -and $files.Count -eq $rec.FileCount) {
            Write-Log "校验通过: $($rec.PublishedName) -> $($rec.RelativePath)（$($files.Count) 个文件）" 'OK'
        } else {
            $verifyOk = $false
            Write-Log "校验失败: $($rec.RelativePath) 预期 $($rec.FileCount) 个文件，实际 $($files.Count) 个，INF $($infs.Count) 个。" 'ERROR'
        }
    }
    # 没有导出驱动文件的打印机必须能在清单里找到记录，并明确说明没有文件
    $manifestPrinterNames = @($records | ForEach-Object { [string]$_.Name })
    foreach ($rec in $records) {
        if ([string]::IsNullOrWhiteSpace([string]$rec.PackageRelativePath)) {
            if ($manifestPrinterNames -contains [string]$rec.Name) {
                Write-Log "校验通过: [$($rec.BackupGrade)] $($rec.Name) —— 本次无驱动文件（配置信息已记录）" 'OK'
            } else {
                $verifyOk = $false
                Write-Log "校验失败: 清单中缺少打印机记录 $($rec.Name)" 'ERROR'
            }
        }
    }
    foreach ($f in @($manifestPath, $summaryPath)) {
        if (Test-Path -LiteralPath $f) { Write-Log "已生成: $f" 'OK' } else { $verifyOk = $false; Write-Log "缺少文件: $f" 'ERROR' }
    }
    # 清理上次遗留、本次未被引用的驱动包目录（只提示，不自动删除有效数据）
    $usedRels = @($packageList | ForEach-Object { [string]$_.RelativePath })
    foreach ($d in @(Get-ChildItem -LiteralPath $driversRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        $rel = 'Drivers\' + $d.Name
        if ($usedRels -notcontains $rel) {
            Write-Log "提示: $rel 不是本次备份使用的驱动包（上次备份遗留），未删除；如需精简备份目录可手动删除。" 'WARN'
        }
    }

    # 8. 打包恢复程序 + 恢复说明 + 校验清单（让备份目录自带恢复入口）
    Write-Log '正在打包恢复程序（02_恢复打印机.bat + 核心脚本）……' 'STEP'
    $packRes = Publish-RestorePackage -Root $root -CoreDir $script:BaseDir
    if ($packRes.Ok) {
        Write-Log $packRes.Message 'OK'
    } else {
        $verifyOk = $false
        Write-Log $packRes.Message 'ERROR'
    }
    $readmePath = ''
    try {
        $readmePath = Write-RestoreReadmeText -Root $root -Manifest $manifest
        Write-Log "已生成恢复说明: $readmePath" 'OK'
    } catch {
        $verifyOk = $false
        Write-Log "生成恢复说明失败: $($_.Exception.Message)" 'ERROR'
    }
    $sumRel = New-Object System.Collections.Generic.List[string]
    foreach ($rec in $packageList) { [void]$sumRel.Add([string]$rec.RelativePath) }
    [void]$sumRel.Add($script:ManifestName)
    $cs = Write-ChecksumManifest -Root $root -RelativePaths $sumRel.ToArray()
    if ($cs.Ok) {
        Write-Log "已生成校验清单: $($cs.TextPath)（$($cs.FileCount) 个文件）" 'OK'
    } else {
        $verifyOk = $false
        Write-Log '生成校验清单失败（备份目录里没有可校验的文件）。' 'ERROR'
    }

    # 9. 最终校验: 校验清单回算 + 打包文件存在 + 不依赖原电脑绝对路径
    Write-Log '正在做最终校验（哈希回算 / 恢复程序齐全 / 路径可迁移）……' 'STEP'
    $csCheck = Test-ChecksumManifest -Root $root
    if ($csCheck.Ok) {
        Write-Log $csCheck.Message 'OK'
    } else {
        $verifyOk = $false
        Write-Log "校验清单回算失败: $($csCheck.Message)" 'ERROR'
        foreach ($m in @($csCheck.Missing)) { Write-LogFile "缺失: $m" }
        foreach ($m in @($csCheck.Mismatch)) { Write-LogFile "不一致: $m" }
    }
    foreach ($n in @('02_恢复打印机.bat', 'Printer_Migration.ps1', $script:ManifestName, '恢复说明.txt')) {
        $f = Join-Path $root $n
        if (Test-Path -LiteralPath $f) { Write-Log "恢复包文件存在: $n" 'OK' } else { $verifyOk = $false; Write-Log "恢复包缺少文件: $n" 'ERROR' }
    }
    # 迁移性: 清单里的路径必须是相对路径，恢复时按自身目录解析，不依赖原电脑绝对路径
    foreach ($rec in $packageList) {
        $rel = [string]$rec.RelativePath
        if ([IO.Path]::IsPathRooted($rel) -or $rel -match '^[A-Za-z]:') {
            $verifyOk = $false
            Write-Log "迁移性检查失败: 驱动包路径不是相对路径 -> $rel" 'ERROR'
        }
    }
    foreach ($p in @($manifest.Printers)) {
        $rel = [string]$p.PackageRelativePath
        if (-not [string]::IsNullOrWhiteSpace($rel) -and ([IO.Path]::IsPathRooted($rel) -or $rel -match '^[A-Za-z]:')) {
            $verifyOk = $false
            Write-Log "迁移性检查失败: 打印机 $($p.Name) 的驱动包路径不是相对路径 -> $rel" 'ERROR'
        }
    }

    if (-not $verifyOk) {
        $overall = Get-OverallBackupResult -Complete $complete -Partial $partial -NotMigratable $notMigratable -VerifyFailed
    }
    # 复核结果若与清单不一致（例如校验发现文件缺失），同步更新清单，避免清单与实际结论不符
    if ($overall -ne [string]$manifest.Summary.Result) {
        $manifest.Summary.Result = $overall
        try {
            [void](Save-BackupManifest -Root $root -Manifest $manifest)
            [void](Save-BackupSummaryText -Root $root -Manifest $manifest)
            [void](Write-RestoreReadmeText -Root $root -Manifest $manifest)
        } catch {
            Write-Log "更新清单结果失败: $($_.Exception.Message)" 'WARN'
        }
    }

    Write-Host ''
    Write-Host ('=' * 66) -ForegroundColor Cyan
    Write-Host ' 备份结果（三级结论）' -ForegroundColor Cyan
    Write-Host ('=' * 66) -ForegroundColor Cyan
    Write-Host ("  打印机总数 : {0}" -f $chosen.Count)
    Write-Host ("  完整备份   : {0}" -f $complete)
    Write-Host ("  部分备份   : {0}" -f $partial)
    Write-Host ("  不可迁移   : {0}" -f $notMigratable)
    Write-Host '  说明: 只有"驱动包已导出并通过身份/完整性/签名校验"才算完整备份；' -ForegroundColor Gray
    Write-Host '        "部分备份"会在新电脑上给出手动步骤；"不可迁移"需要厂商安装包。' -ForegroundColor Gray
    Write-Host ('-' * 66) -ForegroundColor DarkGray
    foreach ($rec in $records) {
        $color = 'Yellow'
        if ($rec.BackupGrade -eq '完整备份') { $color = 'Green' }
        if ($rec.BackupGrade -eq '不可迁移') { $color = 'Red' }
        Write-Host ("  [{0}] {1}" -f $rec.BackupGrade, $rec.Name) -ForegroundColor $color
        if (-not [string]::IsNullOrWhiteSpace([string]$rec.GradeReason)) {
            Write-Host ("        {0}" -f $rec.GradeReason) -ForegroundColor Gray
        }
    }
    Write-Host ('-' * 66) -ForegroundColor DarkGray
    $colorAll = 'Yellow'
    if ($overall -eq '成功') { $colorAll = 'Green' }
    if ($overall -eq '失败') { $colorAll = 'Red' }
    if ($overall -eq '成功') {
        Write-Host '  总体结果: 完整备份成功（全部打印机均为完整备份）' -ForegroundColor Green
    } else {
        Write-Host ("  总体结果: {0}" -f $overall) -ForegroundColor $colorAll
    }
    Write-Host ''
    Write-Host ("  备份目录: {0}" -f $root)
    Write-Host ''
    Write-Host '  下一步: 把整个 Printer_Backup 文件夹拷到 U 盘 -> 拷到新电脑 ->' -ForegroundColor White
    Write-Host '          双击文件夹里的  02_恢复打印机.bat' -ForegroundColor White
    Write-Host ('=' * 66) -ForegroundColor Cyan
    Write-Log "备份结束，总体结果: $overall" 'OK'

    Write-LogFile "备份总体结果: $overall (完整 $complete / 部分 $partial / 不可迁移 $notMigratable / 最终校验 $verifyOk)"
}

function Get-OverallBackupResult {
    <#  总体结论: 只有"全部打印机都是完整备份"才算成功；其余只要还有可用的备份内容就是部分成功。 #>
    param([int]$Complete, [int]$Partial, [int]$NotMigratable, [switch]$VerifyFailed)
    if ($Complete -gt 0 -and $Partial -eq 0 -and $NotMigratable -eq 0 -and -not $VerifyFailed) {
        return '成功'
    }
    if (($Complete + $Partial) -gt 0) { return '部分成功' }
    return '失败'
}

#endregion

#region ---------------- 功能二：恢复 ----------------

function Test-InfPlatform {
    <#  读取 INF 的架构分区标记，判断是否与本机架构匹配 #>
    param([string]$InfPath)
    $r = [ordered]@{ Ok = $true; Message = ''; Decorations = @() }
    if (-not (Test-Path -LiteralPath $InfPath)) {
        $r.Ok = $false
        $r.Message = "INF 文件不存在: $InfPath"
        return $r
    }
    try {
        $text = [string](Get-Content -LiteralPath $InfPath -Raw -ErrorAction Stop)
    } catch {
        $r.Ok = $false
        $r.Message = "无法读取 INF 文件: $($_.Exception.Message)"
        return $r
    }
    $found = @([regex]::Matches($text, 'NT(?:amd64|arm64|x86|ia64)', 'IgnoreCase') | ForEach-Object { $_.Value.ToLowerInvariant() } | Select-Object -Unique)
    $r.Decorations = $found
    if ($found.Count -eq 0) {
        $r.Message = 'INF 未包含架构分区标记，按通用安装包处理。'
        return $r
    }
    $arch = Get-OSArchitecture
    $want = ''
    switch ($arch) {
        'x64'   { $want = 'ntamd64' }
        'ARM64' { $want = 'ntarm64' }
        'x86'   { $want = 'ntx86' }
    }
    if (-not [string]::IsNullOrWhiteSpace($want) -and ($found -contains $want)) {
        $r.Message = "INF 支持本机架构 ($want)。"
        return $r
    }
    $r.Ok = $false
    $r.Message = "INF 的架构标记为 $($found -join '/')，与本机架构 $arch 不匹配，已停止安装该驱动。"
    return $r
}

function Test-DriverEnvironmentCompat {
    <#  依据备份时记录的打印驱动环境判断架构兼容性 #>
    param([string]$DriverEnvironment)
    $r = [ordered]@{ Ok = $true; Message = ''; Need = '' }
    $arch = Get-OSArchitecture
    if ([string]::IsNullOrWhiteSpace($DriverEnvironment)) {
        $r.Message = '备份中没有记录驱动环境，跳过架构检查（最终由 pnputil 校验）。'
        return $r
    }
    $e = $DriverEnvironment.ToLowerInvariant()
    $need = ''
    if ($e -match 'arm64') { $need = 'ARM64' }
    elseif ($e -match 'x64' -or $e -match 'amd64') { $need = 'x64' }
    elseif ($e -match 'x86' -or $e -match 'i386') { $need = 'x86' }
    $r.Need = $need
    if ([string]::IsNullOrWhiteSpace($need)) {
        $r.Message = "驱动环境为 $DriverEnvironment，无法识别架构，跳过检查。"
        return $r
    }
    if ($need -eq $arch) {
        $r.Message = "驱动环境 $DriverEnvironment 与本机架构 $arch 匹配。"
        return $r
    }
    $r.Ok = $false
    $r.Message = "备份的驱动是 $DriverEnvironment，本机是 $arch，架构不兼容，不能安装。"
    return $r
}

function Test-AuthenticodeAvailable {
    <#  检查 Get-AuthenticodeSignature 是否真的可用。
        注意: 如果 PSModulePath 里混入了 PowerShell 7 的模块路径，Windows PowerShell 5.1
        会去加载 PS7 版的 Microsoft.PowerShell.Security 并失败（扩展类型数据冲突）。
        此时必须如实报告"无法检查"，而不是假装"没有需要校签的文件"。 #>
    if ($null -ne $script:AuthSigAvailable) { return [bool]$script:AuthSigAvailable }
    $ok = $false
    foreach ($attempt in 1, 2) {
        try {
            if ($attempt -eq 2) { Import-Module Microsoft.PowerShell.Security -ErrorAction Stop | Out-Null }
            $probe = $script:ScriptPath
            if ([string]::IsNullOrWhiteSpace($probe) -or -not (Test-Path -LiteralPath $probe)) {
                $probe = Join-Path $env:SystemRoot 'System32\notepad.exe'
            }
            if (Test-Path -LiteralPath $probe) {
                [void](Get-AuthenticodeSignature -LiteralPath $probe -ErrorAction Stop)
            }
            $ok = $true
            break
        } catch { $ok = $false }
    }
    if (-not $ok) {
        Write-Log 'Get-AuthenticodeSignature 在本机不可用（PowerShell 模块加载异常），跳过签名检查。' 'WARN'
        Write-LogFile "Get-AuthenticodeSignature 不可用: PSModulePath=$($env:PSModulePath)"
    }
    $script:AuthSigAvailable = $ok
    return [bool]$ok
}

function Test-PackageSignature {
    <#  检查驱动包内的数字签名情况（只做检查与报告，绝不强制安装） #>
    param([string]$Directory)
    $r = [ordered]@{
        Ok        = $true
        HasValidCat = $false
        CatFiles  = @()
        ValidSigs = @()
        Unsigned  = @()
        Bad       = @()
        Message   = ''
    }
    if (-not (Test-Path -LiteralPath $Directory)) {
        $r.Ok = $false
        $r.Message = "驱动包目录不存在: $Directory"
        return $r
    }
    if (-not (Test-AuthenticodeAvailable)) {
        $r.Message = '本机无法加载 Get-AuthenticodeSignature（PowerShell 模块环境异常），未做签名判断；安装时由 pnputil 强制校验驱动签名。'
        return $r
    }
    $files = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -eq '.cat' -or $_.Extension -eq '.sys' -or $_.Extension -eq '.dll' })
    foreach ($f in $files) {
        $sig = $null
        try { $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName -ErrorAction Stop } catch { continue }
        $st = [string]$sig.Status
        if ($f.Extension -ieq '.cat') {
            if ($st -eq 'Valid') { $r.HasValidCat = $true; $r.CatFiles += $f.Name; $r.ValidSigs += $f.Name }
            elseif ($st -eq 'NotSigned') { $r.Unsigned += "$($f.Name)(目录签名文件未签名)" }
            else { $r.Bad += "$($f.Name): $st" }
        } else {
            if ($st -eq 'Valid') { $r.ValidSigs += $f.Name }
            elseif ($st -eq 'NotSigned') { $r.Unsigned += $f.Name }
            else { $r.Bad += "$($f.Name): $st" }
        }
    }
    if ($r.Bad.Count -gt 0) {
        $r.Ok = $false
        $r.Message = '签名检查不通过: ' + ($r.Bad -join '; ')
    } elseif ($r.HasValidCat) {
        $r.Message = "目录签名 (.cat) 有效: $((@($r.CatFiles)) -join ', ')"
    } elseif ($r.Unsigned.Count -gt 0) {
        $r.Message = "包内没有有效的 .cat 目录签名，未签名的文件: $((@($r.Unsigned)) -join ', ')"
    } else {
        $r.Message = '未找到需要校签的文件（安装时由 pnputil 强制校验签名）。'
    }
    return $r
}

function Test-BackupIntegrity {
    <#  恢复前检查：备份文件完整性(哈希校验清单) + 文件齐备性 + 架构兼容性 + 签名，逐台打印机给出结论 #>
    param([string]$Root, $Manifest, $Checksum = $null)
    $checks = New-Object System.Collections.Generic.List[object]
    $pkgCache = @{}
    # 校验清单里所有出问题的文件（相对路径），用于判定某个驱动包是否可用
    $badRelFiles = @()
    if ($null -ne $Checksum -and $Checksum.Found -and -not $Checksum.Ok) {
        $badRelFiles = @(@($Checksum.Missing) + @($Checksum.Mismatch))
    }
    foreach ($p in @($Manifest.Printers)) {
        $c = [ordered]@{
            Printer      = $p
            DriverReady  = $false
            Blocked      = $false
            BlockReason  = ''
            StatusText   = ''
            InfPath      = ''
            PackageDir   = ''
            PackageNote  = ''
            SignatureNote = ''
        }
        $archCheck = Test-DriverEnvironmentCompat -DriverEnvironment ([string]$p.DriverEnvironment)
        if (-not $archCheck.Ok) {
            $c.Blocked = $true
            $c.BlockReason = $archCheck.Message
            $c.StatusText = '架构不兼容'
            $checks.Add([PSCustomObject]$c)
            continue
        }

        $rel = [string]$p.PackageRelativePath
        if ([string]::IsNullOrWhiteSpace($rel)) {
            if ($p.DriverStatus -eq '系统内置') {
                $c.StatusText = '系统自带驱动(备份中无驱动文件)'
                $c.DriverReady = $true
                $c.PackageNote = "本次备份没有该打印机的驱动文件，恢复时依靠新电脑的 Windows 自带该驱动。$([string]$p.DriverMessage)"
            } else {
                $c.StatusText = '无驱动包(仅配置信息)'
                $c.PackageNote = "备份时未能导出驱动包: $($p.DriverMessage)"
            }
            $checks.Add([PSCustomObject]$c)
            continue
        }

        $pkgFull = Join-Path $Root $rel
        $c.PackageDir = $pkgFull
        if (-not (Test-Path -LiteralPath $pkgFull)) {
            $c.StatusText = '驱动包缺失'
            $c.PackageNote = "备份中的驱动包目录不存在: $pkgFull"
            $checks.Add([PSCustomObject]$c)
            continue
        }
        $infs = @(Get-ChildItem -LiteralPath $pkgFull -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue)
        if ($infs.Count -eq 0) {
            $c.StatusText = '驱动包不完整'
            $c.PackageNote = "驱动包目录中没有 INF 文件: $pkgFull"
            $checks.Add([PSCustomObject]$c)
            continue
        }
        $files = @(Get-ChildItem -LiteralPath $pkgFull -Recurse -File -ErrorAction SilentlyContinue)
        $pkgRec = $null
        foreach ($dp in @($Manifest.DriverPackages)) {
            if ([string]$dp.RelativePath -eq $rel) { $pkgRec = $dp; break }
        }
        if ($null -ne $pkgRec -and [int]$pkgRec.FileCount -gt 0 -and $files.Count -ne [int]$pkgRec.FileCount) {
            $c.StatusText = '驱动包不完整'
            $c.PackageNote = "驱动包文件数不符（清单 $($pkgRec.FileCount) 个，实际 $($files.Count) 个），备份可能不完整。"
            $checks.Add([PSCustomObject]$c)
            continue
        }
        # 哈希校验清单里若该驱动包内有文件缺失/被改动 -> 阻止安装
        if ($badRelFiles.Count -gt 0) {
            $pkgBad = @()
            foreach ($brel in $badRelFiles) {
                $brelFull = ''
                try { $brelFull = [IO.Path]::GetFullPath((Join-Path $Root ([string]$brel))) } catch { continue }
                if ($brelFull.StartsWith($pkgFull, [StringComparison]::OrdinalIgnoreCase)) { $pkgBad += [string]$brel }
            }
            if ($pkgBad.Count -gt 0) {
                $c.Blocked = $true
                $c.BlockReason = "驱动包文件校验失败（$($pkgBad.Count) 个文件缺失或被改动）: $((@($pkgBad | Select-Object -First 3)) -join '; ')"
                $c.StatusText = '文件校验失败'
                $c.PackageNote = '备份文件与校验清单不一致，已停止安装该驱动。'
                $checks.Add([PSCustomObject]$c)
                continue
            }
        }

        # 选择与备份一致的 INF
        $chosenInf = $infs[0].FullName
        if (-not [string]::IsNullOrWhiteSpace([string]$p.DriverInfFile)) {
            $m = @($infs | Where-Object { $_.Name -ieq [string]$p.DriverInfFile })
            if ($m.Count -gt 0) { $chosenInf = $m[0].FullName }
        }
        $c.InfPath = $chosenInf

        $infCheck = Test-InfPlatform -InfPath $chosenInf
        if (-not $infCheck.Ok) {
            $c.Blocked = $true
            $c.BlockReason = $infCheck.Message
            $c.StatusText = '架构不兼容'
            $checks.Add([PSCustomObject]$c)
            continue
        }

        if (-not $pkgCache.ContainsKey($pkgFull)) {
            $sig = Test-PackageSignature -Directory $pkgFull
            $pkgCache[$pkgFull] = $sig
        }
        $sigInfo = $pkgCache[$pkgFull]
        $c.SignatureNote = $sigInfo.Message
        if (-not $sigInfo.Ok) {
            $c.Blocked = $true
            $c.BlockReason = $sigInfo.Message
            $c.StatusText = '签名异常'
            $checks.Add([PSCustomObject]$c)
            continue
        }

        $c.DriverReady = $true
        $c.StatusText = '可恢复(驱动包就绪)'
        $c.PackageNote = "INF: $([IO.Path]::GetFileName($chosenInf))  文件数: $($files.Count)"
        $checks.Add([PSCustomObject]$c)
    }
    return $checks.ToArray()
}

function Get-PrinterDriverNames {
    $names = @()
    try { $names = @(Get-PrinterDriver -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name }) } catch { $names = @() }
    return $names
}

function Find-StagedDriverPackage {
    <#  在"系统驱动库"里定位刚入库的驱动包（按原始 INF 名称 + 版本核对）。
        返回 PublishedName 与系统驱动库中的 INF 路径 (C:\Windows\INF\oemNN.inf)。
        -Packages 仅供自检注入。 #>
    param([string]$OriginalName, [string]$ExpectedVersion = '', $Packages = $null)
    $r = [ordered]@{ Ok = $false; PublishedName = ''; StagedInfPath = ''; Candidates = @(); Message = '' }
    if ([string]::IsNullOrWhiteSpace($OriginalName)) {
        $r.Message = '没有原始 INF 名称，无法核对入库结果。'
        return $r
    }
    $pkgs = @()
    if ($null -ne $Packages) { $pkgs = @($Packages) } else { $pkgs = @(Get-DriverStorePackages -Force) }
    $hit = @($pkgs | Where-Object { [string]$_.OriginalName -ieq $OriginalName })
    if ($hit.Count -eq 0) {
        $r.Message = "系统驱动库中没有找到原始 INF 为 $OriginalName 的驱动包。"
        return $r
    }
    $picked = $null
    if ($hit.Count -eq 1) {
        $picked = $hit[0]
    } else {
        $byVer = @($hit | Where-Object { (Test-DriverVersionMatch -Expected $ExpectedVersion -Actual ([string]$_.DriverVersion)) -eq 'match' })
        if ($byVer.Count -eq 1) {
            $picked = $byVer[0]
        } else {
            $r.Candidates = @($hit | ForEach-Object { [string]$_.PublishedName })
            $r.Message = "驱动库里有 $($hit.Count) 个同名驱动包，无法唯一定位入库结果（$((@($hit | ForEach-Object { "$($_.PublishedName)($($_.DriverVersion))" })) -join ', ')）。"
            return $r
        }
    }
    $pub = [string]$picked.PublishedName
    $staged = Join-Path (Join-Path $env:SystemRoot 'INF') $pub
    $r.PublishedName = $pub
    $r.StagedInfPath = $staged
    if (-not (Test-Path -LiteralPath $staged)) {
        $r.Message = "驱动库中已登记 $pub，但系统驱动库 INF 路径不存在: $staged"
        return $r
    }
    $r.Ok = $true
    $r.Message = "已核验: 系统驱动库中的 $pub -> $staged"
    return $r
}

function Install-DriverPackage {
    <#  第 1 步(驱动入库): 用 pnputil 把备份里的 INF 导入系统驱动库(DriverStore)，
        并核验它确实出现在驱动库中、且系统 INF 路径真实存在。
        注意: 这一步只完成"驱动入库"，还不等于打印后台(spooler)已注册打印驱动。 #>
    param([string]$InfPath, [string]$ExpectedOriginalName = '', [string]$ExpectedVersion = '')
    $r = [ordered]@{
        Ok = $false; Output = ''; ExitCode = -1; Message = ''
        StoreVerified = $false; StagedPublishedName = ''; StagedInfPath = ''
    }
    if (-not (Test-Path -LiteralPath $InfPath)) {
        $r.Message = "INF 文件不存在: $InfPath"
        return $r
    }
    $origName = $ExpectedOriginalName
    if ([string]::IsNullOrWhiteSpace($origName)) { $origName = Split-Path -Leaf $InfPath }

    $used = ''
    $n = Invoke-Native -FilePath $script:PnPUtilPath -Arguments @('/add-driver', $InfPath, '/install')
    Write-LogFile "--- pnputil /add-driver `"$InfPath`" /install ---"
    Write-LogFile $n.Output
    Write-LogFile "退出码: $($n.ExitCode)"
    if ($n.ExitCode -eq 0) {
        $used = 'pnputil /add-driver /install'
        $r.Output = [string]$n.Output
    } else {
        Write-Log "pnputil /add-driver /install 返回码 $($n.ExitCode)，改为只入库（不绑定设备）。" 'WARN'
        $n2 = Invoke-Native -FilePath $script:PnPUtilPath -Arguments @('/add-driver', $InfPath)
        Write-LogFile "--- pnputil /add-driver `"$InfPath`" ---"
        Write-LogFile $n2.Output
        Write-LogFile "退出码: $($n2.ExitCode)"
        if ($n2.ExitCode -eq 0) {
            $used = 'pnputil /add-driver'
            $r.Output = [string]$n2.Output
        } else {
            $r.Output = ([string]$n.Output) + "`r`n" + ([string]$n2.Output)
            $r.ExitCode = $n2.ExitCode
            $r.Message = "驱动入库失败（pnputil 退出码 $($n.ExitCode) / $($n2.ExitCode)），未写入系统驱动库。"
            return $r
        }
    }

    # 核验入库结果: 驱动库里必须能按原始 INF 名称找到，且系统 INF 路径存在
    $found = Find-StagedDriverPackage -OriginalName $origName -ExpectedVersion $ExpectedVersion
    Write-LogFile $found.Message
    if (-not $found.Ok) {
        $r.Output = [string]$r.Output
        $r.Message = "$used 报告成功，但未能核验入库结果: $($found.Message) 未把该驱动视为已就绪。"
        return $r
    }
    $r.Ok = $true
    $r.StoreVerified = $true
    $r.StagedPublishedName = $found.PublishedName
    $r.StagedInfPath = $found.StagedInfPath
    $r.Message = "驱动已导入系统驱动库并核验通过（$used）：$($found.PublishedName) -> $($found.StagedInfPath)"
    return $r
}

function Test-PrinterDriverRegistered {
    <#  核验打印后台(spooler)是否已注册该打印驱动，并确认它就是要用的那个驱动包:
        身份依据 = 新电脑上实际分配的 PublishedName（入库后的 oemNN.inf）
                   或 原始 INF 名称 + 驱动 INF 里的 DriverVer 版本核对。
        Registered  : 打印后台里有同名打印驱动
        Matched     : 名称层面能对上
        Confirmed   : 身份已确认（调用方只有 Confirmed=$true 才能判定成功） #>
    param(
        [string]$ModelName,
        [string]$ExpectedInfName = '',
        [string]$ExpectedPublishedName = '',
        [string]$ExpectedVersion = ''
    )
    $r = [ordered]@{ Registered = $false; Matched = $false; Confirmed = $false; RegisteredInfPath = ''; Message = '' }
    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        $r.Message = '没有驱动型号名，无法核验打印后台注册结果。'
        return $r
    }
    $list = @()
    try { $list = @(Get-PrinterDriver -Name $ModelName -ErrorAction SilentlyContinue) } catch { $list = @() }
    if ($list.Count -eq 0) {
        $r.Message = "打印后台中没有找到打印驱动 ""$ModelName""。"
        return $r
    }
    $r.Registered = $true

    $foundInfPath = ''
    foreach ($d in $list) {
        $infPath = ''
        if ($d.PSObject.Properties['InfPath']) { $infPath = [string]$d.InfPath }
        if ([string]::IsNullOrWhiteSpace($infPath)) { continue }
        $leaf = Split-Path -Leaf $infPath
        # 1) 与新电脑实际分配的 PublishedName 一致 -> 身份确认
        if (-not [string]::IsNullOrWhiteSpace($ExpectedPublishedName) -and $leaf -ieq $ExpectedPublishedName) {
            $r.Matched = $true
            $r.Confirmed = $true
            $foundInfPath = $infPath
            break
        }
        # 2) 与备份里的原始 INF 名称一致时，还要求版本一致才算确认
        if (-not [string]::IsNullOrWhiteSpace($ExpectedInfName) -and $leaf -ieq $ExpectedInfName) {
            $r.Matched = $true
            $verChk = 'unknown'
            if (Test-Path -LiteralPath $infPath) {
                $v = Get-InfDriverVersion -InfPath $infPath
                $verChk = Test-DriverVersionMatch -Expected $ExpectedVersion -Actual ([string]$v.Version)
            }
            $foundInfPath = $infPath
            if ($verChk -ne 'mismatch') { $r.Confirmed = $true; break }
        }
        if ([string]::IsNullOrWhiteSpace($foundInfPath)) { $foundInfPath = $infPath }
    }
    $r.RegisteredInfPath = $foundInfPath

    if ($r.Confirmed) {
        $r.Message = "打印后台已注册打印驱动 ""$ModelName""，并已确认关联的驱动包（$([IO.Path]::GetFileName($r.RegisteredInfPath))）。"
    } elseif ($r.Matched) {
        $r.Message = "打印后台已有同名打印驱动 ""$ModelName""，但无法确认它就是备份里的驱动包（登记 INF: $([IO.Path]::GetFileName($r.RegisteredInfPath))；备份原始 INF: $ExpectedInfName；新电脑分配的 PublishedName: $ExpectedPublishedName）。"
    } else {
        $r.Message = "打印后台已有同名打印驱动 ""$ModelName""，但关联的 INF（$([IO.Path]::GetFileName($r.RegisteredInfPath))）与备份不一致，无法确认身份。"
    }
    return $r
}

function Register-PrinterDriver {
    <#  第 2 步(打印后台注册): 把驱动注册到打印后台(spooler)，使其可被打印队列使用，并核验注册结果。
        -InfPath 优先传系统驱动库里的 INF（C:\Windows\INF\oemNN.inf）；
        只有驱动库里找不到时才回退使用备份目录里的 INF。
        -ExpectedPublishedName 是新电脑驱动库实际分配的名称，用于确认"已存在的同名驱动"就是这一个。 #>
    param(
        [string]$ModelName,
        [string]$InfPath,
        [string]$ExpectedInfName = '',
        [string]$ExpectedPublishedName = '',
        [string]$ExpectedVersion = ''
    )
    $r = [ordered]@{ Ok = $false; ModelName = $ModelName; Message = ''; Verified = $false; RegisteredInfPath = ''; UsedInfPath = $InfPath }

    $pre = Test-PrinterDriverRegistered -ModelName $ModelName -ExpectedInfName $ExpectedInfName `
                                        -ExpectedPublishedName $ExpectedPublishedName -ExpectedVersion $ExpectedVersion
    if ($pre.Registered) {
        $r.RegisteredInfPath = $pre.RegisteredInfPath
        if ($pre.Confirmed) {
            $r.Ok = $true
            $r.Verified = $true
            $r.Message = $pre.Message
        } else {
            # 同名但身份无法确认 -> 不得判定成功
            $r.Ok = $false
            $r.Verified = $false
            $r.Message = "$($pre.Message) 未自动判定为成功；请人工确认该驱动是否就是要用的驱动（必要时先在「打印机管理」里删除该打印驱动再重试）。"
        }
        return $r
    }

    $err1 = ''
    try {
        if (-not [string]::IsNullOrWhiteSpace($ModelName)) {
            Add-PrinterDriver -Name $ModelName -InfPath $InfPath -ErrorAction Stop
        } else {
            Add-PrinterDriver -InfPath $InfPath -ErrorAction Stop
        }
    } catch {
        $err1 = $_.Exception.Message
        Write-Log "Add-PrinterDriver 失败: $err1，改用 printui.dll 备用方式。" 'WARN'
        if (-not [string]::IsNullOrWhiteSpace($ModelName)) {
            $n = Invoke-Native -FilePath $script:Rundll32Path -Arguments @('printui.dll,PrintUIEntry', '/ia', '/q', '/m', $ModelName, '/f', $InfPath)
            Write-LogFile '--- rundll32 printui.dll,PrintUIEntry /ia ---'
            Write-LogFile $n.Output
        }
    }

    # 无论用哪种方式，都以打印后台的实际注册结果和身份确认为准
    $post = Test-PrinterDriverRegistered -ModelName $ModelName -ExpectedInfName $ExpectedInfName `
                                         -ExpectedPublishedName $ExpectedPublishedName -ExpectedVersion $ExpectedVersion
    if ($post.Registered -and $post.Confirmed) {
        $r.Ok = $true
        $r.Verified = $true
        $r.RegisteredInfPath = $post.RegisteredInfPath
        $r.Message = $post.Message
        return $r
    }
    if ($post.Registered) {
        $r.Ok = $false
        $r.Verified = $false
        $r.RegisteredInfPath = $post.RegisteredInfPath
        $r.Message = "$($post.Message) 注册结果无法确认身份，未自动判定为成功。"
        return $r
    }
    if ([string]::IsNullOrWhiteSpace($err1)) { $err1 = $post.Message }
    $r.Message = "打印后台注册失败（驱动可能已入库，但打印驱动未注册）: $err1"
    return $r
}

function Test-PrinterNameExists {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $esc = [WildcardPattern]::Escape($Name)
    try {
        if (Get-Printer -Name $esc -ErrorAction SilentlyContinue) { return $true }
    } catch { }
    try {
        if (Get-CimInstance -ClassName Win32_Printer -Filter ("Name='" + ($Name -replace "'", "''") + "'") -ErrorAction SilentlyContinue) { return $true }
    } catch { }
    return $false
}

function Get-DefaultPrinterName {
    try {
        $d = @(Get-CimInstance -ClassName Win32_Printer -Filter 'Default=TRUE' -ErrorAction SilentlyContinue)
        if ($d.Count -gt 0) { return [string]$d[0].Name }
    } catch { }
    return ''
}

function Restore-DefaultPrinter {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $true }
    $now = Get-DefaultPrinterName
    if ($now -eq $Name) { return $true }
    try {
        $net = New-Object -ComObject WScript.Network
        $net.SetDefaultPrinter($Name)
        $after = Get-DefaultPrinterName
        if ($after -eq $Name) { return $true }
        return $false
    } catch {
        Write-Log "恢复默认打印机失败: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Get-NetworkPortPlan {
    <#  纯逻辑: 依据备份信息判断能否自动创建 TCP/IP 端口，以及该用 RAW 还是 LPR。
        缺少必要参数（如 LPR 队列名）时返回 Ok=$false，由调用方提示用户手动配置，不猜。 #>
    param($Printer)
    $r = [ordered]@{
        Ok = $false; Protocol = ''; PortName = ''; Address = ''
        PortNumber = 0; LprQueueName = ''; Reason = ''; Notes = @()
    }
    $addr = ''
    if ($null -ne $Printer -and $Printer.PSObject.Properties['Address']) { $addr = ([string]$Printer.Address).Trim() }
    if (-not (Test-ValidPrinterAddress $addr)) {
        $r.Reason = '备份中没有有效的 IP 地址或主机名，无法自动创建端口，请按下面的手动步骤添加打印机。'
        return $r
    }
    $r.Address = $addr
    $warn = Test-AddressWorthWarning $addr
    if (-not [string]::IsNullOrWhiteSpace($warn)) { $r.Notes = @($r.Notes) + $warn }

    $proto = ''
    if ($null -ne $Printer -and $Printer.PSObject.Properties['Protocol']) { $proto = ([string]$Printer.Protocol).Trim().ToUpperInvariant() }
    $queue = ''
    if ($null -ne $Printer -and $Printer.PSObject.Properties['LprQueueName']) { $queue = ([string]$Printer.LprQueueName).Trim() }
    $origPort = ''
    if ($null -ne $Printer -and $Printer.PSObject.Properties['PortName']) { $origPort = ([string]$Printer.PortName).Trim() }

    if ($proto -match '^LPR') {
        if ([string]::IsNullOrWhiteSpace($queue)) {
            $r.Reason = '备份显示该打印机使用 LPR 协议，但备份里没有 LPR 队列名，无法自动创建端口；请手动添加，并在端口配置里选择 LPR 协议后填写队列名。'
            return $r
        }
        $r.Protocol = 'LPR'
        $r.LprQueueName = $queue
        if (-not [string]::IsNullOrWhiteSpace($origPort) -and $origPort -notmatch '^\\\\') { $r.PortName = $origPort } else { $r.PortName = $addr }
        $r.Ok = $true
        $r.Notes = @($r.Notes) + "按 LPR 协议创建端口，队列名: $queue"
        return $r
    }
    if ([string]::IsNullOrWhiteSpace($proto) -or $proto -match '^RAW') {
        $pn = 9100
        if ($null -ne $Printer -and $Printer.PSObject.Properties['PortNumber'] -and [int]$Printer.PortNumber -gt 0) { $pn = [int]$Printer.PortNumber }
        $r.Protocol = 'RAW'
        $r.PortNumber = $pn
        $r.PortName = 'IP_' + $addr
        $r.Ok = $true
        if ([string]::IsNullOrWhiteSpace($proto)) {
            $r.Notes = @($r.Notes) + '备份未记录端口协议，按 Windows 默认的 RAW 处理'
        }
        $r.Notes = @($r.Notes) + "按 RAW 协议创建端口，端口号: $pn"
        return $r
    }
    $r.Reason = "备份记录的端口协议为 $proto，本工具只支持自动创建 RAW / LPR 端口，请手动配置该端口。"
    return $r
}

function New-TcpPrinterQueue {
    <#  为 TCP/IP 打印机创建端口和打印队列（不覆盖已有打印机、不改默认打印机）。
        顺序: 先判断打印机是否已存在(存在则完全不动，避免留下多余端口) -> 再按 RAW/LPR 计划建端口 -> 再建队列。
        队列创建失败且端口是本函数新建、且没有打印机在使用时，回滚删除该端口。 #>
    param($Printer, [string]$InfPath, [string]$ModelName)
    $r = [ordered]@{
        Ok = $false; Steps = (New-Object System.Collections.Generic.List[string]); Message = ''
        CreatedName = ''; PortName = ''; PortCreated = $false; PortRolledBack = $false
    }
    $printerName = [string]$Printer.Name
    if ([string]::IsNullOrWhiteSpace($printerName)) { $printerName = '网络打印机' }

    # 1) 先检查目标打印机是否已存在 —— 存在就直接结束，不创建任何端口
    if (Test-PrinterNameExists $printerName) {
        $r.Steps.Add("已存在同名打印机 ""$printerName""，按需求不覆盖，也不会创建端口。")
        $r.Message = '未创建（已存在同名打印机，未改动系统）。'
        return $r
    }

    # 2) 生成创建计划（RAW / LPR / 参数不足转手动）
    $plan = Get-NetworkPortPlan -Printer $Printer
    foreach ($n in @($plan.Notes)) { if (-not [string]::IsNullOrWhiteSpace([string]$n)) { $r.Steps.Add([string]$n) } }
    if (-not $plan.Ok) {
        $r.Message = $plan.Reason
        return $r
    }
    $portName = [string]$plan.PortName
    $r.PortName = $portName

    # 3) 创建端口
    $portExists = $false
    try {
        if (Get-PrinterPort -Name ([WildcardPattern]::Escape($portName)) -ErrorAction SilentlyContinue) { $portExists = $true }
    } catch { }
    if ($portExists) {
        $r.Steps.Add("端口 $portName 已存在，跳过创建。")
    } else {
        try {
            if ($plan.Protocol -eq 'LPR') {
                Add-PrinterPort -Name $portName -LprHostAddress $plan.Address -LprQueueName $plan.LprQueueName -ErrorAction Stop
                $r.Steps.Add("已创建 LPR 端口 $portName ($($plan.Address)，队列 $($plan.LprQueueName))。")
            } else {
                Add-PrinterPort -Name $portName -PrinterHostAddress $plan.Address -PortNumber $plan.PortNumber -ErrorAction Stop
                $r.Steps.Add("已创建 RAW 端口 $portName ($($plan.Address):$($plan.PortNumber))。")
            }
            $r.PortCreated = $true
        } catch {
            $r.Steps.Add("创建端口失败: $($_.Exception.Message)")
            $r.Message = '创建端口失败，请按下面的手动步骤添加打印机。'
            return $r
        }
    }

    # 4) 创建打印队列
    $queueOk = $false
    try {
        Add-Printer -Name $printerName -DriverName $ModelName -PortName $portName -ErrorAction Stop
        $r.Steps.Add("已创建打印队列 ""$printerName""（驱动: $ModelName，端口: $portName）。")
        $queueOk = $true
    } catch {
        $r.Steps.Add("Add-Printer 失败: $($_.Exception.Message)")
    }
    if (-not $queueOk) {
        Write-Log '改用 printui.dll 备用方式创建打印队列。' 'WARN'
        $n = Invoke-Native -FilePath $script:Rundll32Path -Arguments @('printui.dll,PrintUIEntry', '/if', '/q', '/b', $printerName, '/f', $InfPath, '/r', $portName, '/m', $ModelName)
        Write-LogFile '--- rundll32 printui.dll,PrintUIEntry /if ---'
        Write-LogFile $n.Output
        if (Test-PrinterNameExists $printerName) {
            $r.Steps.Add("已通过 printui 创建打印队列 ""$printerName""。")
            $queueOk = $true
        }
    }

    if ($queueOk) {
        $r.Ok = $true
        $r.CreatedName = $printerName
        $r.Message = "已创建端口和打印队列（$($plan.Protocol)）。"
        return $r
    }

    # 5) 队列失败: 回收本次新建且无人使用的端口，避免留下多余端口
    if ($r.PortCreated) {
        $inUse = @()
        try { $inUse = @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { [string]$_.PortName -ieq $portName }) } catch { $inUse = @() }
        if ($inUse.Count -eq 0) {
            try {
                Remove-PrinterPort -Name ([WildcardPattern]::Escape($portName)) -ErrorAction Stop
                $r.PortRolledBack = $true
                $r.Steps.Add("打印队列创建失败，已删除本次新建且无人使用的端口 $portName。")
            } catch {
                $r.Steps.Add("打印队列创建失败；尝试删除多余端口 $portName 也失败: $($_.Exception.Message)")
            }
        } else {
            $r.Steps.Add("打印队列创建失败；端口 $portName 已被 $($inUse.Count) 个打印机使用，未删除。")
        }
    }
    $r.Message = '创建打印队列失败，请按下面的手动步骤添加打印机。'
    return $r
}

function Get-ManualSteps {
    <#  为无法自动恢复的打印机生成手动操作说明 #>
    param($Printer, [string]$InfPath)
    $lines = New-Object System.Collections.Generic.List[string]
    $infText = '备份目录\Drivers\<驱动包>\xxx.inf'
    if (-not [string]::IsNullOrWhiteSpace($InfPath)) { $infText = $InfPath }
    if ($Printer.IsUsb) {
        $lines.Add('1) 用 USB 线连接打印机并开机，等待系统识别出端口（如 USB001）。')
        $lines.Add('2) 打开 设置 -> 蓝牙和其他设备 -> 打印机和扫描仪 -> 添加设备。')
        $lines.Add('3) 选择出现的打印机；若提示选择驱动，点击"从磁盘安装"并指向: ' + $infText)
    } elseif ($Printer.IsNetwork -and -not $Printer.IsShared) {
        $addr = [string]$Printer.Address
        if ([string]::IsNullOrWhiteSpace($addr)) { $addr = '打印机 IP 地址' }
        $proto = ''
        if ($null -ne $Printer.PSObject.Properties['Protocol']) { $proto = ([string]$Printer.Protocol).Trim().ToUpperInvariant() }
        $queue = ''
        if ($null -ne $Printer.PSObject.Properties['LprQueueName']) { $queue = ([string]$Printer.LprQueueName).Trim() }
        $pn = 9100
        if ($null -ne $Printer.PortNumber -and [int]$Printer.PortNumber -gt 0) { $pn = [int]$Printer.PortNumber }
        $lines.Add('1) 打开 设置 -> 打印机和扫描仪 -> 添加设备 -> 手动添加。')
        if ($proto -match '^LPR') {
            if ([string]::IsNullOrWhiteSpace($queue)) { $queue = '(请填写，通常为 print 或向原电脑管理员确认)' }
            $lines.Add('2) 选择"使用 IP 地址或主机名添加打印机"，IP: ' + $addr + '，端口类型选 LPR。')
            $lines.Add('3) LPR 队列名填: ' + $queue + '（LPR 协议不使用端口号）。')
            $lines.Add('4) 驱动选择"从磁盘安装"，指向: ' + $infText)
        } else {
            $lines.Add('2) 选择"使用 IP 地址或主机名添加打印机"，IP: ' + $addr + '，端口: ' + $pn + ' (RAW)。')
            $lines.Add('3) 驱动选择"从磁盘安装"，指向: ' + $infText)
        }
    } elseif ($Printer.IsShared) {
        $sp = [string]$Printer.SharePath
        if ([string]::IsNullOrWhiteSpace($sp)) { $sp = '\\服务器\共享名' }
        $lines.Add('1) 本工具不会自动连接共享打印机（需要公司网络和账号权限）。')
        $lines.Add('2) 在文件资源管理器地址栏输入: ' + $sp + ' 并回车，按提示输入有权限的账号。')
        $lines.Add('3) 右键该共享打印机 -> 连接。若提示缺少驱动，用管理员账号在该电脑上安装: ' + $infText)
    } else {
        $lines.Add('1) 打开 设置 -> 打印机和扫描仪 -> 添加设备。')
        $lines.Add('2) 如为虚拟打印机（如 Microsoft Print to PDF / WPS PDF），请安装对应软件后在"添加设备"中启用。')
        $lines.Add('3) 如需从磁盘安装驱动，指向: ' + $infText)
    }
    return $lines
}

function Invoke-RestoreFlow {
    Write-Log '开始【恢复打印机】' 'STEP'

    # 1. 自动定位备份数据（不需要用户填写任何驱动文件位置）
    Write-Log '正在自动识别备份数据（查找 Printers.json）……' 'STEP'
    Write-Log "本程序目录: $($script:BaseDir)" 'INFO'
    $root = Resolve-BackupDataRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        Write-Host ''
        Write-Log '没有在程序目录（及其子目录 Printer_Backup）里找到备份数据 Printers.json。' 'WARN'
        Write-Log '请确认：整个 Printer_Backup 文件夹是从旧电脑完整复制过来的，且没有只复制其中一部分文件。' 'WARN'
        $ans = Read-Input '如果备份数据在别的目录，请输入它的完整路径（直接回车取消）'
        if ([string]::IsNullOrWhiteSpace($ans)) {
            Write-Log '已取消恢复。' 'WARN'
            return
        }
        $cand = $ans.Trim().Trim('"').Trim()
        $root = Resolve-BackupDataRoot -Candidates @($cand, (Join-Path $cand $script:BackupDirName))
        if ([string]::IsNullOrWhiteSpace($root)) {
            Write-Log "该目录下没有找到 $($script:ManifestName): $cand" 'ERROR'
            return
        }
    }
    Write-Log "备份数据目录: $root" 'OK'
    Start-LogFile -Directory (Join-Path $root 'Logs') -Prefix 'restore' | Out-Null

    # 2. 读取清单
    $read = Read-BackupManifest -Root $root
    if (-not $read.Ok) {
        Write-Log $read.Message 'ERROR'
        Write-Log '请确认已把旧电脑的 Printer_Backup 文件夹完整拷贝过来。' 'INFO'
        return
    }
    $manifest = $read.Manifest
    $printers = @($manifest.Printers)
    if ($printers.Count -eq 0) {
        Write-Log '备份清单中没有打印机记录。' 'ERROR'
        return
    }
    Write-Log "备份清单读取成功: $($read.Path)" 'OK'
    Write-Log "备份时间: $($manifest.CreatedAt)   来源计算机: $($manifest.SourceComputer)" 'INFO'
    if ($manifest.Summary) {
        Write-Log ("备份结论: 完整 {0} / 部分 {1} / 不可迁移 {2} / 总体 {3}" -f `
            [string]$manifest.Summary.Complete, [string]$manifest.Summary.Partial, `
            [string]$manifest.Summary.NotMigratable, [string]$manifest.Summary.Result) 'INFO'
    }

    # 3. 环境检查
    Write-Log '正在检查本机操作系统与架构……' 'STEP'
    $os = Get-OSInfo
    Write-Log "本机系统: $($os.Caption) $($os.Version) (内部版本 $($os.Build))，架构: $($os.Architecture)" 'INFO'
    if ($manifest.SourceOS) {
        Write-Log "备份来源: $($manifest.SourceOS.Caption) $($manifest.SourceOS.Version)，架构: $($manifest.SourceOS.Architecture)" 'INFO'
        if ([string]$manifest.SourceOS.Architecture -ne $os.Architecture) {
            Write-Log "警告: 来源架构与本机架构不同，将逐个驱动检查兼容性。" 'WARN'
        }
        if ([bool]$manifest.SourceOS.Is64Bit -and -not $os.Is64Bit) {
            Write-Log '警告: 备份来自 64 位系统，本机是 32 位系统，大部分驱动将无法安装。' 'WARN'
        }
    }

    # 3.5 校验清单哈希核对（驱动文件完整性）
    Write-Log '正在核对备份文件的哈希校验清单……' 'STEP'
    $csCheck = Test-ChecksumManifest -Root $root
    if ($csCheck.Found -and $csCheck.Ok) {
        Write-Log $csCheck.Message 'OK'
    } elseif (-not $csCheck.Found) {
        Write-Log $csCheck.Message 'WARN'
        Write-Log '将退回到"文件数量/INF 是否齐全"的检查方式。' 'WARN'
    } else {
        Write-Log $csCheck.Message 'ERROR'
        foreach ($d in @($csCheck.Details)) { Write-Log "  $d" 'ERROR' }
        Write-Log '备份文件已损坏或被改动，将停止安装对应驱动包（不会用不完整的驱动去装）。' 'ERROR'
    }

    # 4. 完整性与兼容性检查
    Write-Log '正在检查驱动文件完整性、架构兼容性和数字签名……' 'STEP'
    $checks = @(Test-BackupIntegrity -Root $root -Manifest $manifest -Checksum $csCheck)
    $idx = 1
    foreach ($c in $checks) {
        $p = $c.Printer
        Write-Host ("[{0}] {1}" -f $idx, $p.Name) -ForegroundColor White
        Write-Host ("    类型: {0}    端口: {1}" -f $p.ConnectionType, $p.PortName) -ForegroundColor Gray
        if (-not [string]::IsNullOrWhiteSpace($p.Address)) { Write-Host ("    地址: {0}" -f $p.Address) -ForegroundColor Gray }
        if (-not [string]::IsNullOrWhiteSpace($p.SharePath)) { Write-Host ("    共享: {0}" -f $p.SharePath) -ForegroundColor Gray }
        $color = 'Yellow'
        if ($c.DriverReady) { $color = 'Green' }
        if ($c.Blocked) { $color = 'Red' }
        Write-Host ("    状态: {0}" -f $c.StatusText) -ForegroundColor $color
        if (-not [string]::IsNullOrWhiteSpace($c.PackageNote)) { Write-Host ("    {0}" -f $c.PackageNote) -ForegroundColor DarkGray }
        if (-not [string]::IsNullOrWhiteSpace($c.SignatureNote)) { Write-Host ("    签名: {0}" -f $c.SignatureNote) -ForegroundColor DarkGray }
        if ($c.Blocked) { Write-Host ("    已阻止: {0}" -f $c.BlockReason) -ForegroundColor Red }
        $c | Add-Member -NotePropertyName DisplayIndex -NotePropertyValue $idx -Force
        $idx++
    }
    Write-Host ''

    # 5. 选择要恢复的打印机
    $selected = $null
    while ($null -eq $selected) {
        $text = Read-Input '请输入要恢复的编号（多选示例: 1,3 或 1-3 或 all；直接回车取消）'
        if ([string]::IsNullOrWhiteSpace($text)) {
            Write-Log '用户取消恢复。' 'WARN'
            return
        }
        $selected = ConvertTo-Selection -Text $text -Max $checks.Count
        if ($null -eq $selected) {
            Write-Host "输入无效，请输入 1 - $($checks.Count) 之间的编号。" -ForegroundColor Yellow
        }
    }
    $chosen = @($checks | Where-Object { $selected -contains $_.DisplayIndex })
    Write-Host ''
    Write-Host ("即将恢复 {0} 台打印机。程序会:" -f $chosen.Count) -ForegroundColor White
    Write-Host '  - 使用 pnputil 安装备份中的 INF 驱动（Windows 官方方式）' -ForegroundColor Gray
    Write-Host '  - 不覆盖已有打印机、不修改默认打印机、不删除其它驱动、不重启电脑' -ForegroundColor Gray
    $ask = Read-Input '确认继续? (Y/N)'
    if (-not ($ask -match '^(?i)y')) {
        Write-Log '用户取消恢复。' 'WARN'
        return
    }

    if (-not (Test-IsAdministrator)) {
        Write-Host ''
        Write-Log '安装驱动需要管理员权限。' 'WARN'
        $ans = Read-Input '是否现在请求管理员权限并重新打开窗口? (Y/N)'
        if ($ans -match '^(?i)y') {
            if (Start-ElevatedSession -Action 'Restore') {
                Write-Log '已在新的管理员窗口中继续执行恢复，本窗口结束。' 'INFO'
                Exit-Tool 0
            }
        } else {
            Write-Log '未获得管理员权限，已取消恢复。' 'ERROR'
        }
        return
    }

    # 6. 记录默认打印机，便于恢复后还原
    $defaultBefore = Get-DefaultPrinterName
    if (-not [string]::IsNullOrWhiteSpace($defaultBefore)) {
        Write-Log "当前默认打印机: $defaultBefore（恢复完成后会保持不变）" 'INFO'
    }

    # 7. 逐台恢复
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($c in $chosen) {
        $p = $c.Printer
        Write-Log ("处理打印机: {0}" -f $p.Name) 'STEP'
        $res = [ordered]@{
            Name        = $p.Name
            DriverOk    = $false
            DriverNote  = ''
            QueueOk     = $false
            QueueNote   = ''
            Steps       = (New-Object System.Collections.Generic.List[string])
            Manual      = @()
        }
        $modelName = [string]$p.ModelName
        if ([string]::IsNullOrWhiteSpace($modelName)) { $modelName = [string]$p.DriverName }

        if ($c.Blocked) {
            $res.DriverNote = "已跳过安装: $($c.BlockReason)"
            Write-Log $res.DriverNote 'ERROR'
        } elseif ([string]::IsNullOrWhiteSpace($c.InfPath)) {
            $res.DriverNote = [string]$p.DriverStatus
            if ($p.DriverStatus -eq '系统内置') {
                # 系统内置驱动不需要安装驱动包；但如果本机已有同名打印驱动，仍然可以继续创建端口/队列
                $builtinReady = $false
                if (-not [string]::IsNullOrWhiteSpace($modelName)) {
                    try { if (Get-PrinterDriver -Name $modelName -ErrorAction SilentlyContinue) { $builtinReady = $true } } catch { }
                }
                if ($builtinReady) {
                    $res.DriverOk = $true
                    $res.DriverNote = "系统内置驱动 ""$modelName"" 在本机已可用，无需安装驱动包。"
                    Write-Log $res.DriverNote 'OK'
                } else {
                    $res.DriverNote = '系统内置驱动，本机暂未找到同名打印驱动（虚拟打印机需安装对应软件后才会出现）。'
                    Write-Log $res.DriverNote 'WARN'
                }
            } else {
                $res.DriverNote = "备份中没有可用的驱动包，只能提供配置信息。原因: $([string]$p.DriverMessage)"
                Write-Log $res.DriverNote 'WARN'
            }
        } else {
            # 7.1 第 1 步: 驱动入库 (系统驱动库/DriverStore)
            $driversBefore = @(Get-PrinterDriverNames)
            # 定位驱动包用备份时记录的"导出驱动的原始 INF 名称"(DriverOriginalName)
            $expectedInfName = [string]$p.DriverOriginalName
            if ([string]::IsNullOrWhiteSpace($expectedInfName)) { $expectedInfName = [string]$p.DriverInfFile }
            if ([string]::IsNullOrWhiteSpace($expectedInfName)) { $expectedInfName = [IO.Path]::GetFileName($c.InfPath) }
            $expectedVersion = [string]$p.DriverExpectedVer
            Write-Log "第 1 步 驱动入库: pnputil 导入 $($c.InfPath)（原始 INF: $expectedInfName）" 'INFO'
            $inst = Install-DriverPackage -InfPath $c.InfPath -ExpectedOriginalName $expectedInfName -ExpectedVersion $expectedVersion
            Write-LogFile "[入库] $($inst.Message)"
            if ($inst.Ok) {
                Write-Log $inst.Message 'OK'
                # 第 2 步: 打印后台注册 (优先用系统驱动库里的 INF 路径)
                # 核验身份用"新电脑实际分配的 PublishedName"(入库后的 oemNN.inf) + 原始 INF 名 + 版本
                $regInfPath = $inst.StagedInfPath
                if ([string]::IsNullOrWhiteSpace($regInfPath)) { $regInfPath = $c.InfPath }
                $stagedPublished = [string]$inst.StagedPublishedName
                Write-Log "第 2 步 打印后台注册: Add-PrinterDriver -Name ""$modelName"" -InfPath $regInfPath（新电脑分配: $stagedPublished）" 'INFO'
                $reg = Register-PrinterDriver -ModelName $modelName -InfPath $regInfPath -ExpectedInfName $expectedInfName `
                                              -ExpectedPublishedName $stagedPublished -ExpectedVersion $expectedVersion
                Write-LogFile "[注册] $($reg.Message)"
                if ($reg.Ok) {
                    $res.DriverOk = $true
                    $res.DriverNote = $reg.Message
                    if ($reg.Verified) {
                        Write-Log $reg.Message 'OK'
                    } else {
                        Write-Log $reg.Message 'WARN'
                    }
                } else {
                    # 尝试用"安装前后新增的打印驱动"来校正驱动名
                    $driversAfter = @(Get-PrinterDriverNames)
                    $newOnes = @($driversAfter | Where-Object { $driversBefore -notcontains $_ })
                    if ($newOnes.Count -eq 1) {
                        $modelName = $newOnes[0]
                        Write-Log "已按打印后台新增的打印驱动更正驱动名为: $modelName" 'WARN'
                        $reg2 = Register-PrinterDriver -ModelName $modelName -InfPath $regInfPath -ExpectedInfName $expectedInfName `
                                                       -ExpectedPublishedName $stagedPublished -ExpectedVersion $expectedVersion
                        if ($reg2.Ok) {
                            $res.DriverOk = $true
                            $res.DriverNote = $reg2.Message
                        }
                    }
                    if (-not $res.DriverOk) {
                        $res.DriverNote = $reg.Message + ' (驱动只完成了入库，打印后台还没有确认注册对应的打印驱动)'
                        Write-Log $res.DriverNote 'WARN'
                    }
                }
                # 7.3 复查打印后台注册结果（必须身份确认通过）
                if ($res.DriverOk) {
                    $recheck = Test-PrinterDriverRegistered -ModelName $modelName -ExpectedInfName $expectedInfName `
                                                            -ExpectedPublishedName $stagedPublished -ExpectedVersion $expectedVersion
                    if ($recheck.Registered -and $recheck.Confirmed) {
                        Write-Log "复查通过: $($recheck.Message)" 'OK'
                    } else {
                        Write-Log "复查未能确认打印后台注册身份: $($recheck.Message)" 'WARN'
                        Write-Log '未自动判定为成功，请按手动步骤确认/添加打印机。' 'WARN'
                        $res.DriverOk = $false
                    }
                }
            } else {
                $res.DriverNote = $inst.Message
                Write-Log $res.DriverNote 'ERROR'
                Write-Log '驱动入库失败，已停止该打印机的后续操作（不会复制文件冒充成功）。' 'ERROR'
                Write-LogFile $inst.Output
            }
        }

        # 7.4 按连接类型处理
        if ($c.Blocked -or -not $res.DriverOk) {
            $res.Manual = @(Get-ManualSteps -Printer $p -InfPath $c.InfPath)
        } elseif ($p.IsShared) {
            $sp = [string]$p.SharePath
            Write-Host ''
            Write-Log "这是共享打印机，原共享路径: $sp" 'WARN'
            Write-Log '程序不会自动连接共享打印机（需要公司网络和账号权限），请在资源管理器中手动连接。' 'WARN'
            $res.Manual = @(Get-ManualSteps -Printer $p -InfPath $c.InfPath)
        } elseif ($p.IsUsb) {
            Write-Host ''
            Write-Log "USB 打印机 ""$($p.Name)""：请先连接 USB 线并开机。" 'WARN'
            $namesBefore = @(Get-PrinterInventory | ForEach-Object { [string]$_.Name })
            $ans = Read-Input '连接好后按回车键检测（输入 S 跳过检测）'
            if ($ans -match '^(?i)s') {
                $res.QueueNote = '用户跳过 USB 检测，请自行确认打印机是否已出现在系统中。'
                $res.Manual = @(Get-ManualSteps -Printer $p -InfPath $c.InfPath)
            } else {
                Write-Log '正在重新检测打印机……' 'INFO'
                $invNow = @(Get-PrinterInventory)
                $newPrinters = @($invNow | Where-Object { $namesBefore -notcontains [string]$_.Name })
                $usbHit = @($invNow | Where-Object { $_.IsUsb -and ($_.DriverName -eq $modelName -or $_.Name -eq $p.Name) })
                $foundName = ''
                if ($usbHit.Count -gt 0) {
                    $res.QueueOk = $true
                    $foundName = [string]$usbHit[0].Name
                    $res.QueueNote = "已检测到 USB 打印机: $((@($usbHit | ForEach-Object { $_.Name })) -join ', ')"
                    Write-Log $res.QueueNote 'OK'
                } elseif ($newPrinters.Count -gt 0) {
                    $res.QueueOk = $true
                    $foundName = [string]$newPrinters[0].Name
                    $res.QueueNote = "检测到新打印机: $((@($newPrinters | ForEach-Object { $_.Name })) -join ', ')，请确认是否使用了正确的驱动。"
                    Write-Log $res.QueueNote 'OK'
                } else {
                    $res.QueueNote = '未检测到新打印机（设备可能需要时间安装，或需要在"添加设备"里手动选择）。'
                    Write-Log $res.QueueNote 'WARN'
                    $res.Manual = @(Get-ManualSteps -Printer $p -InfPath $c.InfPath)
                }
                # 已识别到打印机 -> 询问是否打印测试页
                if (-not [string]::IsNullOrWhiteSpace($foundName)) {
                    Write-Log "系统识别检查: 已找到打印机 ""$foundName""。" 'OK'
                    $testAns = Read-Input "是否现在打印一张测试页来确认打印正常? (Y/N)"
                    if ($testAns -match '^(?i)y') {
                        $tp = Send-TestPage -PrinterName $foundName
                        Write-Log $tp.Message $(if ($tp.Ok) { 'OK' } else { 'WARN' })
                        $res.QueueNote = "$($res.QueueNote) 测试页: $($tp.Message)"
                    }
                }
            }
        } elseif ($p.IsNetwork -and -not [string]::IsNullOrWhiteSpace([string]$p.Address)) {
            Write-Host ''
            $warn = Test-AddressWorthWarning ([string]$p.Address)
            Write-Log "该打印机为 TCP/IP 网络打印机，备份的地址: $($p.Address)" 'INFO'
            if (-not [string]::IsNullOrWhiteSpace($warn)) { Write-Log $warn 'WARN' }
            # 先给出创建计划（协议/端口/端口号或 LPR 队列），让用户明确知道会创建什么
            $plan = Get-NetworkPortPlan -Printer $p
            $askQueue = $true
            if ($plan.Ok) {
                foreach ($n in @($plan.Notes)) { if (-not [string]::IsNullOrWhiteSpace([string]$n)) { Write-Log "计划: $n" 'INFO' } }
                Write-Log "计划: 端口名 $($plan.PortName)，协议 $($plan.Protocol)" 'INFO'
                # 连接条件检查（ping / 打印端口），只提示不阻断
                $conn = Test-NetworkTargetReachable -Address ([string]$p.Address) -Protocol $plan.Protocol -PortNumber ([int]$plan.PortNumber)
                if ($conn.Checked) {
                    Write-Log "连接检查: $($conn.Message)" $(if ($conn.PingOk -or $conn.PortOk) { 'INFO' } else { 'WARN' })
                    if (-not $conn.PingOk -and -not $conn.PortOk) {
                        Write-Log '打印机当前没有响应（可能未开机或不在同一网络）；仍可先创建端口和队列，之后再确认。' 'WARN'
                    }
                }
            } else {
                # 缺少必要参数（如 LPR 队列名 / 有效地址）: 不提供自动创建选项，直接给手动步骤
                Write-Log $plan.Reason 'WARN'
                $askQueue = $false
            }
            $ans = 'N'
            if ($askQueue) { $ans = Read-Input "是否创建打印机端口和打印队列 ""$($p.Name)""? (Y/N)" }
            if ($ans -match '^(?i)y') {
                $q = New-TcpPrinterQueue -Printer $p -InfPath $c.InfPath -ModelName $modelName
                foreach ($s in $q.Steps) { Write-Log $s 'INFO' }
                $res.QueueOk = [bool]$q.Ok
                $res.QueueNote = $q.Message
                if ($q.Ok) {
                    Write-Log $q.Message 'OK'
                    # 安装成功后复查系统是否识别该打印机，并询问是否打印测试页
                    $res.QueueNote = "$($q.Message) 系统已识别打印机 ""$($q.CreatedName)""。"
                    Write-Log "系统识别检查: 已找到打印机 ""$($q.CreatedName)""。" 'OK'
                    $testAns = Read-Input "是否现在打印一张测试页来确认打印正常? (Y/N)"
                    if ($testAns -match '^(?i)y') {
                        $tp = Send-TestPage -PrinterName ([string]$q.CreatedName)
                        Write-Log $tp.Message $(if ($tp.Ok) { 'OK' } else { 'WARN' })
                        $res.QueueNote = "$($res.QueueNote) 测试页: $($tp.Message)"
                    }
                } else {
                    Write-Log $q.Message 'WARN'
                    $res.Manual = @(Get-ManualSteps -Printer $p -InfPath $c.InfPath)
                }
            } else {
                if ($askQueue) {
                    $res.QueueNote = '用户选择不自动创建端口和队列。'
                } else {
                    $res.QueueNote = '备份信息不足，未自动创建端口，请按手动步骤配置。'
                }
                Write-Log $res.QueueNote 'WARN'
                $res.Manual = @(Get-ManualSteps -Printer $p -InfPath $c.InfPath)
            }
        } elseif ($p.IsNetwork) {
            Write-Log "该打印机为网络打印机（$($p.ConnectionType)），备份中没有可用 IP，需在新电脑上重新搜索设备。" 'WARN'
            $res.QueueNote = '需要手动搜索添加（WSD/其它网络端口）。'
            $res.Manual = @(Get-ManualSteps -Printer $p -InfPath $c.InfPath)
        } else {
            Write-Log '驱动已就绪，请按下面的方法在本机添加该打印机。' 'INFO'
            $res.Manual = @(Get-ManualSteps -Printer $p -InfPath $c.InfPath)
        }

        $results.Add([PSCustomObject]$res)
    }

    # 8. 还原默认打印机
    if (-not [string]::IsNullOrWhiteSpace($defaultBefore)) {
        $afterDefault = Get-DefaultPrinterName
        if ($afterDefault -ne $defaultBefore) {
            if (Restore-DefaultPrinter -Name $defaultBefore) {
                Write-Log "已把默认打印机还原为: $defaultBefore" 'OK'
            } else {
                Write-Log "默认打印机被系统改成了 $afterDefault，未能自动还原为 $defaultBefore。" 'WARN'
            }
        } else {
            Write-Log "默认打印机保持不变: $defaultBefore" 'OK'
        }
    }

    # 9. 结果汇总
    Write-Host ''
    Write-Host ('=' * 66) -ForegroundColor Cyan
    Write-Host ' 恢复结果' -ForegroundColor Cyan
    Write-Host ('=' * 66) -ForegroundColor Cyan
    $okCount = 0
    foreach ($res in $results) {
        $tag = '需手动处理'
        $color = 'Yellow'
        if ($res.DriverOk -and ($res.QueueOk -or $res.Manual.Count -eq 0)) { $tag = '已恢复'; $color = 'Green'; $okCount++ }
        elseif ($res.DriverOk) { $tag = '驱动已装'; $color = 'Yellow'; $okCount++ }
        else { $color = 'Red' }
        Write-Host ("  [{0}] {1}" -f $tag, $res.Name) -ForegroundColor $color
        if (-not [string]::IsNullOrWhiteSpace($res.DriverNote)) { Write-Host ("        驱动: {0}" -f $res.DriverNote) -ForegroundColor Gray }
        if (-not [string]::IsNullOrWhiteSpace($res.QueueNote)) { Write-Host ("        队列: {0}" -f $res.QueueNote) -ForegroundColor Gray }
        if (@($res.Manual).Count -gt 0) {
            Write-Host '        手动步骤:' -ForegroundColor Gray
            foreach ($line in @($res.Manual)) { Write-Host ("          {0}" -f $line) -ForegroundColor Gray }
        }
        Write-Host ''
    }
    Write-Host ('-' * 66) -ForegroundColor DarkGray
    Write-Host ("  成功处理: {0} / {1}" -f $okCount, $results.Count) -ForegroundColor $(if ($okCount -eq $results.Count) { 'Green' } else { 'Yellow' })
    Write-Host '  说明: 本工具只做"驱动安装 + 可选队列创建"，不会自动重启电脑。' -ForegroundColor Gray
    Write-Host ('=' * 66) -ForegroundColor Cyan
    Write-Log "恢复结束: 成功处理 $okCount / $($results.Count)" 'OK'
}

#endregion

#region ---------------- 自包含备份包：打包、校验清单、迁移等级 ----------------

function Resolve-BackupDataRoot {
    <#  自动定位备份数据目录（必须含 Printers.json）。支持两种布局:
        A) 恢复程序与备份数据在同一个目录（程序 A 打包出来的 Printer_Backup 文件夹）
        B) 数据在程序目录下的 Printer_Backup 子目录（兼容旧版布局）
        -Candidates 仅供自检注入。 #>
    param([string[]]$Candidates = $null)
    $list = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Candidates) {
        foreach ($c in $Candidates) { if (-not [string]::IsNullOrWhiteSpace($c)) { [void]$list.Add($c) } }
    } else {
        [void]$list.Add($script:BaseDir)
        [void]$list.Add((Join-Path $script:BaseDir $script:BackupDirName))
        $cwd = ''
        try { $cwd = (Get-Location).Path } catch { $cwd = '' }
        if (-not [string]::IsNullOrWhiteSpace($cwd)) {
            [void]$list.Add($cwd)
            [void]$list.Add((Join-Path $cwd $script:BackupDirName))
        }
    }
    $seen = @{}
    foreach ($c in $list) {
        $full = ''
        try { $full = [IO.Path]::GetFullPath($c) } catch { continue }
        if ([string]::IsNullOrWhiteSpace($full) -or $seen.ContainsKey($full)) { continue }
        $seen[$full] = $true
        if (-not (Test-Path -LiteralPath $full)) { continue }
        if (Test-Path -LiteralPath (Join-Path $full $script:ManifestName)) { return $full }
    }
    return ''
}

function Write-ChecksumManifest {
    <#  为备份包生成校验清单（SHA256）: 覆盖驱动包文件和配置清单，
        新电脑恢复时会逐个核对，文件缺失或被改动都能查出来。 #>
    param([string]$Root, [string[]]$RelativePaths, [string]$Name = 'Checksums.json', [string]$TextName = '校验清单.txt')
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $RelativePaths) {
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $full = Join-Path $Root $rel
        if (Test-Path -LiteralPath $full -PathType Container) {
            foreach ($f in @(Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction SilentlyContinue)) { [void]$files.Add($f.FullName) }
        } elseif (Test-Path -LiteralPath $full -PathType Leaf) {
            [void]$files.Add($full)
        }
    }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($f in @($files | Sort-Object -Unique)) {
        $rel = $f.Substring($Root.Length).TrimStart('\')
        $hash = ''
        try { $hash = (Get-FileHash -LiteralPath $f -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $hash = '' }
        if ([string]::IsNullOrWhiteSpace($hash)) { continue }
        $len = 0
        try { $len = [long](Get-Item -LiteralPath $f).Length } catch { $len = 0 }
        $entries.Add([PSCustomObject]@{ Path = $rel; Bytes = $len; Sha256 = $hash })
    }
    $doc = [PSCustomObject][ordered]@{
        FormatVersion = 1
        Algorithm     = 'SHA256'
        CreatedAt     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        FileCount     = $entries.Count
        Files         = $entries.ToArray()
    }
    $jsonPath = Join-Path $Root $Name
    [IO.File]::WriteAllText($jsonPath, ($doc | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($true)))

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('============================================================')
    [void]$sb.AppendLine(' 备份校验清单 (SHA256)')
    [void]$sb.AppendLine('============================================================')
    [void]$sb.AppendLine("生成时间 : $($doc.CreatedAt)")
    [void]$sb.AppendLine("文件数量 : $($entries.Count)")
    [void]$sb.AppendLine('算法     : SHA256')
    [void]$sb.AppendLine('')
    foreach ($e in $entries) { [void]$sb.AppendLine(("{0}  {1,10}  {2}" -f $e.Sha256, $e.Bytes, $e.Path)) }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('说明: 新电脑恢复前会逐个核对上面的哈希值；文件缺失或被改动会明确报错，并停止安装该驱动。')
    [IO.File]::WriteAllText((Join-Path $Root $TextName), $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))

    return [PSCustomObject]@{ Ok = ($entries.Count -gt 0); JsonPath = $jsonPath; TextPath = (Join-Path $Root $TextName); FileCount = $entries.Count }
}

function Test-ChecksumManifest {
    <#  校验备份文件完整性: 逐个核对存在性、大小和 SHA256。 #>
    param([string]$Root, [string]$Name = 'Checksums.json')
    $r = [ordered]@{ Ok = $false; Found = $false; Checked = 0; Missing = @(); Mismatch = @(); Details = @(); Message = '' }
    $p = Join-Path $Root $Name
    if (-not (Test-Path -LiteralPath $p)) {
        $r.Message = "备份目录里没有 $Name（可能是旧版本备份），无法做哈希校验。"
        return $r
    }
    try {
        $doc = (Get-Content -LiteralPath $p -Raw -Encoding UTF8 -ErrorAction Stop) | ConvertFrom-Json
    } catch {
        $r.Message = "校验清单解析失败（文件可能损坏）: $($_.Exception.Message)"
        return $r
    }
    if ($null -eq $doc -or -not $doc.PSObject.Properties['Files']) {
        $r.Message = '校验清单格式不正确。'
        return $r
    }
    $files = @($doc.Files)
    if ($files.Count -eq 0) {
        $r.Message = '校验清单里没有文件记录。'
        return $r
    }
    $r.Found = $true
    $missing = New-Object System.Collections.Generic.List[string]
    $bad = New-Object System.Collections.Generic.List[string]
    $details = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) {
        $rel = [string]$f.Path
        $full = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            [void]$missing.Add($rel)
            [void]$details.Add("缺失: $rel")
            continue
        }
        $len = 0
        try { $len = [long](Get-Item -LiteralPath $full).Length } catch { $len = 0 }
        if ([long]$f.Bytes -gt 0 -and $len -ne [long]$f.Bytes) {
            [void]$bad.Add($rel)
            [void]$details.Add("大小不一致: $rel (实际 $len <> 清单 $($f.Bytes))")
            continue
        }
        $hash = ''
        try { $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $hash = '' }
        if ([string]::IsNullOrWhiteSpace($hash) -or $hash -ine [string]$f.Sha256) {
            [void]$bad.Add($rel)
            [void]$details.Add("SHA256 不一致: $rel")
            continue
        }
        $r.Checked++
    }
    $r.Missing = $missing.ToArray()
    $r.Mismatch = $bad.ToArray()
    $r.Details = $details.ToArray()
    if ($missing.Count -eq 0 -and $bad.Count -eq 0) {
        $r.Ok = $true
        $r.Message = "完整性校验通过: $($r.Checked) 个文件与校验清单一致。"
    } else {
        $r.Message = "完整性校验失败: 缺失 $($missing.Count) 个文件，内容不一致 $($bad.Count) 个。"
    }
    return $r
}

function Get-PrinterBackupGrade {
    <#  备份结果三级结论: 完整备份 / 部分备份 / 不可迁移。
        只有"驱动包真实导出 + 身份与文件校验通过 + 签名通过 + 恢复时驱动可自动安装"才算完整备份。 #>
    param(
        [bool]$PackageReady,
        [string]$DriverStatus,
        [bool]$SignatureOk,
        [bool]$IsNetwork,
        [bool]$IsShared,
        [bool]$HasValidAddress,
        [string]$Protocol,
        [string]$LprQueueName
    )
    $r = [ordered]@{ Grade = '不可迁移'; Reason = '' }
    if ($PackageReady) {
        if (-not $SignatureOk) {
            $r.Grade = '不可迁移'
            $r.Reason = '驱动包签名检查未通过，不会自动安装，请向厂商索取带签名的驱动'
            return $r
        }
        $reasons = New-Object System.Collections.Generic.List[string]
        $grade = '完整备份'
        if ($IsShared) {
            $grade = '部分备份'
            [void]$reasons.Add('共享打印机需要在新电脑上手动连接（需要公司网络和账号权限）')
        } elseif ($IsNetwork) {
            if (-not $HasValidAddress) {
                $grade = '部分备份'
                [void]$reasons.Add('网络打印机没有记录到有效 IP/主机名，端口需要手动配置')
            } elseif ($Protocol -match '(?i)^lpr' -and [string]::IsNullOrWhiteSpace($LprQueueName)) {
                $grade = '部分备份'
                [void]$reasons.Add('LPR 端口缺少队列名，端口需要手动配置')
            }
        }
        $r.Grade = $grade
        if ($reasons.Count -gt 0) { $r.Reason = ($reasons -join '；') }
        else { $r.Reason = '驱动包已导出并通过身份/完整性/签名校验，新电脑可自动安装' }
        return $r
    }
    if ($DriverStatus -eq '系统内置') {
        $r.Grade = '部分备份'
        $r.Reason = '本次没有驱动文件（该驱动由 Windows 自带），只保存了配置信息'
        return $r
    }
    $r.Grade = '不可迁移'
    switch ($DriverStatus) {
        '身份不符' { $r.Reason = '驱动包身份无法确认（版本不一致），未导出；需要厂商安装包' }
        '存在歧义' { $r.Reason = '系统驱动库里有多个同名驱动包，无法唯一确认，未导出；需要厂商安装包' }
        default    { $r.Reason = '未能定位可导出的驱动包；需要厂商安装包或在旧电脑上先安装厂商驱动' }
    }
    return $r
}

function Publish-RestorePackage {
    <#  把恢复入口 BAT 和核心脚本复制进备份目录，保证备份目录自带恢复程序、
        拷到 U 盘/新电脑后不依赖原电脑路径、也不需要手工复制脚本。 #>
    param(
        [string]$Root,
        [string]$CoreDir,
        [string]$RestoreBatName = '02_恢复打印机.bat',
        [string]$CoreDestName = 'Printer_Migration.ps1'
    )
    $r = [ordered]@{ Ok = $false; Copied = @(); Missing = @(); Message = '' }
    $copied = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]

    $batSrc = Join-Path $CoreDir $RestoreBatName
    if (-not (Test-Path -LiteralPath $batSrc)) {
        $cand = @(Get-ChildItem -LiteralPath $CoreDir -File -Filter '*.bat' -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like '02*' -or $_.Name -like '*恢复*' } | Sort-Object Name)
        if ($cand.Count -gt 0) { $batSrc = $cand[0].FullName }
    }
    if (Test-Path -LiteralPath $batSrc) {
        $batDest = Join-Path $Root $RestoreBatName
        if ([IO.Path]::GetFullPath($batSrc) -ieq [IO.Path]::GetFullPath($batDest)) {
            [void]$copied.Add($RestoreBatName)   # 已经在目标位置，无需复制
        } else {
            Copy-Item -LiteralPath $batSrc -Destination $batDest -Force -ErrorAction Stop
            [void]$copied.Add($RestoreBatName)
        }
    } else {
        [void]$missing.Add($RestoreBatName)
    }

    if (-not [string]::IsNullOrWhiteSpace($script:ScriptPath) -and (Test-Path -LiteralPath $script:ScriptPath)) {
        $coreDest = Join-Path $Root $CoreDestName
        if ([IO.Path]::GetFullPath($script:ScriptPath) -ieq [IO.Path]::GetFullPath($coreDest)) {
            [void]$copied.Add($CoreDestName)
        } else {
            Copy-Item -LiteralPath $script:ScriptPath -Destination $coreDest -Force -ErrorAction Stop
            [void]$copied.Add($CoreDestName)
        }
    } else {
        [void]$missing.Add($CoreDestName)
    }

    $r.Copied = $copied.ToArray()
    $r.Missing = $missing.ToArray()
    $r.Ok = ($missing.Count -eq 0)
    if ($r.Ok) {
        $r.Message = "已把恢复程序打包进备份目录: $((@($r.Copied)) -join ', ')"
    } else {
        $r.Message = "打包恢复程序失败，缺少: $((@($r.Missing)) -join ', ')（请确认 01_备份打印机.bat、02_恢复打印机.bat、Printer_Migration.ps1 在同一目录）"
    }
    return $r
}

function Write-RestoreReadmeText {
    <#  在备份目录里生成"恢复说明.txt"，新电脑上不看别的文档也能操作 #>
    param([string]$Root, $Manifest)
    $path = Join-Path $Root '恢复说明.txt'
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('============================================================')
    [void]$sb.AppendLine(' 打印机迁移备份 - 新电脑恢复说明')
    [void]$sb.AppendLine('============================================================')
    [void]$sb.AppendLine("备份时间   : $($Manifest.CreatedAt)")
    [void]$sb.AppendLine("来源计算机 : $($Manifest.SourceComputer)")
    [void]$sb.AppendLine("来源系统   : $($Manifest.SourceOS.Caption) ($($Manifest.SourceOS.Version))  架构: $($Manifest.SourceOS.Architecture)")
    [void]$sb.AppendLine("打印机数量 : $(@($Manifest.Printers).Count)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('【怎么用】')
    [void]$sb.AppendLine('1. 把整个这个文件夹（Printer_Backup）拷到新电脑（U 盘 / 网盘都行），')
    [void]$sb.AppendLine('   建议放到桌面或任意有写入权限的目录，不要只拷里面的文件；')
    [void]$sb.AppendLine('2. 在新电脑上双击本文件夹里的:  02_恢复打印机.bat')
    [void]$sb.AppendLine('3. 按提示确认后，程序会自动校验并安装驱动、重建端口和打印队列；')
    [void]$sb.AppendLine('4. 需要管理员权限时会出现 UAC 提权窗口，这是正常的系统授权。')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('【备份结果含义】')
    [void]$sb.AppendLine('  完整备份 : 驱动包已导出并校验通过，新电脑可自动安装')
    [void]$sb.AppendLine('  部分备份 : 没有驱动文件或需要人工一步（例如共享打印机、缺 IP 的网络打印机、')
    [void]$sb.AppendLine('             USB 需要重新插线），程序会给出具体的手动步骤')
    [void]$sb.AppendLine('  不可迁移 : 旧电脑上该驱动没有可导出的 INF（厂商安装程序直接注册的旧式驱动），')
    [void]$sb.AppendLine('             必须在新电脑上安装厂商驱动包')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('【注意】')
    [void]$sb.AppendLine('- 程序不会覆盖新电脑上已有的同名打印机，也不会修改默认打印机；')
    [void]$sb.AppendLine('- 不会删除任何驱动、不会自动重启；')
    [void]$sb.AppendLine('- 共享打印机需要公司网络和账号权限，程序不会自动连接；')
    [void]$sb.AppendLine('- 驱动文件校验失败时程序会明确报错并停止安装该驱动。')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [IO.File]::WriteAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    return $path
}

function Test-NetworkTargetReachable {
    <#  网络打印机的"连接条件"检查: ping 目标地址 + (RAW) 探测端口。
        只做提示，不阻断（打印机可能没开机，用户仍可能要先建队列）。 #>
    param([string]$Address, [string]$Protocol = 'RAW', [int]$PortNumber = 0)
    $r = [ordered]@{ Checked = $false; PingOk = $false; PortChecked = $false; PortOk = $false; Message = '' }
    if ([string]::IsNullOrWhiteSpace($Address)) {
        $r.Message = '没有地址，跳过网络连通性检查。'
        return $r
    }
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send($Address, 1500)
        if ($null -ne $reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $r.PingOk = $true }
    } catch { $r.PingOk = $false }

    if ($Protocol -match '(?i)^raw' -and $PortNumber -gt 0) {
        $r.PortChecked = $true
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($Address, $PortNumber, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(2000)) {
                $client.EndConnect($iar)
                $r.PortOk = $true
            }
        } catch {
            $r.PortOk = $false
        } finally {
            if ($null -ne $client) { try { $client.Close() } catch { } }
        }
    }
    $r.Checked = $true
    $parts = New-Object System.Collections.Generic.List[string]
    if ($r.PingOk) { [void]$parts.Add('ping 有响应') } else { [void]$parts.Add('ping 无响应') }
    if ($r.PortChecked) {
        if ($r.PortOk) { [void]$parts.Add("打印端口 $PortNumber 可达") } else { [void]$parts.Add("打印端口 $PortNumber 不可达") }
    }
    $r.Message = ($parts -join '，')
    return $r
}

function Send-TestPage {
    <#  通过系统自带 printui.dll 发送测试页 #>
    param([string]$PrinterName)
    $r = [ordered]@{ Ok = $false; Message = '' }
    if ([string]::IsNullOrWhiteSpace($PrinterName)) {
        $r.Message = '没有打印机名称，无法发送测试页。'
        return $r
    }
    $n = Invoke-Native -FilePath $script:Rundll32Path -Arguments @('printui.dll,PrintUIEntry', '/k', '/n', $PrinterName)
    Write-LogFile '--- rundll32 printui.dll,PrintUIEntry /k ---'
    Write-LogFile $n.Output
    Write-LogFile "退出码: $($n.ExitCode)"
    if ($n.ExitCode -eq 0) {
        $r.Ok = $true
        $r.Message = '已向打印队列发送测试页（程序无法代替你确认纸张是否真的打出来）。'
    } else {
        $r.Message = "发送测试页失败（退出码 $($n.ExitCode)），可在 打印机属性 -> 常规 -> 打印测试页 手动测试。"
    }
    return $r
}

#endregion

#region ---------------- 自检 ----------------

function Invoke-SelfTest {
    $script:SelfTestPass = 0
    $script:SelfTestFail = 0
    function Test-Case {
        param([string]$Name, [scriptblock]$Body)
        try {
            $ok = & $Body
            if ($ok) {
                Write-Host ("  [PASS] {0}" -f $Name) -ForegroundColor Green
                $script:SelfTestPass++
            } else {
                Write-Host ("  [FAIL] {0}" -f $Name) -ForegroundColor Red
                $script:SelfTestFail++
            }
        } catch {
            Write-Host ("  [FAIL] {0} -> {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
            $script:SelfTestFail++
        }
    }

    Write-Host ''
    Write-Host '================ 自检 (SelfTest) ================' -ForegroundColor Cyan
    Write-Host ("运行环境: PowerShell {0} / 架构 {1} / 管理员 {2}" -f $PSVersionTable.PSVersion, (Get-OSArchitecture), (Test-IsAdministrator))
    Write-Host ''

    Test-Case '多选输入解析: 单值/多值/区间/all/中文逗号' {
        $a = ConvertTo-Selection -Text '2' -Max 5
        $b = ConvertTo-Selection -Text '1,3,5' -Max 5
        $c = ConvertTo-Selection -Text '1-3' -Max 5
        $d = ConvertTo-Selection -Text 'all' -Max 3
        $e = ConvertTo-Selection -Text '1，2 4' -Max 5
        $f = ConvertTo-Selection -Text '1 2-4' -Max 5
        (($a -join ',') -eq '2') -and (($b -join ',') -eq '1,3,5') -and (($c -join ',') -eq '1,2,3') -and
        (($d -join ',') -eq '1,2,3') -and (($e -join ',') -eq '1,2,4') -and (($f -join ',') -eq '1,2,3,4')
    }

    Test-Case '多选输入解析: 非法输入必须被拒绝' {
        ($null -eq (ConvertTo-Selection -Text 'abc' -Max 5)) -and
        ($null -eq (ConvertTo-Selection -Text '0' -Max 5)) -and
        ($null -eq (ConvertTo-Selection -Text '6' -Max 5)) -and
        ($null -eq (ConvertTo-Selection -Text '' -Max 5)) -and
        ($null -eq (ConvertTo-Selection -Text '1;x' -Max 5))
    }

    Test-Case 'IPv4 校验' {
        (Test-ValidIPv4 '192.168.1.50') -and (Test-ValidIPv4 '10.0.0.1') -and
        (-not (Test-ValidIPv4 '999.1.1.1')) -and (-not (Test-ValidIPv4 'printer01')) -and
        (-not (Test-ValidIPv4 '')) -and (-not (Test-ValidIPv4 '2001:db8::1'))
    }

    Test-Case '打印机地址校验 (IP / 主机名)' {
        (Test-ValidPrinterAddress '192.168.1.50') -and (Test-ValidPrinterAddress 'PRINTER-01') -and
        (Test-ValidPrinterAddress 'print.company.local') -and (-not (Test-ValidPrinterAddress '打印机'))
    }

    Test-Case '连接类型识别: USB / 并口 / 共享 / TCP/IP / WSD / 虚拟' {
        $t1 = Resolve-ConnectionType -PortName 'USB001' -ServerName '' -ShareName '' -Network $false -Local $true -PortInfo $null -TcpPortInfo $null
        $t2 = Resolve-ConnectionType -PortName 'LPT1:' -ServerName '' -ShareName '' -Network $false -Local $true -PortInfo $null -TcpPortInfo $null
        $t3 = Resolve-ConnectionType -PortName '\\SRV\HP1108' -ServerName '' -ShareName '' -Network $true -Local $false -PortInfo $null -TcpPortInfo $null
        $t4 = Resolve-ConnectionType -PortName 'IP_10.1.1.9' -ServerName '' -ShareName '' -Network $true -Local $true -PortInfo $null -TcpPortInfo $null
        $t5 = Resolve-ConnectionType -PortName 'WSD-1234abcd-5678' -ServerName '' -ShareName '' -Network $true -Local $true -PortInfo $null -TcpPortInfo $null
        $t6 = Resolve-ConnectionType -PortName 'PORTPROMPT:' -ServerName '' -ShareName '' -Network $false -Local $true -PortInfo $null -TcpPortInfo $null
        $t7 = Resolve-ConnectionType -PortName 'Kingsoft Virtual Printer Port' -ServerName '' -ShareName '' -Network $false -Local $true -PortInfo $null -TcpPortInfo $null
        ($t1.Kind -eq 'USB 本地打印机') -and ($t2.Kind -match '并口') -and ($t3.IsShared) -and
        ($t4.Kind -eq 'TCP/IP 网络打印机') -and ($t4.Address -eq '10.1.1.9') -and
        ($t5.Kind -match 'WSD') -and ($t6.Kind -match '虚拟') -and ($t7.Kind -match '虚拟')
    }

    Test-Case '架构兼容性判断 (x64 / x86 / ARM64)' {
        $arch = Get-OSArchitecture
        if ($arch -eq 'x64') {
            (Test-DriverEnvironmentCompat 'Windows x64').Ok -and
            (-not (Test-DriverEnvironmentCompat 'Windows NT x86').Ok) -and
            (-not (Test-DriverEnvironmentCompat 'Windows ARM64').Ok) -and
            (Test-DriverEnvironmentCompat '').Ok
        } else {
            $true
        }
    }

    Test-Case 'INF 架构标记解析 (生成临时 INF)' {
        $tmp = Join-Path $env:TEMP ("pm_inf_test_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            $arch = Get-OSArchitecture
            $dec = 'NTamd64'
            if ($arch -eq 'ARM64') { $dec = 'NTarm64' }
            if ($arch -eq 'x86') { $dec = 'NTx86' }
            $other = 'NTarm64'
            if ($arch -eq 'ARM64') { $other = 'NTamd64' }
            $okInf = Join-Path $tmp 'ok.inf'
            $badInf = Join-Path $tmp 'bad.inf'
            $plainInf = Join-Path $tmp 'plain.inf'
            Set-Content -LiteralPath $okInf -Value "[Version]`r`nClass=Printer`r`n[Manufacturer]`r`n%M%=Sec,$dec" -Encoding ASCII
            Set-Content -LiteralPath $badInf -Value "[Version]`r`nClass=Printer`r`n[Manufacturer]`r`n%M%=Sec,$other" -Encoding ASCII
            Set-Content -LiteralPath $plainInf -Value "[Version]`r`nClass=Printer" -Encoding ASCII
            (Test-InfPlatform -InfPath $okInf).Ok -and
            (-not (Test-InfPlatform -InfPath $badInf).Ok) -and
            (Test-InfPlatform -InfPath $plainInf).Ok -and
            (-not (Test-InfPlatform -InfPath (Join-Path $tmp 'nope.inf')).Ok)
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case '中文+空格 路径 读写与清单往返 (JSON)' {
        $tmpRoot = Join-Path $env:TEMP ("打印机 备份 自检 " + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
        try {
            $manifest = [PSCustomObject][ordered]@{
                FormatVersion  = 1
                ToolName       = $script:ToolName
                ToolVersion    = $script:ToolVersion
                CreatedAt      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                SourceComputer = '测试电脑'
                SourceUser     = '测试用户'
                SourceOS       = [PSCustomObject]@{ Caption = 'Microsoft Windows 11 专业版'; Version = '10.0.26200'; Architecture = 'x64'; Is64Bit = $true; Build = '26200'; PSVersion = '5.1' }
                DriverPackages = @([PSCustomObject]@{ PublishedName = 'oem42.inf'; OriginalName = 'hp1234.inf'; RelativePath = 'Drivers\oem42'; FileCount = 1; TotalBytes = 10; TotalSizeText = '10 B'; DriverDate = '01/01/2020'; DriverVersion = '1.0.0.0'; InfFiles = @('hp1234.inf'); Environment = 'Windows x64'; UsedBy = @('测试打印机') })
                Printers       = @([PSCustomObject][ordered]@{
                    Name = '中文 打印机 名称'; DriverName = 'HP LaserJet 测试'; ModelName = 'HP LaserJet 测试'
                    Environment = 'Windows x64'; PortName = 'IP_192.168.1.88'; ConnectionType = 'TCP/IP 网络打印机'
                    IsUsb = $false; IsNetwork = $true; IsShared = $false; SharePath = ''; ServerName = ''
                    Address = '192.168.1.88'; PortNumber = 9100; Protocol = 'RAW'; IsDefault = $false
                    Comment = '三楼 备注'; Location = '三楼东侧'
                    DriverStatus = '可导出'; DriverMessage = 'ok'; DriverPublishedName = 'oem42.inf'
                    DriverOriginalName = 'hp1234.inf'; DriverInfFile = 'hp1234.inf'; DriverEnvironment = 'Windows x64'
                    DriverFilePathRef = ''; PackageRelativePath = 'Drivers\oem42'; BackupGrade = '完整备份'
                    GradeReason = '驱动包已导出并通过身份/完整性/签名校验'
                })
                Summary        = [PSCustomObject]@{ Total = 1; Complete = 1; Partial = 0; NotMigratable = 0; Result = '成功' }
            }
            $p = Save-BackupManifest -Root $tmpRoot -Manifest $manifest
            $p2 = Save-BackupSummaryText -Root $tmpRoot -Manifest $manifest
            $again = Read-BackupManifest -Root $tmpRoot
            $pr = @($again.Manifest.Printers)
            $again.Ok -and (Test-Path -LiteralPath $p) -and (Test-Path -LiteralPath $p2) -and
            ($pr.Count -eq 1) -and ($pr[0].Name -eq '中文 打印机 名称') -and
            ($pr[0].Address -eq '192.168.1.88') -and (@($again.Manifest.DriverPackages).Count -eq 1) -and
            ((Get-Content -LiteralPath $p2 -Raw -Encoding UTF8) -match '中文 打印机 名称')
        } finally {
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case '备份目录缺失时恢复流程应给出明确错误 (不安装任何驱动)' {
        $tmpRoot = Join-Path $env:TEMP ("pm_nodir_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
        try {
            $r = Read-BackupManifest -Root $tmpRoot
            (-not $r.Ok) -and ($r.Message -match '不存在')
        } finally {
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case 'pnputil 可用性与驱动包枚举 (只读)' {
        $pkgs = @(Get-DriverStorePackages -Force)
        (Test-Path -LiteralPath $script:PnPUtilPath) -and ($null -ne $script:DriverStoreCache)
    }

    Test-Case '驱动包定位: 内置驱动识别为系统内置、未知 INF 不猜成成功' {
        # 使用确定不在系统驱动库里的名称，保证结果与环境无关
        $a = Resolve-DriverPackageName -InfFileName 'prnms999zzz.inf' -InfPath 'C:\Windows\INF\prnms999zzz.inf'
        $b = Resolve-DriverPackageName -InfFileName 'ntprintzzz.inf' -InfPath 'C:\Windows\INF\ntprintzzz.inf'
        $c = Resolve-DriverPackageName -InfFileName 'oem99999.inf' -InfPath 'C:\Windows\INF\oem99999.inf'
        $d = Resolve-DriverPackageName -InfFileName 'vendor_unknown_driver.inf' -InfPath 'C:\Windows\System32\spool\DRIVERS\x64\3\vendor.dll'
        ($a.Status -eq '系统内置') -and ($b.Status -eq '系统内置') -and
        ($c.Status -eq '无法定位') -and ($d.Status -eq '无法定位') -and
        (-not $a.IsExportable) -and (-not $c.IsExportable) -and (-not $d.IsExportable)
    }

    Test-Case '驱动包定位: 系统驱动库中的包必须能按原始 INF 名称反查' {
        $pkgs = @(Get-DriverStorePackages)
        if ($pkgs.Count -eq 0) {
            Write-Host '        本机没有第三方驱动包，跳过反查测试。' -ForegroundColor DarkGray
            return $true
        }
        $target = $pkgs[0]
        $r = Resolve-DriverPackageName -InfFileName ([string]$target.OriginalName) -InfPath ('C:\Windows\INF\' + [string]$target.PublishedName)
        $r.IsExportable -and ($r.PublishedName -ieq [string]$target.PublishedName)
    }

    Test-Case '驱动包枚举格式: 发布名为 oemN.inf 且原始名非空' {
        $pkgs = @(Get-DriverStorePackages)
        if ($pkgs.Count -eq 0) { return $true }
        $bad = @($pkgs | Where-Object { [string]$_.PublishedName -notmatch '^oem\d+\.inf$' -or [string]::IsNullOrWhiteSpace([string]$_.OriginalName) })
        if ($bad.Count -gt 0) { Write-Host ("        异常记录: " + (($bad | ForEach-Object { $_.PublishedName }) -join ', ')) -ForegroundColor DarkGray }
        $bad.Count -eq 0
    }

    Test-Case '端口与外部工具路径存在性' {
        (Test-Path -LiteralPath $script:PnPUtilPath) -and
        (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\rundll32.exe'))
    }

    Test-Case '环境健康: 数字签名检查命令可用 (PS7 模块路径污染检测)' {
        $ok = Test-AuthenticodeAvailable
        if (-not $ok) {
            Write-Host ("        PSModulePath=$($env:PSModulePath)") -ForegroundColor DarkGray
            Write-Host '        请用 Printer_Migration.bat 启动（启动器会修正 PSModulePath），' -ForegroundColor DarkGray
            Write-Host '        或以管理员身份运行: Import-Module Microsoft.PowerShell.Security' -ForegroundColor DarkGray
        }
        $ok
    }

    Test-Case '格式大小与 WQL 名称转义' {
        (Format-Size 0) -eq '0 B'
    }

    # ---- 以下为针对已修复缺陷的定向测试 ----

    Test-Case '[缺陷1] 驱动身份校验: 同名多包必须靠版本唯一确认，否则禁止自动导出' {
        $g = {
            param($pub, $orig, $ver)
            [PSCustomObject]@{ PublishedName = $pub; OriginalName = $orig; DriverDate = ''; DriverVersion = $ver }
        }
        $two = @(
            (& $g 'oem10.inf' 'rtkfilter.inf' '2.8.1063.3005'),
            (& $g 'oem41.inf' 'rtkfilter.inf' '3.8.1067.3030')
        )
        $a = Resolve-DriverPackageName -InfFileName 'rtkfilter.inf' -InfPath 'C:\Windows\INF\rtkfilter.inf_amd64_x\rtkfilter.inf' -ExpectedVersion '2.8.1063.3005' -Packages $two
        $b = Resolve-DriverPackageName -InfFileName 'rtkfilter.inf' -InfPath 'x' -ExpectedVersion '9.9.9.9' -Packages $two
        $c = Resolve-DriverPackageName -InfFileName 'rtkfilter.inf' -InfPath 'x' -Packages $two
        $same = @(
            (& $g 'oem0.inf' 'rtscrextpr.inf' '10.0.22000.1'),
            (& $g 'oem25.inf' 'rtscrextpr.inf' '10.0.22000.1')
        )
        $f = Resolve-DriverPackageName -InfFileName 'rtscrextpr.inf' -InfPath 'x' -ExpectedVersion '10.0.22000.1' -Packages $same
        $d = Resolve-DriverPackageName -InfFileName 'rtkfilter.inf' -InfPath 'C:\Windows\INF\rtkfilter.inf_amd64_x\rtkfilter.inf' -ExpectedVersion '3.8.1067.3030' -Packages @((& $g 'oem41.inf' 'rtkfilter.inf' '3.8.1067.3030'))
        $e = Resolve-DriverPackageName -InfFileName 'rtkfilter.inf' -InfPath 'x' -ExpectedVersion '1.0.0.0' -Packages @((& $g 'oem10.inf' 'rtkfilter.inf' '2.8.1063.3005'))
        ($a.IsExportable -and $a.PublishedName -eq 'oem10.inf') -and
        (-not $b.IsExportable -and $b.Status -eq '身份不符') -and
        (-not $c.IsExportable -and $c.Status -eq '存在歧义') -and
        (-not $f.IsExportable -and $f.Status -eq '存在歧义') -and
        ($d.IsExportable -and $d.PublishedName -eq 'oem41.inf') -and
        (-not $e.IsExportable -and $e.Status -eq '身份不符')
    }

    Test-Case '[缺陷1] 驱动身份校验(真实驱动库数据): 同名多包不得选错版本' {
        $pkgs = @(Get-DriverStorePackages)
        $groups = @($pkgs | Group-Object { ([string]$_.OriginalName).ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })
        if ($groups.Count -eq 0) {
            Write-Host '        本机驱动库没有同名多包，跳过该真实数据用例。' -ForegroundColor DarkGray
            return $true
        }
        $ok = $true
        foreach ($grp in $groups) {
            $first = $grp.Group[0]
            $sameVer = @($grp.Group | Where-Object { [string]$_.DriverVersion -eq [string]$first.DriverVersion })
            $rGood = Resolve-DriverPackageName -InfFileName ([string]$first.OriginalName) -InfPath 'x' -ExpectedVersion ([string]$first.DriverVersion) -Packages $pkgs
            if ($sameVer.Count -eq 1) {
                if (-not ($rGood.IsExportable -and $rGood.PublishedName -ieq [string]$first.PublishedName)) { $ok = $false }
            } else {
                if (-not ((-not $rGood.IsExportable) -and $rGood.Status -eq '存在歧义')) { $ok = $false }
            }
            $rBad = Resolve-DriverPackageName -InfFileName ([string]$first.OriginalName) -InfPath 'x' -ExpectedVersion '0.0.0.0.0' -Packages $pkgs
            if ($rBad.IsExportable) { Write-Host ("        意外可导出: " + [string]$first.OriginalName) -ForegroundColor DarkGray; $ok = $false }
        }
        Write-Host ("        已用真实驱动库检查 {0} 组同名原始 INF" -f $groups.Count) -ForegroundColor DarkGray
        $ok
    }

    Test-Case '[缺陷2] 驱动入库核验: 使用系统驱动库 INF 路径 (Windows\INF\oemNN.inf)' {
        $pkgs = @(Get-DriverStorePackages)
        if ($pkgs.Count -eq 0) { return $true }
        $t = $null
        foreach ($cand in $pkgs) {
            $same = @($pkgs | Where-Object { [string]$_.OriginalName -ieq [string]$cand.OriginalName -and [string]$_.DriverVersion -eq [string]$cand.DriverVersion })
            if ($same.Count -eq 1) { $t = $cand; break }
        }
        if ($null -eq $t) { return $true }
        $f = Find-StagedDriverPackage -OriginalName ([string]$t.OriginalName) -ExpectedVersion ([string]$t.DriverVersion) -Packages $pkgs
        $expectPath = Join-Path (Join-Path $env:SystemRoot 'INF') ([string]$t.PublishedName)
        $missing = Find-StagedDriverPackage -OriginalName 'no_such_driver_xyz.inf' -Packages $pkgs
        $f.Ok -and ($f.StagedInfPath -ieq $expectPath) -and (Test-Path -LiteralPath $f.StagedInfPath) -and (-not $missing.Ok)
    }

    Test-Case '[缺陷2] 区分驱动入库与打印后台注册两个函数' {
        (Get-Command Install-DriverPackage) -and (Get-Command Register-PrinterDriver) -and
        (Get-Command Test-PrinterDriverRegistered) -and (Get-Command Find-StagedDriverPackage) -and
        ((Get-Command Install-DriverPackage).Parameters.Keys -contains 'ExpectedOriginalName') -and
        ((Get-Command Register-PrinterDriver).Parameters.Keys -contains 'ExpectedInfName')
    }

    Test-Case '[缺陷2] 打印后台注册核验(只读): 能识别已注册驱动并核对关联 INF' {
        $list = @()
        try { $list = @(Get-PrinterDriver -ErrorAction SilentlyContinue | Where-Object { $_.InfPath }) } catch { $list = @() }
        if ($list.Count -eq 0) {
            Write-Host '        本机没有带 INF 的打印驱动，跳过。' -ForegroundColor DarkGray
            return $true
        }
        $d = $list[0]
        $infName = Split-Path -Leaf ([string]$d.InfPath)
        $hit = Test-PrinterDriverRegistered -ModelName ([string]$d.Name) -ExpectedInfName $infName
        $miss = Test-PrinterDriverRegistered -ModelName 'no_such_printer_driver_xyz' -ExpectedInfName 'x.inf'
        if (-not ($hit.Registered -and $hit.Matched)) {
            Write-Host ("        核验结果: " + [string]$hit.Message) -ForegroundColor DarkGray
        }
        ($hit.Registered -and $hit.Matched) -and (-not $miss.Registered)
    }

    Test-Case '[缺陷3] 网络端口计划: 区分 RAW / LPR，缺参数转手动' {
        $mk = {
            param($addr, $proto, $pn, $queue, $port)
            [PSCustomObject][ordered]@{ Address = $addr; Protocol = $proto; PortNumber = $pn; LprQueueName = $queue; PortName = $port }
        }
        $raw = Get-NetworkPortPlan -Printer (& $mk '10.1.1.9' 'RAW' 9100 '' 'IP_10.1.1.9')
        $rawDefault = Get-NetworkPortPlan -Printer (& $mk '10.1.1.9' '' 0 '' '')
        $lpr = Get-NetworkPortPlan -Printer (& $mk '10.1.1.9' 'LPR' 0 'print' '10.1.1.9')
        $lprNoQueue = Get-NetworkPortPlan -Printer (& $mk '10.1.1.9' 'LPR' 0 '' '')
        $noAddr = Get-NetworkPortPlan -Printer (& $mk '' 'RAW' 9100 '' '')
        $other = Get-NetworkPortPlan -Printer (& $mk '10.1.1.9' 'IPP' 631 '' '')
        ($raw.Ok -and $raw.Protocol -eq 'RAW' -and $raw.PortName -eq 'IP_10.1.1.9' -and $raw.PortNumber -eq 9100) -and
        ($rawDefault.Ok -and $rawDefault.Protocol -eq 'RAW' -and $rawDefault.PortNumber -eq 9100) -and
        ($lpr.Ok -and $lpr.Protocol -eq 'LPR' -and $lpr.LprQueueName -eq 'print' -and $lpr.PortName -eq '10.1.1.9') -and
        ((-not $lprNoQueue.Ok) -and ([string]$lprNoQueue.Reason -match 'LPR')) -and
        (-not $noAddr.Ok) -and (-not $other.Ok)
    }

    Test-Case '[缺陷4] 备份结论: 只有全部完整才算成功' {
        ((Get-OverallBackupResult -Complete 2 -Partial 0 -NotMigratable 0) -eq '成功') -and
        ((Get-OverallBackupResult -Complete 1 -Partial 1 -NotMigratable 0) -eq '部分成功') -and
        ((Get-OverallBackupResult -Complete 0 -Partial 2 -NotMigratable 0) -eq '部分成功') -and
        ((Get-OverallBackupResult -Complete 1 -Partial 0 -NotMigratable 1) -eq '部分成功') -and
        ((Get-OverallBackupResult -Complete 0 -Partial 0 -NotMigratable 2) -eq '失败') -and
        ((Get-OverallBackupResult -Complete 2 -Partial 0 -NotMigratable 0 -VerifyFailed) -eq '部分成功')
    }

    Test-Case '[新结构] 备份三级判定: 完整/部分/不可迁移' {
        # 完整: 驱动包就绪+签名通过+网络有IP
        $a = Get-PrinterBackupGrade -PackageReady $true -DriverStatus '可导出' -SignatureOk $true -IsNetwork $true -IsShared $false -HasValidAddress $true -Protocol 'RAW' -LprQueueName ''
        # 部分: 驱动包就绪但网络没有 IP
        $b = Get-PrinterBackupGrade -PackageReady $true -DriverStatus '可导出' -SignatureOk $true -IsNetwork $true -IsShared $false -HasValidAddress $false -Protocol 'RAW' -LprQueueName ''
        # 部分: LPR 缺队列名
        $c = Get-PrinterBackupGrade -PackageReady $true -DriverStatus '可导出' -SignatureOk $true -IsNetwork $true -IsShared $false -HasValidAddress $true -Protocol 'LPR' -LprQueueName ''
        # 部分: 共享打印机(需人工连接)
        $d = Get-PrinterBackupGrade -PackageReady $true -DriverStatus '可导出' -SignatureOk $true -IsNetwork $true -IsShared $true -HasValidAddress $true -Protocol 'RAW' -LprQueueName ''
        # 部分: 系统自带驱动，没有驱动文件
        $e = Get-PrinterBackupGrade -PackageReady $false -DriverStatus '系统内置' -SignatureOk $false -IsNetwork $false -IsShared $false -HasValidAddress $false -Protocol '' -LprQueueName ''
        # 不可迁移: 无法定位驱动包 / 签名不通过
        $f = Get-PrinterBackupGrade -PackageReady $false -DriverStatus '无法定位' -SignatureOk $false -IsNetwork $false -IsShared $false -HasValidAddress $false -Protocol '' -LprQueueName ''
        $g = Get-PrinterBackupGrade -PackageReady $true -DriverStatus '可导出' -SignatureOk $false -IsNetwork $false -IsShared $false -HasValidAddress $false -Protocol '' -LprQueueName ''
        ($a.Grade -eq '完整备份') -and ($b.Grade -eq '部分备份') -and ($c.Grade -eq '部分备份') -and
        ($d.Grade -eq '部分备份') -and ($e.Grade -eq '部分备份') -and
        ($f.Grade -eq '不可迁移') -and ($g.Grade -eq '不可迁移') -and
        (-not [string]::IsNullOrWhiteSpace($a.Reason))
    }

    Test-Case '[新结构] 恢复数据目录自动识别（程序和数据同目录 / 上级目录）' {
        $base = Join-Path $env:TEMP ("pm_root_" + [guid]::NewGuid().ToString('N'))
        $sub = Join-Path $base 'Printer_Backup'
        $empty = Join-Path $base 'Empty'
        try {
            New-Item -ItemType Directory -Force -Path $sub, $empty | Out-Null
            # 找不到任何清单 -> 空字符串
            $none = Resolve-BackupDataRoot -Candidates @($empty)
            # 数据在子目录 Printer_Backup -> 命中子目录
            Set-Content -LiteralPath (Join-Path $sub 'Printers.json') -Value '{}' -Encoding UTF8
            $viaSub = Resolve-BackupDataRoot -Candidates @($base, $sub)
            # 程序与数据同目录（打包后的备份文件夹）-> 命中自身
            $same = Resolve-BackupDataRoot -Candidates @($sub)
            ([string]::IsNullOrWhiteSpace($none)) -and
            (-not [string]::IsNullOrWhiteSpace($viaSub)) -and ((Split-Path -Leaf $viaSub) -eq 'Printer_Backup') -and
            ($same -eq $viaSub)
        } finally {
            Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case '[新结构] 校验清单: 生成、通过、篡改必被发现' {
        $root = Join-Path $env:TEMP ("pm_cs_" + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $root 'Drivers\oem9') | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'Drivers\oem9\a.inf') -Value 'abc' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $root 'Drivers\oem9\a.dll') -Value 'defg' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $root 'Printers.json') -Value '{}' -Encoding UTF8
            $w = Write-ChecksumManifest -Root $root -RelativePaths @('Drivers\oem9', 'Printers.json')
            $ok1 = Test-ChecksumManifest -Root $root
            # 篡改文件内容 -> 必须检出
            Set-Content -LiteralPath (Join-Path $root 'Drivers\oem9\a.dll') -Value 'TAMPERED' -Encoding ASCII
            $ok2 = Test-ChecksumManifest -Root $root
            # 删除文件 -> 必须检出
            Remove-Item -LiteralPath (Join-Path $root 'Drivers\oem9\a.inf') -Force
            $ok3 = Test-ChecksumManifest -Root $root
            $w.Ok -and ($w.FileCount -eq 3) -and $ok1.Ok -and
            (-not $ok2.Ok) -and (@($ok2.Mismatch).Count -ge 1) -and
            (-not $ok3.Ok) -and (@($ok3.Missing).Count -ge 1) -and
            (Test-Path -LiteralPath (Join-Path $root '校验清单.txt'))
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case '[新结构] 恢复程序打包: 02 BAT + 核心脚本进备份目录' {
        $root = Join-Path $env:TEMP ("pm_pack_" + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            $r = Publish-RestorePackage -Root $root -CoreDir $script:BaseDir
            $batOk = Test-Path -LiteralPath (Join-Path $root '02_恢复打印机.bat')
            $coreOk = Test-Path -LiteralPath (Join-Path $root 'Printer_Migration.ps1')
            if (-not $r.Ok) { Write-Host ("        打包缺少: " + ((@($r.Missing)) -join ', ')) -ForegroundColor DarkGray }
            $r.Ok -and $batOk -and $coreOk
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case '[新结构] 网络连接条件检查(只读, 不阻断)' {
        $c = Test-NetworkTargetReachable -Address '127.0.0.1' -Protocol 'RAW' -PortNumber 54321
        $c.Checked -and $c.PingOk -and (-not [string]::IsNullOrWhiteSpace($c.Message)) -and
        ((Test-NetworkTargetReachable -Address '').Checked -eq $false)
    }

    Test-Case '[缺陷5] 重新备份安全: 验证失败不动原备份，验证通过才替换' {
        $tmp = Join-Path $env:TEMP ('pm_pub_' + [guid]::NewGuid().ToString('N'))
        $target = Join-Path $tmp 'oem99'
        $badStage = Join-Path $tmp 'stage_bad'
        $goodStage = Join-Path $tmp 'stage_good'
        try {
            New-Item -ItemType Directory -Force -Path $target, $badStage, $goodStage | Out-Null
            Set-Content -LiteralPath (Join-Path $target 'old.inf') -Value 'old'
            Set-Content -LiteralPath (Join-Path $badStage 'readme.txt') -Value 'no inf here'
            Set-Content -LiteralPath (Join-Path $goodStage 'new.inf') -Value 'new'
            $r1 = Publish-StagedDriverPackage -StagingDir $badStage -TargetDir $target
            $oldKept = Test-Path -LiteralPath (Join-Path $target 'old.inf')
            $r2 = Publish-StagedDriverPackage -StagingDir $goodStage -TargetDir $target
            $newIn = Test-Path -LiteralPath (Join-Path $target 'new.inf')
            $leftover = @(Get-ChildItem -LiteralPath $tmp -Directory -Force | Where-Object { $_.Name -like 'oem99.old_*' }).Count
            ($r1.Ok -eq $false) -and $oldKept -and $r2.Ok -and $newIn -and ($leftover -eq 0)
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case '[缺陷7] 先查打印机是否存在: 已存在同名打印机时不得创建端口' {
        $inv = @(Get-PrinterInventory)
        if ($inv.Count -eq 0) {
            Write-Host '        本机没有打印机，跳过(需要一台已存在的同名打印机)。' -ForegroundColor DarkGray
            return $true
        }
        $testPort = 'IP_192.0.2.99'   # RFC5737 文档地址，仅用于测试名称
        $fake = [PSCustomObject][ordered]@{
            Name = [string]$inv[0].Name; Address = '192.0.2.99'; PortNumber = 9100
            Protocol = 'RAW'; LprQueueName = ''; PortName = $testPort
        }
        $q = New-TcpPrinterQueue -Printer $fake -InfPath '' -ModelName 'x'
        $created = $false
        try { if (Get-PrinterPort -Name ([WildcardPattern]::Escape($testPort)) -ErrorAction SilentlyContinue) { $created = $true } } catch { }
        if ($created) {
            try { Remove-PrinterPort -Name ([WildcardPattern]::Escape($testPort)) -ErrorAction Stop } catch { }
            Write-Host "        意外创建了端口 $testPort，已尝试清理" -ForegroundColor DarkGray
            return $false
        }
        ((-not $q.Ok) -and ([string]$q.Message -match '已存在同名打印机'))
    }

    Test-Case '枚举本机打印机 (只读, 不修改系统)' {
        $inv = @(Get-PrinterInventory)
        foreach ($p in $inv) {
            if ([string]::IsNullOrWhiteSpace([string]$p.Name)) { return $false }
            if ([string]::IsNullOrWhiteSpace([string]$p.ConnectionType)) { return $false }
        }
        Write-Host ("        检测到 {0} 台打印机: {1}" -f $inv.Count, ((@($inv | ForEach-Object { $_.Name })) -join ' / ')) -ForegroundColor DarkGray
        $true
    }

    Write-Host ''
    Write-Host ("自检结果: 通过 $($script:SelfTestPass) 项, 失败 $($script:SelfTestFail) 项") -ForegroundColor $(if ($script:SelfTestFail -eq 0) { 'Green' } else { 'Red' })
    Write-Host '=================================================' -ForegroundColor Cyan
    if ($script:SelfTestFail -gt 0) { exit 1 }
    exit 0
}

#endregion

#region ---------------- 主程序 ----------------

function Show-Usage {
    Write-Host ''
    Write-Host '本文件是"打印机迁移工具"的公共核心脚本，必须由下面两个入口 BAT 调用：' -ForegroundColor Yellow
    Write-Host '  旧电脑（公司电脑）: 双击  01_备份打印机.bat'
    Write-Host '  新电脑（个人电脑）: 双击  备份文件夹里的  02_恢复打印机.bat'
    Write-Host ''
    Write-Host '请不要直接双击本 .ps1 文件（会被执行策略拦截，且缺少参数）。'
    Write-Host '自检: 01_备份打印机.bat -SelfTest  或  02_恢复打印机.bat -SelfTest'
}

function Invoke-Safe {
    param([scriptblock]$Action)
    try {
        & $Action
    } catch {
        Write-Log "操作中断: $($_.Exception.Message)" 'ERROR'
        Write-LogFile ([string]$_.ScriptStackTrace)
    }
}

function Main {
    Initialize-Console
    if ($SelfTest) { Invoke-SelfTest; return }

    $script:IsElevated = Test-IsAdministrator

    if ($Action -eq 'None') {
        Write-Banner
        Show-Usage
        Pause-Continue '按回车键退出'
        Exit-Tool 2
    }

    Write-Banner
    if ($script:IsElevated) {
        Write-Log '当前已获得管理员权限。' 'OK'
    } else {
        Write-Log '当前未以管理员身份运行（需要时会请求提权）。' 'WARN'
    }

    Write-Host ''
    if ($Action -eq 'Backup') {
        Write-Log '本次运行: 【备份】模式（旧电脑）' 'STEP'
        Invoke-Safe { Invoke-BackupFlow }
    } elseif ($Action -eq 'Restore') {
        Write-Log '本次运行: 【恢复】模式（新电脑）' 'STEP'
        Invoke-Safe { Invoke-RestoreFlow }
    }

    # 结束时停留，方便查看结果（提权窗口与 BAT 窗口都需要）
    Write-Host ''
    Pause-Continue '按回车键关闭窗口'
    Exit-Tool 0
}

Main

#endregion
