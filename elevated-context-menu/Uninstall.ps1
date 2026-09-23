<#
    Removes the elevated PowerShell/Python context menu entries, scheduled
    tasks, and the ElevatedRunner support folder installed by Install.ps1.

    Usage:
      powershell -ExecutionPolicy Bypass -File Uninstall.ps1
#>

$ErrorActionPreference = "SilentlyContinue"

Unregister-ScheduledTask -TaskName "ElevatedRunPS1" -Confirm:$false
Unregister-ScheduledTask -TaskName "ElevatedRunPY" -Confirm:$false

Remove-Item -Path "Registry::HKEY_CURRENT_USER\Software\Classes\SystemFileAssociations\.ps1\shell\RunElevatedPS1" -Recurse -Force
Remove-Item -Path "Registry::HKEY_CURRENT_USER\Software\Classes\SystemFileAssociations\.py\shell\RunElevatedPY" -Recurse -Force

Remove-Item -Path (Join-Path $env:ProgramData "ElevatedRunner") -Recurse -Force

Write-Host "Removed elevated context menu entries, scheduled tasks, and support files."
