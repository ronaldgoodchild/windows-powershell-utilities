<#
    Elevated "Run with PowerShell (Admin)" / "Run with Python (Admin)" context menu.

    What this does:
      - Registers two Scheduled Tasks (ElevatedRunPS1 / ElevatedRunPY) with
        RunLevel = Highest, manual trigger only. Task Scheduler is allowed to
        launch a "highest privileges" task for an Administrator account WITHOUT
        a UAC consent prompt - that's the trick that makes this silent.
      - Adds a right-click entry on .ps1 and .py files (per-user registry,
        HKCU\Software\Classes, so no admin rights needed to install) that
        writes the clicked file's path to a marker file and fires the
        matching task via `schtasks /run`.

    Requirements:
      - No admin rights needed to RUN this installer.
      - Your Windows account DOES need to be a local Administrator for the
        resulting right-click action to elevate silently (no UAC prompt).
        On a standard/non-admin account you'll still get a UAC prompt.

    Usage (on any PC):
      powershell -ExecutionPolicy Bypass -File Install.ps1
#>

$ErrorActionPreference = "Stop"

$baseDir = Join-Path $env:ProgramData "ElevatedRunner"
New-Item -ItemType Directory -Path $baseDir -Force | Out-Null

# --- Launcher scripts (run BY the scheduled task, already elevated) ---

$launcherPS1 = @'
$targetFile = Join-Path $env:ProgramData "ElevatedRunner\target_ps1.txt"
if (Test-Path $targetFile) {
    $target = (Get-Content -Path $targetFile -Raw).Trim().Trim('"')
    if (Test-Path $target) {
        Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$target`""
        )
    }
}
'@
Set-Content -Path (Join-Path $baseDir "Launcher-PS1.ps1") -Value $launcherPS1 -Encoding UTF8

$launcherPY = @'
$targetFile = Join-Path $env:ProgramData "ElevatedRunner\target_py.txt"
if (Test-Path $targetFile) {
    $target = (Get-Content -Path $targetFile -Raw).Trim().Trim('"')
    if (Test-Path $target) {
        Start-Process -FilePath "cmd.exe" -ArgumentList @(
            "/k", "python `"$target`""
        )
    }
}
'@
Set-Content -Path (Join-Path $baseDir "Launcher-PY.ps1") -Value $launcherPY -Encoding UTF8

# --- Scheduled tasks: Highest privileges, no trigger (manual run only) ---

function Register-ElevatedTask {
    param([string]$TaskName, [string]$ScriptPath)

    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
}

Register-ElevatedTask -TaskName "ElevatedRunPS1" -ScriptPath (Join-Path $baseDir "Launcher-PS1.ps1")
Register-ElevatedTask -TaskName "ElevatedRunPY"  -ScriptPath (Join-Path $baseDir "Launcher-PY.ps1")

# --- Context menu entries (per-user, HKCU - no admin required) ---

function Add-ContextMenuEntry {
    param(
        [string]$Extension,
        [string]$KeyName,
        [string]$MenuText,
        [string]$Icon,
        [string]$MarkerFile,
        [string]$TaskName
    )

    $shellPath = "Registry::HKEY_CURRENT_USER\Software\Classes\SystemFileAssociations\$Extension\shell\$KeyName"
    New-Item -Path $shellPath -Force | Out-Null
    Set-ItemProperty -Path $shellPath -Name "(Default)" -Value $MenuText
    if ($Icon) { Set-ItemProperty -Path $shellPath -Name "Icon" -Value $Icon }

    $cmdPath = Join-Path $shellPath "command"
    New-Item -Path $cmdPath -Force | Out-Null
    $markerPath = Join-Path $baseDir $MarkerFile
    $cmd = "cmd.exe /c echo %1>`"$markerPath`" & schtasks /run /tn `"$TaskName`""
    Set-ItemProperty -Path $cmdPath -Name "(Default)" -Value $cmd
}

$psIcon = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe,0"
$pyCmd  = Get-Command python -ErrorAction SilentlyContinue
$pyIcon = if ($pyCmd) { "$($pyCmd.Source),0" } else { "$env:SystemRoot\System32\shell32.dll,-152" }

Add-ContextMenuEntry -Extension ".ps1" -KeyName "RunElevatedPS1" `
    -MenuText "Run with PowerShell (Admin)" -Icon $psIcon `
    -MarkerFile "target_ps1.txt" -TaskName "ElevatedRunPS1"

Add-ContextMenuEntry -Extension ".py" -KeyName "RunElevatedPY" `
    -MenuText "Run with Python (Admin)" -Icon $pyIcon `
    -MarkerFile "target_py.txt" -TaskName "ElevatedRunPY"

Write-Host "Installed. Right-click a .ps1 or .py file -> 'Run with PowerShell (Admin)' / 'Run with Python (Admin)'."
Write-Host "Silent elevation only works if this Windows account is a local Administrator."
Write-Host "To remove everything, run Uninstall.ps1."
