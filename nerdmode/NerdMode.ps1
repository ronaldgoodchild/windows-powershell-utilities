#requires -Version 5.1
<#
    Nerd Mode - Windows System Inspector
    Read-only system telemetry dashboard. Never modifies settings, kills
    processes, deletes files, changes services, or alters network config.

    Launch:  powershell.exe -ExecutionPolicy Bypass -File NerdMode.ps1
    No administrator rights required.
#>

# --- STA guard: WPF requires an STA thread. Relaunch if we aren't one. ---
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    )
    exit
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms

# All telemetry in this app is gathered via pure .NET/Win32 APIs (DriveInfo,
# NetworkInterface, PerformanceCounter, GlobalMemoryStatusEx, registry reads,
# SystemInformation.PowerStatus) rather than WMI/CIM - deliberately avoids any
# dependency on the WMI service, which can be slow, blocked, or hang on some
# machines depending on local policy/security software.
Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NmNative {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct MEMORYSTATUSEX {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);
}
"@

function Get-NmMemoryStatus {
    $ms = New-Object NmNative+MEMORYSTATUSEX
    $ms.dwLength = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf([type][NmNative+MEMORYSTATUSEX])
    $ok = [NmNative]::GlobalMemoryStatusEx([ref]$ms)
    if (-not $ok) { return $null }
    return $ms
}

# Disk and network enumeration run here, entirely in C# on a raw System.Threading.Thread
# with a ManualResetEvent timeout - deliberately NOT via a nested PowerShell runspace
# (an earlier [PowerShell]::Create()-based timeout wrapper proved unreliable: something
# about spinning up a second runspace from inside this WPF/STA process meant its
# WaitOne() didn't reliably return within the timeout on all machines). Plain .NET
# threading primitives have no such ambiguity - WaitOne(ms) always returns on time.
Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.IO;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Threading;
using System.Collections.Generic;

public class NmDiskRow {
    public string Drive;
    public string Label;
    public long TotalBytes;
    public long FreeBytes;
}

public class NmNetRow {
    public string Name;
    public string Status;
    public string IPv4;
    public double SpeedMbps;
    public long BytesSent;
    public long BytesReceived;
}

public static class NmBackground {
    public static List<NmDiskRow> GetDisks(int timeoutMs) {
        List<NmDiskRow> result = null;
        ManualResetEvent done = new ManualResetEvent(false);
        Thread t = new Thread(delegate() {
            try {
                List<NmDiskRow> list = new List<NmDiskRow>();
                foreach (DriveInfo d in DriveInfo.GetDrives()) {
                    try {
                        if (d.DriveType == DriveType.Fixed && d.IsReady) {
                            list.Add(new NmDiskRow { Drive = d.Name, Label = d.VolumeLabel, TotalBytes = d.TotalSize, FreeBytes = d.AvailableFreeSpace });
                        }
                    } catch { }
                }
                result = list;
            } catch { }
            finally { done.Set(); }
        });
        t.IsBackground = true;
        t.Start();
        if (!done.WaitOne(timeoutMs)) return null;
        return result;
    }

    public static List<NmNetRow> GetAdapters(int timeoutMs) {
        List<NmNetRow> result = null;
        ManualResetEvent done = new ManualResetEvent(false);
        Thread t = new Thread(delegate() {
            try {
                List<NmNetRow> list = new List<NmNetRow>();
                foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces()) {
                    try {
                        if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                        string ip = null;
                        try {
                            foreach (UnicastIPAddressInformation ua in nic.GetIPProperties().UnicastAddresses) {
                                if (ua.Address.AddressFamily == AddressFamily.InterNetwork) { ip = ua.Address.ToString(); break; }
                            }
                        } catch { }
                        long sent = 0, recv = 0;
                        try {
                            IPv4InterfaceStatistics st = nic.GetIPv4Statistics();
                            sent = st.BytesSent; recv = st.BytesReceived;
                        } catch { }
                        list.Add(new NmNetRow {
                            Name = nic.Name,
                            Status = nic.OperationalStatus.ToString(),
                            IPv4 = ip,
                            SpeedMbps = nic.Speed > 0 ? nic.Speed / 1000000.0 : 0,
                            BytesSent = sent,
                            BytesReceived = recv
                        });
                    } catch { }
                }
                result = list;
            } catch { }
            finally { done.Set(); }
        });
        t.IsBackground = true;
        t.Start();
        if (!done.WaitOne(timeoutMs)) return null;
        return result;
    }
}
"@

# --- Brand palette (frozen brushes for reuse, both in XAML resources and code-behind) ---
function New-NmBrush([byte]$R, [byte]$G, [byte]$B) {
    $brush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb($R, $G, $B))
    $brush.Freeze()
    return $brush
}
$script:BrushAccent   = New-NmBrush 0x33 0x85 0xFF
$script:BrushGreen    = New-NmBrush 0x50 0xDC 0x82
$script:BrushAmber    = New-NmBrush 0xFF 0xAA 0x3C
$script:BrushRed      = New-NmBrush 0xFF 0x5A 0x5A
$script:BrushText     = New-NmBrush 0xE8 0xEA 0xED
$script:BrushTextDim  = New-NmBrush 0x8B 0x93 0xA7
$script:BrushTrack    = New-NmBrush 0x22 0x28 0x38
$script:BrushWisdom   = New-NmBrush 0xC9 0x7C 0xF0

function Get-NmThresholdBrush {
    param([double]$Percent)
    if ($Percent -ge 90) { return $script:BrushRed }
    elseif ($Percent -ge 75) { return $script:BrushAmber }
    else { return $script:BrushGreen }
}

function Get-NmBatteryBrush {
    param([double]$Percent)
    if ($Percent -le 20) { return $script:BrushRed }
    elseif ($Percent -le 50) { return $script:BrushAmber }
    else { return $script:BrushGreen }
}

function Format-NmRate {
    param([double]$BytesPerSec)
    if ($BytesPerSec -ge 1MB) { return "{0:N1} MB/s" -f ($BytesPerSec / 1MB) }
    else { return "{0:N0} KB/s" -f ($BytesPerSec / 1KB) }
}

function Format-NmBytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    else { return "{0:N0} KB" -f ($Bytes / 1KB) }
}

# Renders a two-tone block-character meter bar ("████████░░░░") into a TextBlock's Inlines.
function Set-NmMeterBar {
    param(
        [System.Windows.Controls.TextBlock]$TextBlock,
        [double]$Percent,
        [System.Windows.Media.Brush]$FillBrush,
        [int]$Width = 26
    )
    $filled = [int][math]::Round(($Percent / 100) * $Width)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $Width) { $filled = $Width }
    $empty = $Width - $filled
    $TextBlock.Inlines.Clear()
    if ($filled -gt 0) {
        $runFilled = New-Object System.Windows.Documents.Run ([string]([char]0x2588) * $filled)
        $runFilled.Foreground = $FillBrush
        $TextBlock.Inlines.Add($runFilled)
    }
    if ($empty -gt 0) {
        $runEmpty = New-Object System.Windows.Documents.Run ([string]([char]0x2591) * $empty)
        $runEmpty.Foreground = $script:BrushTrack
        $TextBlock.Inlines.Add($runEmpty)
    }
}

# Builds one dynamic sensor row (label + meter bar + value) for the Temperature/Fan panels,
# whose item count isn't known until runtime.
function New-NmSensorRow {
    param([string]$Label, [string]$ValueText, [double]$Percent)
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '0,3,0,3'
    $col1 = New-Object System.Windows.Controls.ColumnDefinition
    $col1.Width = New-Object System.Windows.GridLength(120)
    $col2 = New-Object System.Windows.Controls.ColumnDefinition
    $col2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $col3 = New-Object System.Windows.Controls.ColumnDefinition
    $col3.Width = New-Object System.Windows.GridLength(70)
    [void]$grid.ColumnDefinitions.Add($col1)
    [void]$grid.ColumnDefinitions.Add($col2)
    [void]$grid.ColumnDefinitions.Add($col3)

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = $Label
    $lbl.FontFamily = 'Consolas'
    $lbl.FontSize = 11
    $lbl.Foreground = $script:BrushTextDim
    $lbl.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($lbl, 0)

    $bar = New-Object System.Windows.Controls.TextBlock
    $bar.FontFamily = 'Consolas'
    $bar.FontSize = 11
    $bar.VerticalAlignment = 'Center'
    Set-NmMeterBar -TextBlock $bar -Percent $Percent -FillBrush (Get-NmThresholdBrush -Percent $Percent) -Width 18
    [System.Windows.Controls.Grid]::SetColumn($bar, 1)

    $val = New-Object System.Windows.Controls.TextBlock
    $val.Text = $ValueText
    $val.FontFamily = 'Consolas'
    $val.FontSize = 11
    $val.Foreground = $script:BrushText
    $val.HorizontalAlignment = 'Right'
    $val.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($val, 2)

    [void]$grid.Children.Add($lbl)
    [void]$grid.Children.Add($bar)
    [void]$grid.Children.Add($val)
    return $grid
}

# Bind arbitrary PSCustomObject rows to a WPF DataGrid via System.Data.DataTable
# (WPF's binding engine resolves DataRowView columns reliably; PSCustomObject
# properties are not guaranteed to bind the same way).
function ConvertTo-NmDataTable {
    param([array]$InputObject)
    $table = New-Object System.Data.DataTable
    if ($InputObject -and $InputObject.Count -gt 0) {
        foreach ($prop in $InputObject[0].PSObject.Properties) {
            [void]$table.Columns.Add($prop.Name, [string])
        }
        foreach ($item in $InputObject) {
            $row = $table.NewRow()
            foreach ($prop in $item.PSObject.Properties) {
                if ($null -eq $prop.Value) { $row[$prop.Name] = [DBNull]::Value }
                else { $row[$prop.Name] = [string]$prop.Value }
            }
            $table.Rows.Add($row)
        }
    }
    return $table
}

$script:WisdomQuotes = @(
    "The backup is only real after the restore test."
    "There is no cloud, just someone else's computer."
    "Ping before you panic."
    "Documentation you didn't write is documentation you don't trust."
    "Every 'quick fix' outlives the person who made it."
    "The most dangerous phrase in IT: 'it should just work.'"
    "Uptime is a vanity metric until it isn't."
    "Two is one, one is none, zero is an incident report."
    "If it's not monitored, it's not really running."
    "Change the default password. All of them."
    "A green dashboard doesn't mean nothing's wrong - it means nothing's alerting yet."
    "Read the error message. All of it. Twice."
    "The fastest fix is the one you don't have to explain twice."
    "Automate the boring parts; question the exciting ones."
    "Reboot fixes the symptom. Logs fix the problem."
    "Nobody reads the changelog until something breaks."
)

function Get-NmRandomWisdom {
    return $script:WisdomQuotes | Get-Random
}

# --- Telemetry functions: each is independently fault-tolerant. ---

function Get-NmCpuInfo {
    try {
        if (-not $script:CpuCounter) {
            $script:CpuCounter = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total')
            [void]$script:CpuCounter.NextValue()
            Start-Sleep -Milliseconds 200
        }
        $val = $script:CpuCounter.NextValue()
        return [PSCustomObject]@{ HasData = $true; PercentOverall = [math]::Round($val, 1) }
    } catch {
        return [PSCustomObject]@{ HasData = $false }
    }
}

function Get-NmMemoryInfo {
    try {
        $ms = Get-NmMemoryStatus
        if (-not $ms) { return [PSCustomObject]@{ HasData = $false } }
        $totalGB = $ms.ullTotalPhys / 1GB
        $freeGB = $ms.ullAvailPhys / 1GB
        $usedGB = $totalGB - $freeGB
        return [PSCustomObject]@{
            HasData     = $true
            TotalGB     = [math]::Round($totalGB, 2)
            UsedGB      = [math]::Round($usedGB, 2)
            FreeGB      = [math]::Round($freeGB, 2)
            PercentUsed = [math]::Round([double]$ms.dwMemoryLoad, 1)
        }
    } catch {
        return [PSCustomObject]@{ HasData = $false }
    }
}

function Get-NmDiskInfo {
    $result = @()
    $raw = $null
    try { $raw = [NmBackground]::GetDisks(2000) } catch {}
    if ($raw) {
        foreach ($d in $raw) {
            if ($d.TotalBytes -le 0) { continue }
            $usedBytes = $d.TotalBytes - $d.FreeBytes
            $pct = [math]::Round(($usedBytes / $d.TotalBytes) * 100, 1)
            $severity = if ($pct -ge 90) { 'Critical' } elseif ($pct -ge 75) { 'Warning' } else { 'Normal' }
            $label = if ($d.Label) { $d.Label } else { 'Local Disk' }
            $result += [PSCustomObject]@{
                Drive       = $d.Drive.TrimEnd('\')
                Label       = $label
                TotalGB     = [math]::Round($d.TotalBytes / 1GB, 1)
                UsedGB      = [math]::Round($usedBytes / 1GB, 1)
                FreeGB      = [math]::Round($d.FreeBytes / 1GB, 1)
                UsedPercent = $pct
                Severity    = $severity
            }
        }
    }
    if ($result.Count -eq 0) {
        $label = if ($null -eq $raw) { 'Disk check timed out' } else { 'Disk data unavailable' }
        $result = @([PSCustomObject]@{
            Drive = '-'; Label = $label; TotalGB = 0; UsedGB = 0; FreeGB = 0
            UsedPercent = 0; Severity = 'Warning'
        })
    }
    return $result
}

function Get-NmNetworkInfo {
    $now = Get-Date
    $elapsed = if ($script:PrevNetTime) { ($now - $script:PrevNetTime).TotalSeconds } else { 0 }
    $raw = $null
    try { $raw = [NmBackground]::GetAdapters(2000) } catch {}

    if ($null -eq $raw) {
        return @([PSCustomObject]@{
            Adapter = 'Network check timed out'; Status = '-'; IPv4 = '-'; LinkSpeed = '-'
            DownloadBps = 0; UploadBps = 0; TotalRxBytes = 0; TotalTxBytes = 0; Severity = 'Warning'
        })
    }

    $result = @()
    $newStats = @{}
    foreach ($nic in $raw) {
        $rxRate = 0; $txRate = 0
        if ($elapsed -gt 0 -and $script:PrevNetStats.ContainsKey($nic.Name)) {
            $prev = $script:PrevNetStats[$nic.Name]
            $rxRate = [math]::Max(0, ($nic.BytesReceived - $prev.Rx) / $elapsed)
            $txRate = [math]::Max(0, ($nic.BytesSent - $prev.Tx) / $elapsed)
        }
        $newStats[$nic.Name] = [PSCustomObject]@{ Rx = $nic.BytesReceived; Tx = $nic.BytesSent }

        $severity = if ($nic.Status -eq 'Up') { 'Normal' } else { 'Warning' }
        $linkSpeed = if ($nic.SpeedMbps -gt 0) { "{0:N0} Mbps" -f $nic.SpeedMbps } else { '-' }
        $result += [PSCustomObject]@{
            Adapter      = $nic.Name
            Status       = $nic.Status
            IPv4         = $(if ($nic.IPv4) { $nic.IPv4 } else { '-' })
            LinkSpeed    = $linkSpeed
            DownloadBps  = $rxRate
            UploadBps    = $txRate
            TotalRxBytes = $nic.BytesReceived
            TotalTxBytes = $nic.BytesSent
            Severity     = $severity
        }
    }
    $script:PrevNetStats = $newStats
    $script:PrevNetTime = $now

    if ($result.Count -eq 0) {
        $result = @([PSCustomObject]@{
            Adapter = 'Network data unavailable'; Status = '-'; IPv4 = '-'; LinkSpeed = '-'
            DownloadBps = 0; UploadBps = 0; TotalRxBytes = 0; TotalTxBytes = 0; Severity = 'Warning'
        })
    }
    return $result
}

function Get-NmSystemInfo {
    try {
        $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $osCaption = $cv.ProductName
        $displayVersion = if ($cv.DisplayVersion) { $cv.DisplayVersion } elseif ($cv.ReleaseId) { $cv.ReleaseId } else { '' }
        $ubr = $cv.UBR
        $fullBuild = if ($ubr) { "$($cv.CurrentBuildNumber).$ubr" } else { "$($cv.CurrentBuildNumber)" }
        $arch = if ([System.Environment]::Is64BitOperatingSystem) { '64-bit' } else { '32-bit' }

        $cpuModel = $env:PROCESSOR_IDENTIFIER
        try {
            $cpuReg = Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop
            if ($cpuReg.ProcessorNameString) { $cpuModel = $cpuReg.ProcessorNameString.Trim() }
        } catch {}

        $manufacturer = 'Unknown'; $model = 'Unknown'
        try {
            $bios = Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction Stop
            if ($bios.SystemManufacturer) { $manufacturer = $bios.SystemManufacturer }
            if ($bios.SystemProductName) { $model = $bios.SystemProductName }
        } catch {}

        $ramGB = 0
        $ms = Get-NmMemoryStatus
        if ($ms) { $ramGB = [math]::Round($ms.ullTotalPhys / 1GB, 1) }

        return [PSCustomObject]@{
            HasData           = $true
            Hostname          = $env:COMPUTERNAME
            CurrentUser       = "$env:USERDOMAIN\$env:USERNAME"
            DomainOrWorkgroup = $env:USERDOMAIN
            OsCaption         = $osCaption
            OsVersion         = $displayVersion
            OsBuild           = $fullBuild
            OsArch            = $arch
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            CpuModel          = $cpuModel
            LogicalCores      = [Environment]::ProcessorCount
            RamInstalledGB    = $ramGB
            Manufacturer      = $manufacturer
            Model             = $model
        }
    } catch {
        return [PSCustomObject]@{ HasData = $false }
    }
}

function Get-NmBootTime {
    try { return (Get-Date).AddMilliseconds(-[Environment]::TickCount64) }
    catch { return $null }
}

function Get-NmBatteryInfo {
    try {
        $status = [System.Windows.Forms.SystemInformation]::PowerStatus
        if ($status.BatteryChargeStatus -band [System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery) {
            return [PSCustomObject]@{ HasData = $false }
        }
        $pct = [math]::Round($status.BatteryLifePercent * 100, 0)
        $charging = $status.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Online
        $statusText = if ($charging) { 'AC Power / Charging' } else { 'Discharging' }
        $runtimeText = if ($status.BatteryLifeRemaining -ge 0) { "{0} min remaining" -f [math]::Round($status.BatteryLifeRemaining / 60.0) } else { 'Calculating...' }
        return [PSCustomObject]@{
            HasData          = $true
            PercentRemaining = $pct
            Status           = $statusText
            RuntimeText      = $runtimeText
        }
    } catch {
        return [PSCustomObject]@{ HasData = $false }
    }
}

# Temperature/fan sensors are intentionally not implemented: the only Windows APIs
# for these (ACPI thermal zone WMI, Win32_Fan) go through WMI, which this app
# otherwise avoids entirely, and third-party hardware-monitor libraries are out of
# scope for a dependency-free single-file tool. These always return empty, and the
# UI collapses their panels accordingly.
function Get-NmTempInfo { return @() }
function Get-NmFanInfo { return @() }

function Get-NmTopProcesses {
    $cpuRows = @(); $memRows = @()
    try {
        $now = Get-Date
        $elapsed = if ($script:PrevProcTime) { ($now - $script:PrevProcTime).TotalSeconds } else { 0 }
        $procs = Get-Process -ErrorAction SilentlyContinue
        $curCpu = @{}
        $cpuList = @()
        foreach ($p in $procs) {
            try {
                $pidVal = $p.Id
                $cpuSec = $p.CPU
                if ($null -ne $cpuSec) { $curCpu[$pidVal] = $cpuSec }
                if ($elapsed -gt 0 -and $null -ne $cpuSec -and $script:PrevProcCpu.ContainsKey($pidVal)) {
                    $deltaSec = $cpuSec - $script:PrevProcCpu[$pidVal]
                    if ($deltaSec -lt 0) { $deltaSec = 0 }
                    $pct = [math]::Round((($deltaSec / $elapsed) / $script:CoreCount) * 100, 1)
                    if ($pct -gt 0) {
                        $cpuList += [PSCustomObject]@{ Process = $p.ProcessName; PID = $pidVal; CpuPercent = $pct }
                    }
                }
            } catch {}
        }
        $cpuRows = $cpuList | Sort-Object -Property CpuPercent -Descending | Select-Object -First 8
        $script:PrevProcCpu = $curCpu
        $script:PrevProcTime = $now

        $memRows = $procs | Where-Object { $_.WorkingSet64 -gt 0 } |
            Sort-Object -Property WorkingSet64 -Descending | Select-Object -First 8 |
            ForEach-Object { [PSCustomObject]@{ Process = $_.ProcessName; PID = $_.Id; MemoryMB = [math]::Round($_.WorkingSet64 / 1MB, 1) } }
    } catch {}
    return [PSCustomObject]@{ TopCpu = $cpuRows; TopMemory = $memRows }
}

function Get-NmSnapshot {
    $cpu = Get-NmCpuInfo
    $mem = Get-NmMemoryInfo
    $disks = Get-NmDiskInfo
    $net = Get-NmNetworkInfo
    $procs = Get-NmTopProcesses
    $temps = Get-NmTempInfo
    $fans = Get-NmFanInfo
    $uptimeSec = if ($script:BootTime) { [math]::Round(((Get-Date) - $script:BootTime).TotalSeconds) } else { $null }
    $batteryBlock = [PSCustomObject]@{ present = $false }
    if ($script:HasBattery) {
        $b = Get-NmBatteryInfo
        if ($b.HasData) {
            $batteryBlock = [PSCustomObject]@{
                present = $true; percent_remaining = $b.PercentRemaining; status = $b.Status; runtime = $b.RuntimeText
            }
        }
    }

    return [PSCustomObject]@{
        captured_at = (Get-Date).ToString('o')
        hostname    = $script:SysInfo.Hostname
        current_user = $script:SysInfo.CurrentUser
        domain      = $script:SysInfo.DomainOrWorkgroup
        os          = [PSCustomObject]@{
            caption      = $script:SysInfo.OsCaption
            version      = $script:SysInfo.OsVersion
            build        = $script:SysInfo.OsBuild
            architecture = $script:SysInfo.OsArch
        }
        powershell_version = $script:SysInfo.PowerShellVersion
        hardware    = [PSCustomObject]@{
            cpu_model        = $script:SysInfo.CpuModel
            cores_logical    = $script:SysInfo.LogicalCores
            ram_installed_gb = $script:SysInfo.RamInstalledGB
            manufacturer     = $script:SysInfo.Manufacturer
            model            = $script:SysInfo.Model
        }
        cpu_percent = $cpu.PercentOverall
        memory      = [PSCustomObject]@{
            total_gb = $mem.TotalGB; used_gb = $mem.UsedGB; free_gb = $mem.FreeGB; percent_used = $mem.PercentUsed
        }
        uptime_seconds = $uptimeSec
        battery        = $batteryBlock
        disks          = $disks | ForEach-Object {
            [PSCustomObject]@{
                drive = $_.Drive; label = $_.Label; total_gb = $_.TotalGB; used_gb = $_.UsedGB
                free_gb = $_.FreeGB; used_percent = $_.UsedPercent
            }
        }
        network_adapters = $net | ForEach-Object {
            [PSCustomObject]@{
                adapter = $_.Adapter; status = $_.Status; ipv4 = $_.IPv4; link_speed = $_.LinkSpeed
                total_sent_bytes = $_.TotalTxBytes; total_received_bytes = $_.TotalRxBytes
                download_bytes_per_sec = [math]::Round($_.DownloadBps); upload_bytes_per_sec = [math]::Round($_.UploadBps)
            }
        }
        top_cpu_processes = $procs.TopCpu | ForEach-Object {
            [PSCustomObject]@{ process = $_.Process; pid_value = $_.PID; cpu_percent = $_.CpuPercent }
        }
        top_memory_processes = $procs.TopMemory | ForEach-Object {
            [PSCustomObject]@{ process = $_.Process; pid_value = $_.PID; memory_mb = $_.MemoryMB }
        }
        temperatures = $temps | ForEach-Object { [PSCustomObject]@{ zone = $_.Label; celsius = $_.Celsius } }
        fans         = $fans | ForEach-Object { [PSCustomObject]@{ name = $_.Label; rpm = $_.RPM } }
    }
}

function Format-NmSnapshotText {
    param($Snapshot)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("NERD MODE - SYSTEM SNAPSHOT")
    [void]$sb.AppendLine("Captured: $($Snapshot.captured_at)")
    [void]$sb.AppendLine([string]('=' * 60))
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Hostname:      $($Snapshot.hostname)")
    [void]$sb.AppendLine("User:          $($Snapshot.current_user)")
    [void]$sb.AppendLine("Domain:        $($Snapshot.domain)")
    [void]$sb.AppendLine("OS:            $($Snapshot.os.caption) (Build $($Snapshot.os.build), $($Snapshot.os.architecture))")
    [void]$sb.AppendLine("PowerShell:    $($Snapshot.powershell_version)")
    [void]$sb.AppendLine("CPU:           $($Snapshot.hardware.cpu_model)")
    [void]$sb.AppendLine("Cores:         $($Snapshot.hardware.cores_logical) logical")
    [void]$sb.AppendLine("RAM Installed: $($Snapshot.hardware.ram_installed_gb) GB")
    [void]$sb.AppendLine("Manufacturer:  $($Snapshot.hardware.manufacturer) $($Snapshot.hardware.model)")
    [void]$sb.AppendLine("Uptime (sec):  $($Snapshot.uptime_seconds)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("CPU Usage:     $($Snapshot.cpu_percent)%")
    [void]$sb.AppendLine("Memory:        $($Snapshot.memory.used_gb) GB / $($Snapshot.memory.total_gb) GB ($($Snapshot.memory.percent_used)%)")
    if ($Snapshot.battery.present) {
        [void]$sb.AppendLine("Battery:       $($Snapshot.battery.percent_remaining)% - $($Snapshot.battery.status) ($($Snapshot.battery.runtime))")
    } else {
        [void]$sb.AppendLine("Battery:       Not present")
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("DISK VOLUMES")
    foreach ($d in $Snapshot.disks) {
        [void]$sb.AppendLine("  $($d.drive) [$($d.label)] Used $($d.used_gb) GB / $($d.total_gb) GB ($($d.used_percent)%) Free $($d.free_gb) GB")
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("NETWORK ADAPTERS")
    foreach ($n in $Snapshot.network_adapters) {
        [void]$sb.AppendLine("  $($n.adapter) [$($n.status)] IPv4=$($n.ipv4) Sent=$($n.total_sent_bytes) B Received=$($n.total_received_bytes) B")
    }
    if ($Snapshot.temperatures.Count -gt 0) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("TEMPERATURES")
        foreach ($t in $Snapshot.temperatures) { [void]$sb.AppendLine("  $($t.zone): $($t.celsius) C") }
    }
    if ($Snapshot.fans.Count -gt 0) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("FANS")
        foreach ($f in $Snapshot.fans) { [void]$sb.AppendLine("  $($f.name): $($f.rpm) RPM") }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("TOP CPU PROCESSES")
    foreach ($p in $Snapshot.top_cpu_processes) {
        [void]$sb.AppendLine("  $($p.process) (PID $($p.pid_value)) - $($p.cpu_percent)%")
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("TOP MEMORY PROCESSES")
    foreach ($p in $Snapshot.top_memory_processes) {
        [void]$sb.AppendLine("  $($p.process) (PID $($p.pid_value)) - $($p.memory_mb) MB")
    }
    return $sb.ToString()
}

# --- Per-tick / cross-tick state ---
$script:PrevNetStats  = @{}
$script:PrevNetTime   = $null
$script:PrevProcCpu   = @{}
$script:PrevProcTime  = $null
$script:CoreCount     = [Environment]::ProcessorCount
$script:BootTime      = $null
$script:SysInfo       = $null
$script:HasBattery    = $false
$script:NmRefreshing  = $false

# --- XAML UI definition ---
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Nerd Mode - System Inspector" Height="960" Width="1320"
        WindowStartupLocation="CenterScreen" Background="#0A0E17"
        FontFamily="Segoe UI">
    <Window.Resources>
        <SolidColorBrush x:Key="BrushTile" Color="#12141C"/>
        <SolidColorBrush x:Key="BrushTile2" Color="#171A24"/>
        <SolidColorBrush x:Key="BrushBorder" Color="#232838"/>
        <SolidColorBrush x:Key="BrushAccent" Color="#3385FF"/>
        <SolidColorBrush x:Key="BrushText" Color="#E8EAED"/>
        <SolidColorBrush x:Key="BrushTextDim" Color="#8B93A7"/>
        <SolidColorBrush x:Key="BrushWisdom" Color="#C97CF0"/>
        <SolidColorBrush x:Key="BrushGreen" Color="#50DC82"/>

        <Style x:Key="TileBorder" TargetType="Border">
            <Setter Property="Background" Value="{StaticResource BrushTile}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BrushBorder}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="6"/>
            <Setter Property="Padding" Value="14"/>
            <Setter Property="Margin" Value="6"/>
        </Style>

        <Style x:Key="SectionHeader" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource BrushAccent}"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Margin" Value="0,0,0,8"/>
        </Style>

        <Style x:Key="TileSub" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource BrushTextDim}"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Margin" Value="0,6,0,0"/>
        </Style>

        <Style x:Key="FlatButton" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource BrushTile2}"/>
            <Setter Property="Foreground" Value="{StaticResource BrushText}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BrushBorder}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="Margin" Value="6,0,0,0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="4"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="{StaticResource BrushAccent}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DarkGrid" TargetType="DataGrid">
            <Setter Property="EnableRowVirtualization" Value="False"/>
            <Setter Property="EnableColumnVirtualization" Value="False"/>
            <Setter Property="Background" Value="{StaticResource BrushTile}"/>
            <Setter Property="Foreground" Value="{StaticResource BrushText}"/>
            <Setter Property="RowBackground" Value="{StaticResource BrushTile}"/>
            <Setter Property="AlternatingRowBackground" Value="{StaticResource BrushTile2}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush" Value="{StaticResource BrushBorder}"/>
            <Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="CanUserAddRows" Value="False"/>
            <Setter Property="CanUserDeleteRows" Value="False"/>
            <Setter Property="CanUserResizeRows" Value="False"/>
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="AutoGenerateColumns" Value="False"/>
            <Setter Property="RowHeaderWidth" Value="0"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="ColumnHeaderHeight" Value="28"/>
        </Style>

        <Style x:Key="DarkColumnHeader" TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="{StaticResource BrushTile2}"/>
            <Setter Property="Foreground" Value="{StaticResource BrushAccent}"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Padding" Value="8,4"/>
            <Setter Property="BorderBrush" Value="{StaticResource BrushBorder}"/>
            <Setter Property="BorderThickness" Value="0,0,0,1"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
        </Style>

        <Style x:Key="DarkCell" TargetType="DataGridCell">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="8,3"/>
            <Setter Property="Foreground" Value="{StaticResource BrushText}"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#1E2A44"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="DarkRow" TargetType="DataGridRow">
            <Setter Property="Background" Value="Transparent"/>
            <Style.Triggers>
                <DataTrigger Binding="{Binding Severity}" Value="Critical">
                    <Setter Property="Foreground" Value="#FF5A5A"/>
                </DataTrigger>
                <DataTrigger Binding="{Binding Severity}" Value="Warning">
                    <Setter Property="Foreground" Value="#FFAA3C"/>
                </DataTrigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <Grid Grid.Row="0" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Orientation="Vertical" Grid.Column="0">
                <TextBlock Text="NERD MODE" FontSize="24" FontWeight="Bold" Foreground="{StaticResource BrushAccent}"/>
                <TextBlock Text="Read-only system inspector - inspects only, never modifies" FontSize="11" Foreground="{StaticResource BrushTextDim}" Margin="0,2,0,0"/>
                <TextBlock x:Name="TxtStatusLine" Text="SYSTEM STATUS: INITIALIZING" FontFamily="Consolas" FontSize="11" Foreground="{StaticResource BrushGreen}" Margin="0,6,0,0"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Grid.Column="1" VerticalAlignment="Top">
                <TextBlock x:Name="TxtClock" Text="--:--:--" FontFamily="Consolas" FontSize="14" Foreground="{StaticResource BrushText}" VerticalAlignment="Center" Margin="0,0,16,0"/>
                <Button x:Name="BtnRefresh" Content="Refresh Now" Style="{StaticResource FlatButton}" AutomationProperties.AutomationId="BtnRefresh"/>
                <Button x:Name="BtnExport" Content="Export Snapshot" Style="{StaticResource FlatButton}" AutomationProperties.AutomationId="BtnExport"/>
            </StackPanel>
        </Grid>

        <!-- Body: two columns -->
        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- LEFT: identity, processes, sensors -->
            <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto">
                <StackPanel>
                    <Border Style="{StaticResource TileBorder}">
                        <StackPanel>
                            <TextBlock Text="SYSTEM IDENTITY" Style="{StaticResource SectionHeader}"/>
                            <TextBlock x:Name="TxtSystemInfo" Text="Loading..." FontFamily="Consolas" FontSize="11" Foreground="{StaticResource BrushText}"/>
                        </StackPanel>
                    </Border>

                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Border Grid.Column="0" Style="{StaticResource TileBorder}">
                            <StackPanel>
                                <TextBlock Text="TOP CPU PROCESSES" Style="{StaticResource SectionHeader}"/>
                                <DataGrid x:Name="GridTopCpu" Style="{StaticResource DarkGrid}"
                                          ColumnHeaderStyle="{StaticResource DarkColumnHeader}"
                                          CellStyle="{StaticResource DarkCell}"
                                          RowStyle="{StaticResource DarkRow}"
                                          MaxHeight="190">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Process" Binding="{Binding Process}" Width="*"/>
                                        <DataGridTextColumn Header="PID" Binding="{Binding PID}" Width="55"/>
                                        <DataGridTextColumn Header="CPU" Binding="{Binding CpuPctDisplay}" Width="55"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                            </StackPanel>
                        </Border>
                        <Border Grid.Column="1" Style="{StaticResource TileBorder}">
                            <StackPanel>
                                <TextBlock Text="TOP MEMORY PROCESSES" Style="{StaticResource SectionHeader}"/>
                                <DataGrid x:Name="GridTopMem" Style="{StaticResource DarkGrid}"
                                          ColumnHeaderStyle="{StaticResource DarkColumnHeader}"
                                          CellStyle="{StaticResource DarkCell}"
                                          RowStyle="{StaticResource DarkRow}"
                                          MaxHeight="190">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Process" Binding="{Binding Process}" Width="*"/>
                                        <DataGridTextColumn Header="PID" Binding="{Binding PID}" Width="55"/>
                                        <DataGridTextColumn Header="Memory" Binding="{Binding MemDisplay}" Width="75"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                            </StackPanel>
                        </Border>
                    </Grid>

                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Border x:Name="BorderTemps" Grid.Column="0" Style="{StaticResource TileBorder}" Visibility="Collapsed">
                            <StackPanel>
                                <TextBlock Text="SYSTEM TEMPERATURES" Style="{StaticResource SectionHeader}"/>
                                <StackPanel x:Name="PanelTemps"/>
                            </StackPanel>
                        </Border>
                        <Border x:Name="BorderFans" Grid.Column="1" Style="{StaticResource TileBorder}" Visibility="Collapsed">
                            <StackPanel>
                                <TextBlock Text="FAN SPEED" Style="{StaticResource SectionHeader}"/>
                                <StackPanel x:Name="PanelFans"/>
                            </StackPanel>
                        </Border>
                    </Grid>
                </StackPanel>
            </ScrollViewer>

            <!-- RIGHT: live metrics -->
            <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto">
                <StackPanel>
                    <Border Style="{StaticResource TileBorder}">
                        <StackPanel>
                            <TextBlock Text="CPU" Style="{StaticResource SectionHeader}"/>
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Grid.Column="0" Text="CPU Load:" FontFamily="Consolas" FontSize="12" Foreground="{StaticResource BrushTextDim}" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                <TextBlock x:Name="TxtCpuBar" Grid.Column="1" FontFamily="Consolas" FontSize="14" VerticalAlignment="Center"/>
                                <TextBlock x:Name="TxtCpuPercent" Grid.Column="2" Text="-" FontFamily="Consolas" FontSize="16" FontWeight="Bold" Foreground="{StaticResource BrushText}" VerticalAlignment="Center" Margin="10,0,0,0" MinWidth="55" TextAlignment="Right"/>
                            </Grid>
                            <TextBlock x:Name="TxtCpuSub" Text="" Style="{StaticResource TileSub}"/>
                        </StackPanel>
                    </Border>

                    <Border Style="{StaticResource TileBorder}">
                        <StackPanel>
                            <TextBlock Text="MEMORY" Style="{StaticResource SectionHeader}"/>
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Grid.Column="0" Text="RAM Usage:" FontFamily="Consolas" FontSize="12" Foreground="{StaticResource BrushTextDim}" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                <TextBlock x:Name="TxtMemBar" Grid.Column="1" FontFamily="Consolas" FontSize="14" VerticalAlignment="Center"/>
                                <TextBlock x:Name="TxtMemPercent" Grid.Column="2" Text="-" FontFamily="Consolas" FontSize="16" FontWeight="Bold" Foreground="{StaticResource BrushText}" VerticalAlignment="Center" Margin="10,0,0,0" MinWidth="55" TextAlignment="Right"/>
                            </Grid>
                            <TextBlock x:Name="TxtMemSub" Text="" Style="{StaticResource TileSub}"/>
                        </StackPanel>
                    </Border>

                    <Border Style="{StaticResource TileBorder}">
                        <StackPanel>
                            <TextBlock Text="STORAGE" Style="{StaticResource SectionHeader}"/>
                            <DataGrid x:Name="GridDisks" Style="{StaticResource DarkGrid}"
                                      ColumnHeaderStyle="{StaticResource DarkColumnHeader}"
                                      CellStyle="{StaticResource DarkCell}"
                                      RowStyle="{StaticResource DarkRow}"
                                      MaxHeight="180">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Drive" Binding="{Binding Drive}" Width="55"/>
                                    <DataGridTextColumn Header="Used" Binding="{Binding UsedDisplay}" Width="75"/>
                                    <DataGridTextColumn Header="Free" Binding="{Binding FreeDisplay}" Width="75"/>
                                    <DataGridTextColumn Header="Total" Binding="{Binding TotalDisplay}" Width="75"/>
                                    <DataGridTextColumn Header="Use %" Binding="{Binding UsedPctDisplay}" Width="*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </StackPanel>
                    </Border>

                    <Border Style="{StaticResource TileBorder}">
                        <StackPanel>
                            <TextBlock Text="NETWORK" Style="{StaticResource SectionHeader}"/>
                            <DataGrid x:Name="GridNetwork" Style="{StaticResource DarkGrid}"
                                      ColumnHeaderStyle="{StaticResource DarkColumnHeader}"
                                      CellStyle="{StaticResource DarkCell}"
                                      RowStyle="{StaticResource DarkRow}"
                                      MaxHeight="180">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Interface" Binding="{Binding Adapter}" Width="110"/>
                                    <DataGridTextColumn Header="IPv4 Address" Binding="{Binding IPv4}" Width="100"/>
                                    <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="65"/>
                                    <DataGridTextColumn Header="Sent" Binding="{Binding SentDisplay}" Width="75"/>
                                    <DataGridTextColumn Header="Received" Binding="{Binding ReceivedDisplay}" Width="*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </StackPanel>
                    </Border>

                    <Border Style="{StaticResource TileBorder}">
                        <StackPanel>
                            <TextBlock Text="SYSADMIN WISDOM" Style="{StaticResource SectionHeader}"/>
                            <TextBlock x:Name="TxtWisdom" Text="" FontFamily="Consolas" FontSize="12" FontStyle="Italic" Foreground="{StaticResource BrushWisdom}" TextWrapping="Wrap"/>
                        </StackPanel>
                    </Border>
                </StackPanel>
            </ScrollViewer>
        </Grid>

        <!-- Footer -->
        <Grid Grid.Row="2" Margin="0,8,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="TxtStatus" Grid.Column="0" Text="Initializing..." Foreground="{StaticResource BrushTextDim}" FontSize="11" VerticalAlignment="Center"/>
            <TextBlock Grid.Column="1" Text="NERD MODE - REGTeches" Foreground="{StaticResource BrushTextDim}" FontSize="10" VerticalAlignment="Center"/>
        </Grid>
    </Grid>
</Window>
'@

[xml]$xamlXml = $xamlText
$xamlReader = New-Object System.Xml.XmlNodeReader $xamlXml
$window = [System.Windows.Markup.XamlReader]::Load($xamlReader)

$txtClock        = $window.FindName('TxtClock')
$txtStatusLine   = $window.FindName('TxtStatusLine')
$btnRefresh      = $window.FindName('BtnRefresh')
$btnExport       = $window.FindName('BtnExport')
$txtCpuPercent   = $window.FindName('TxtCpuPercent')
$txtCpuBar       = $window.FindName('TxtCpuBar')
$txtCpuSub       = $window.FindName('TxtCpuSub')
$txtMemPercent   = $window.FindName('TxtMemPercent')
$txtMemBar       = $window.FindName('TxtMemBar')
$txtMemSub       = $window.FindName('TxtMemSub')
$txtSystemInfo   = $window.FindName('TxtSystemInfo')
$gridDisks       = $window.FindName('GridDisks')
$gridNetwork     = $window.FindName('GridNetwork')
$gridTopCpu      = $window.FindName('GridTopCpu')
$gridTopMem      = $window.FindName('GridTopMem')
$borderTemps     = $window.FindName('BorderTemps')
$panelTemps      = $window.FindName('PanelTemps')
$borderFans      = $window.FindName('BorderFans')
$panelFans       = $window.FindName('PanelFans')
$txtWisdom       = $window.FindName('TxtWisdom')
$txtStatus       = $window.FindName('TxtStatus')

function Set-NmProgress {
    param([string]$Message)
    $txtStatus.Text = $Message
    # Force a render pass now so this text is actually visible before the next
    # (possibly slow) telemetry call runs. Uses the standard Dispatcher.Invoke-at-
    # Render-priority idiom - NOT a manually managed DispatcherFrame/PushFrame
    # (an earlier version of this used that and had a reentrancy bug: called
    # repeatedly from within an already-deferred/background dispatcher operation,
    # it could stop advancing while leaving the window fully responsive, since a
    # nested pump still processes window messages like Alt+F4/close - looked
    # exactly like a hang but wasn't one, and none of it had anything to do with
    # the telemetry calls it was sitting in front of).
    $txtStatus.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render) | Out-Null
}

function Update-NmDashboard {
    if ($script:NmRefreshing) { return }
    $script:NmRefreshing = $true
    try {
        $txtClock.Text = Get-Date -Format 'HH:mm:ss  ddd, MMM d'

        Set-NmProgress "Loading CPU..."
        $cpu = Get-NmCpuInfo
        if ($cpu.HasData) {
            $txtCpuPercent.Text = "$($cpu.PercentOverall)%"
            Set-NmMeterBar -TextBlock $txtCpuBar -Percent $cpu.PercentOverall -FillBrush (Get-NmThresholdBrush -Percent $cpu.PercentOverall)
            $txtCpuSub.Text = "$($script:SysInfo.LogicalCores) logical processors"
        } else {
            $txtCpuPercent.Text = "-"
            $txtCpuSub.Text = "unavailable"
        }

        Set-NmProgress "Loading memory..."
        $mem = Get-NmMemoryInfo
        if ($mem.HasData) {
            $txtMemPercent.Text = "$($mem.PercentUsed)%"
            Set-NmMeterBar -TextBlock $txtMemBar -Percent $mem.PercentUsed -FillBrush (Get-NmThresholdBrush -Percent $mem.PercentUsed)
            $txtMemSub.Text = "Used / Total: $($mem.UsedGB) GB / $($mem.TotalGB) GB   |   Free: $($mem.FreeGB) GB"
        } else {
            $txtMemPercent.Text = "-"
            $txtMemSub.Text = "unavailable"
        }

        Set-NmProgress "Loading disks..."
        $disks = Get-NmDiskInfo
        $diskRows = $disks | ForEach-Object {
            [PSCustomObject]@{
                Drive          = $_.Drive
                UsedDisplay    = "{0:N1} GB" -f $_.UsedGB
                FreeDisplay    = "{0:N1} GB" -f $_.FreeGB
                TotalDisplay   = "{0:N1} GB" -f $_.TotalGB
                UsedPctDisplay = "$($_.UsedPercent)%"
                Severity       = $_.Severity
            }
        }
        $gridDisks.ItemsSource = (ConvertTo-NmDataTable $diskRows).DefaultView

        Set-NmProgress "Loading network adapters..."
        $net = Get-NmNetworkInfo
        $netRows = $net | ForEach-Object {
            [PSCustomObject]@{
                Adapter         = $_.Adapter
                Status          = $_.Status
                IPv4            = $_.IPv4
                SentDisplay     = Format-NmBytes $_.TotalTxBytes
                ReceivedDisplay = Format-NmBytes $_.TotalRxBytes
                Severity        = $_.Severity
            }
        }
        $gridNetwork.ItemsSource = (ConvertTo-NmDataTable $netRows).DefaultView

        Set-NmProgress "Loading processes..."
        $procs = Get-NmTopProcesses
        $cpuRows = @($procs.TopCpu | ForEach-Object {
            [PSCustomObject]@{ Process = $_.Process; PID = $_.PID; CpuPctDisplay = "$($_.CpuPercent)%" }
        })
        if ($cpuRows.Count -eq 0) {
            # Guarantees the DataTable always has the expected columns - a fully empty
            # (zero-row, zero-column) DataTable bound to a DataGrid with predefined
            # columns can crash WPF's DataGrid on first render. TopCpu is legitimately
            # empty on the very first tick (needs two samples to compute a CPU delta).
            $cpuRows = @([PSCustomObject]@{ Process = '(collecting...)'; PID = ''; CpuPctDisplay = '' })
        }
        $gridTopCpu.ItemsSource = (ConvertTo-NmDataTable $cpuRows).DefaultView

        $memRows = @($procs.TopMemory | ForEach-Object {
            [PSCustomObject]@{ Process = $_.Process; PID = $_.PID; MemDisplay = "{0:N0} MB" -f $_.MemoryMB }
        })
        if ($memRows.Count -eq 0) {
            $memRows = @([PSCustomObject]@{ Process = '(collecting...)'; PID = ''; MemDisplay = '' })
        }
        $gridTopMem.ItemsSource = (ConvertTo-NmDataTable $memRows).DefaultView

        Set-NmProgress "Loading temperature sensors..."
        $temps = Get-NmTempInfo
        if ($temps.Count -gt 0) {
            $borderTemps.Visibility = [System.Windows.Visibility]::Visible
            $panelTemps.Children.Clear()
            foreach ($t in $temps) {
                [void]$panelTemps.Children.Add((New-NmSensorRow -Label $t.Label -ValueText "$($t.Celsius) C" -Percent ([math]::Min(100, ($t.Celsius / 100.0) * 100))))
            }
        } else {
            $borderTemps.Visibility = [System.Windows.Visibility]::Collapsed
        }

        Set-NmProgress "Loading fan sensors..."
        $fans = Get-NmFanInfo
        if ($fans.Count -gt 0) {
            $borderFans.Visibility = [System.Windows.Visibility]::Visible
            $panelFans.Children.Clear()
            foreach ($f in $fans) {
                [void]$panelFans.Children.Add((New-NmSensorRow -Label $f.Label -ValueText "$($f.RPM) RPM" -Percent ([math]::Min(100, ($f.RPM / 5000.0) * 100))))
            }
        } else {
            $borderFans.Visibility = [System.Windows.Visibility]::Collapsed
        }

        # System identity: static fields cached at startup, live fields recomputed each tick.
        $uptimeText = "unavailable"
        if ($script:BootTime) {
            $up = (Get-Date) - $script:BootTime
            $uptimeText = "{0}d {1:D2}h {2:D2}m" -f [int]$up.Days, $up.Hours, $up.Minutes
        }
        $ipList = ($net | Where-Object { $_.Status -eq 'Up' -and $_.IPv4 -ne '-' } | Select-Object -ExpandProperty IPv4) -join ', '
        if (-not $ipList) { $ipList = '-' }

        if ($script:SysInfo.HasData) {
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add("Computer Name : $($script:SysInfo.Hostname)")
            $lines.Add("User          : $($script:SysInfo.CurrentUser)")
            $lines.Add("Domain        : $($script:SysInfo.DomainOrWorkgroup)")
            $lines.Add("OS            : $($script:SysInfo.OsCaption)")
            $lines.Add("Build         : $($script:SysInfo.OsBuild) ($($script:SysInfo.OsArch))")
            $lines.Add("PowerShell    : $($script:SysInfo.PowerShellVersion)")
            $lines.Add("Uptime        : $uptimeText")
            $lines.Add("Manufacturer  : $($script:SysInfo.Manufacturer)")
            $lines.Add("Model         : $($script:SysInfo.Model)")
            $lines.Add("IPv4 Address  : $ipList")
            if ($script:HasBattery) {
                $batt = Get-NmBatteryInfo
                if ($batt.HasData) {
                    $lines.Add("Battery       : $($batt.PercentRemaining)% - $($batt.Status)")
                }
            }
            $txtSystemInfo.Text = [string]::Join("`n", $lines)
        } else {
            $txtSystemInfo.Text = "System information unavailable."
        }

        $txtStatusLine.Text = "SYSTEM STATUS: ONLINE   |   AUTO-REFRESH: 3s"
        $txtStatus.Text = "Live - refreshing every 3s   |   Last telemetry sweep: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    } catch {
        $txtStatus.Text = "Refresh error: $($_.Exception.Message)"
    } finally {
        $script:NmRefreshing = $false
    }
}

$window.Add_Loaded({
    # Defer the first (heavy) data load until after the window has painted its
    # initial frame - doing this synchronously in Loaded blocks the first render
    # pass and leaves a blank white window while all processes/adapters/volumes
    # are enumerated.
    $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{
        try {
            $script:BootTime = Get-NmBootTime
            $script:SysInfo = Get-NmSystemInfo

            $battCheck = Get-NmBatteryInfo
            $script:HasBattery = [bool]$battCheck.HasData

            $txtWisdom.Text = Get-NmRandomWisdom
            Update-NmDashboard
            $script:nmTimer.Start()
        } catch {
            $txtStatus.Text = "Startup error: $($_.Exception.Message)"
        }
    }) | Out-Null
})

$window.Add_Closing({
    if ($script:nmTimer) { $script:nmTimer.Stop() }
})

$btnRefresh.Add_Click({
    $script:nmTimer.Stop()
    $txtWisdom.Text = Get-NmRandomWisdom
    Update-NmDashboard
    $script:nmTimer.Start()
})

$btnExport.Add_Click({
    try {
        $sfd = New-Object Microsoft.Win32.SaveFileDialog
        $sfd.Filter = "JSON Snapshot (*.json)|*.json|Text Report (*.txt)|*.txt"
        $sfd.FileName = "NerdMode_Snapshot_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        $ok = $sfd.ShowDialog()
        if ($ok) {
            $snapshot = Get-NmSnapshot
            $ext = [System.IO.Path]::GetExtension($sfd.FileName).ToLower()
            if ($ext -eq '.txt') {
                $text = Format-NmSnapshotText -Snapshot $snapshot
                [System.IO.File]::WriteAllText($sfd.FileName, $text, [System.Text.Encoding]::UTF8)
            } else {
                $json = $snapshot | ConvertTo-Json -Depth 6
                [System.IO.File]::WriteAllText($sfd.FileName, $json, [System.Text.Encoding]::UTF8)
            }
            $txtStatus.Text = "[EXPORTED] $($sfd.FileName)"
        }
    } catch {
        [System.Windows.MessageBox]::Show("Export failed: $($_.Exception.Message)", "Nerd Mode", 'OK', 'Error') | Out-Null
    }
})

$script:nmTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:nmTimer.Interval = [TimeSpan]::FromSeconds(3)
$script:nmTimer.Add_Tick({
    try { Update-NmDashboard } catch {}
})

[void]$window.ShowDialog()
