# Nerd Mode — Windows

A lightweight, read-only system inspection dashboard for Windows. Single-file PowerShell/WPF app — nothing to install.

**Read-only by design.** Nerd Mode inspects and reports system information; it does not modify system settings, terminate processes, clean files, change services, or alter your network configuration.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built in — no PowerShell 7 or extra modules required)
- No administrator rights needed

## Launch

```powershell
powershell.exe -ExecutionPolicy Bypass -File NerdMode.ps1
```

If your organization's execution policy blocks scripts, the `-ExecutionPolicy Bypass` flag above only affects this one process — it does not change your system's policy.

## Features

- Live CPU utilization
- Memory utilization
- Disk usage and available storage per volume
- Network interface information (adapters, IPs, link status, live throughput)
- System and hardware information
- System uptime
- Battery status when available (hidden automatically on desktops)
- Top CPU-consuming and top memory-consuming processes
- Automatic 3-second telemetry refresh, plus manual refresh
- Exportable diagnostic snapshots (JSON or plain-text report)

## Notes

- The JSON snapshot uses a generic, OS-agnostic schema (`cpu_percent`, `memory`, `disks`, `network_adapters`, etc.) so a future Linux/Python companion app can produce matching output.
- Every telemetry source degrades independently — if one data source (e.g. a flaky network adapter) fails, the rest of the dashboard keeps working.
