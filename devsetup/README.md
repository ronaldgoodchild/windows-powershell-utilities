# DevSetup

A single, **re-runnable** PowerShell script that turns a fresh Windows PC into a developer machine. It skips anything that is already installed or configured, so you can run it again any time.

- Self-elevates to Administrator
- Sets execution policy and enables long paths
- Installs developer tools with winget (PowerShell 7, Python, Git, VS Code and more - see the script for the full list)
- Creates PowerShell and CMD profiles with aliases and helpers (`ccode`, `projects`, `c.` to open VS Code, `kill`, and others)
- 11 clearly numbered steps with colour-coded output and a final summary

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File .\DevSetup.ps1
```

Set `$ForceUpdate = $true` at the top of the script to force reinstall / upgrade of everything.

## Customise

- `ccode` jumps to `%USERPROFILE%\code` - change it in the profile section if your projects live elsewhere.
- Read the script before running it: it installs software and edits your shell profiles. Use it only on machines you own or administer.
