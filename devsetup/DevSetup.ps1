#Requires -Version 5.1
<#
.SYNOPSIS
    Full Developer Environment Setup (REGTeches)
    Safe to re-run anytime - skips anything already installed/configured.
    Set $ForceUpdate = $true at the top to force reinstall/upgrade everything.
#>

# ── Configuration ─────────────────────────────────────────────────────────────
$ForceUpdate = $false   # Change to $true to force reinstall/upgrade everything

# ── Self-elevate to Administrator ─────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Relaunching as Administrator..." -ForegroundColor Yellow
    Start-Process pwsh -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Clear-Host
$Width = 62
function Banner($msg, $color = "Magenta") {
    $line = "=" * $Width
    Write-Host $line -ForegroundColor $color
    Write-Host ("  " + $msg) -ForegroundColor $color
    Write-Host $line -ForegroundColor $color
}
function Step($n, $total, $msg) { Write-Host "`n[$n/$total] $msg" -ForegroundColor Cyan }
function OK($msg)   { Write-Host "  -> OK: $msg"      -ForegroundColor Green  }
function INFO($msg) { Write-Host "  -> $msg"           -ForegroundColor Gray   }
function WARN($msg) { Write-Host "  -> WARNING: $msg"  -ForegroundColor Yellow }
function Skipped($msg) { Write-Host "  -> SKIP: $msg"  -ForegroundColor DarkGray }

Banner "REGTECHES FULL DEV ENVIRONMENT SETUP"
if ($ForceUpdate) { Write-Host "  [Force Update mode ON - reinstalling everything]" -ForegroundColor Yellow }
$Total = 11

# ── 1. Execution Policy & Long Paths ─────────────────────────────────────────
Step 1 $Total "Execution Policy & Long Paths..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$currentPolicy = (Get-ExecutionPolicy -Scope LocalMachine)
if ($ForceUpdate -or $currentPolicy -ne "Bypass") {
    Set-ExecutionPolicy Bypass -Force -Scope LocalMachine
    INFO "Execution policy set to Bypass."
} else { Skipped "Execution policy already Bypass." }

$longPaths = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
if ($ForceUpdate -or $longPaths -ne 1) {
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" `
        -Name "LongPathsEnabled" -Value 1 -PropertyType DWORD -Force | Out-Null
    INFO "Long Paths enabled."
} else { Skipped "Long Paths already enabled." }
OK "Done."

# ── 2. UAC Auto-Approve for Admins ───────────────────────────────────────────
Step 2 $Total "UAC for Administrator Profiles..."
$uacVal = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name ConsentPromptBehaviorAdmin -ErrorAction SilentlyContinue).ConsentPromptBehaviorAdmin
if ($ForceUpdate -or $uacVal -ne 0) {
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
        -Name "ConsentPromptBehaviorAdmin" -Value 0
    OK "UAC set to auto-approve for Administrator."
} else { Skipped "UAC already configured." ; OK "Done." }

# ── 3. WinGet – Core System Packages ─────────────────────────────────────────
Step 3 $Total "Core Applications via WinGet..."
$WinGetApps = @(
    @{ ID = "Microsoft.PowerShell";          Name = "PowerShell 7"       },
    @{ ID = "Python.Python.3.11";            Name = "Python 3.11"        },
    @{ ID = "OpenJS.NodeJS.LTS";             Name = "Node.js LTS"        },
    @{ ID = "Git.Git";                       Name = "Git"                },
    @{ ID = "Microsoft.VisualStudioCode";    Name = "VS Code"            },
    @{ ID = "Microsoft.WindowsTerminal";     Name = "Windows Terminal"   },
    @{ ID = "JanDeDobbeleer.OhMyPosh";       Name = "Oh My Posh"         },
    @{ ID = "GitHub.cli";                    Name = "GitHub CLI (gh)"    }
)

foreach ($app in $WinGetApps) {
    $check = winget list --id $app.ID --accept-source-agreements 2>&1
    if ($check -match $app.ID) {
        if ($ForceUpdate) {
            INFO "Upgrading $($app.Name)..."
            winget upgrade --id $app.ID --accept-source-agreements --accept-package-agreements --silent 2>&1 | Out-Null
        } else {
            Skipped "$($app.Name) already installed."
        }
    } else {
        INFO "Installing $($app.Name)..."
        winget install --id $app.ID --accept-source-agreements --accept-package-agreements --silent 2>&1 | Out-Null
        OK "$($app.Name) installed."
    }
}
OK "Core applications done."

# Refresh PATH so newly installed tools are found in this session
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path", "User")

# ── 4. Python Packages ────────────────────────────────────────────────────────
Step 4 $Total "Python Packages..."
if (Get-Command python -ErrorAction SilentlyContinue) {
    python -m pip install --upgrade pip --quiet

    $PythonLibs = @(
        "requests", "rich", "black", "ipython", "pyinstaller",
        "pandas", "numpy", "matplotlib", "scikit-learn", "openpyxl",
        "flask", "django", "fastapi", "uvicorn", "aiohttp", "httpx",
        "sqlalchemy", "alembic",
        "pywin32", "psutil", "wmi", "pywin32-ctypes",
        "Pillow",
        "ping3", "paramiko", "python-nmap", "scapy", "dnspython",
        "schedule", "apscheduler",
        "python-jose", "passlib", "bcrypt", "python-multipart",
        "plyer", "win10toast",
        "xlsxwriter", "reportlab",
        "python-dotenv",
        "anthropic"
    )

    # Get all installed packages in one shot to avoid calling pip 30+ times
    $installedRaw = pip list --format=freeze 2>&1
    $installedPkgs = $installedRaw | ForEach-Object { ($_ -split "==")[0].Trim().ToLower() }

    $toInstall = @()
    foreach ($lib in $PythonLibs) {
        # Handle packages whose pip name differs from import name (e.g. Pillow -> pillow)
        if ($ForceUpdate -or ($installedPkgs -notcontains $lib.ToLower())) {
            $toInstall += $lib
        } else {
            Skipped "$lib already installed."
        }
    }

    if ($toInstall.Count -gt 0) {
        INFO "Installing $($toInstall.Count) missing package(s)..."
        foreach ($lib in $toInstall) {
            INFO "  pip install $lib"
            pip install $lib --quiet 2>&1 | Out-Null
        }
    }

    # Fix Python directory ownership (only if not already set)
    $pythonDir = Split-Path (Get-Command python).Source
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl  = Get-Acl $pythonDir
    $existingRule = $acl.Access | Where-Object {
        $_.IdentityReference -like "*$($user.Split('\')[-1])*" -and
        $_.FileSystemRights -match "FullControl"
    }
    if ($ForceUpdate -or -not $existingRule) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $user, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.SetAccessRule($rule)
        Set-Acl $pythonDir $acl
        INFO "Python directory ownership fixed."
    } else {
        Skipped "Python directory ownership already correct."
    }
    OK "Python packages done."
} else {
    WARN "Python not found in PATH. Reboot then re-run to install Python packages."
}

# ── 5. Node.js Global Packages ───────────────────────────────────────────────
Step 5 $Total "Node.js Global Packages..."
if (Get-Command npm -ErrorAction SilentlyContinue) {
    $NodeGlobals = @("vite", "typescript", "eslint", "prettier", "nodemon", "http-server")

    # Get installed globals in one shot
    $installedGlobals = npm list -g --depth=0 2>&1 | ForEach-Object {
        if ($_ -match "-- (.+)@") { $Matches[1] }
    }

    foreach ($pkg in $NodeGlobals) {
        if ($ForceUpdate -or ($installedGlobals -notcontains $pkg)) {
            INFO "npm install -g $pkg"
            npm install -g $pkg --silent 2>&1 | Out-Null
        } else {
            Skipped "$pkg already installed."
        }
    }
    OK "Node.js global packages done."
} else {
    WARN "npm not found. Reboot after this script to activate Node.js, then re-run."
}

# ── 6. PowerShell Modules ────────────────────────────────────────────────────
Step 6 $Total "PowerShell Modules..."
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
}

$PSModules = @(
    "PSReadLine",
    "Terminal-Icons",
    "PSWindowsUpdate",
    "BurntToast",
    "Microsoft.Graph",
    "SqlServer",
    "Posh-Git",
    "PSScriptAnalyzer"
)

foreach ($mod in $PSModules) {
    if (Get-Module -ListAvailable $mod) {
        if ($ForceUpdate) {
            INFO "Updating $mod..."
            Update-Module -Name $mod -Force -ErrorAction SilentlyContinue
        } else {
            Skipped "$mod already installed."
        }
    } else {
        INFO "Installing $mod..."
        Install-Module -Name $mod -AllowClobber -Force -Scope CurrentUser `
            -Repository PSGallery -ErrorAction SilentlyContinue
        OK "$mod installed."
    }
}
OK "PowerShell modules done."

# ── 7. PowerShell Profile ────────────────────────────────────────────────────
Step 7 $Total "PowerShell Profile (PS5 + PS7)..."

# Marker line - if this is in the profile it was written by this script
$ProfileMarker = "# REGTeches PowerShell Profile"

$ProfileContent = @'
# REGTeches PowerShell Profile

# Oh My Posh prompt - tries multiple known install locations for the theme file
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    $ThemePaths = @(
        "$env:POSH_THEMES_PATH\jandedobbeleer.omp.json",
        "$env:LOCALAPPDATA\Programs\oh-my-posh\themes\jandedobbeleer.omp.json",
        "$env:APPDATA\oh-my-posh\themes\jandedobbeleer.omp.json"
    )
    $Theme = $ThemePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($Theme) {
        oh-my-posh init pwsh --config $Theme | Invoke-Expression
    } else {
        oh-my-posh init pwsh | Invoke-Expression
    }
}

# File/folder icons in terminal
Import-Module Terminal-Icons -ErrorAction SilentlyContinue

# Predictive autocomplete (up arrow / inline suggestion)
Import-Module PSReadLine -ErrorAction SilentlyContinue
Set-PSReadLineOption -PredictionSource History
Set-PSReadLineOption -PredictionViewStyle ListView

# Git prompt integration
Import-Module Posh-Git -ErrorAction SilentlyContinue

# ── Windows / Linux shortcuts ─────────────────────────────────────────────────

# ps -> open a new PowerShell 7 window as Admin
# (overrides built-in ps/Get-Process alias; use Get-Process or gps instead)
function ps   { Start-Process pwsh -Verb RunAs }

# py -> run Python 3.11 with any args passed through
function py   { & python @args }

# Linux-style ls variants
# (ls/dir/cat/rm/cp/mv/mkdir/pwd/clear are already aliased in PowerShell)
function ll   { Get-ChildItem -Force @args }
function la   { Get-ChildItem -Force -Hidden @args }
function l    { Get-ChildItem @args | Format-Wide -AutoSize }

# grep -> search file contents (like Linux grep)
function grep {
    param([string]$Pattern, [string]$Path = ".")
    Select-String -Pattern $Pattern -Path $Path -Recurse
}

# touch -> create empty file or update timestamp
function touch {
    param([string]$File)
    if (Test-Path $File) { (Get-Item $File).LastWriteTime = Get-Date }
    else { New-Item -ItemType File -Path $File | Out-Null }
}

# which -> show where a command lives
function which { param([string]$cmd) (Get-Command $cmd -ErrorAction SilentlyContinue).Source }

# head / tail -> first or last N lines of a file
function head { param([string]$File, [int]$n = 10) Get-Content $File -TotalCount $n }
function tail { param([string]$File, [int]$n = 10) Get-Content $File -Tail $n }

# find -> search for files by name pattern under a path
function find {
    param([string]$Path = ".", [string]$Name = "*")
    Get-ChildItem -Path $Path -Recurse -Filter $Name -ErrorAction SilentlyContinue
}

# df -> show disk free space for all drives
function df { Get-PSDrive -PSProvider FileSystem | Select-Object Name, @{N="Used(GB)";E={[math]::Round($_.Used/1GB,1)}}, @{N="Free(GB)";E={[math]::Round($_.Free/1GB,1)}}, @{N="Total(GB)";E={[math]::Round(($_.Used+$_.Free)/1GB,1)}} }

# du -> show size of a folder
function du {
    param([string]$Path = ".")
    $size = (Get-ChildItem $Path -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    Write-Host ("{0:N2} MB  {1}" -f ($size / 1MB), (Resolve-Path $Path))
}

# sudo -> run a command as Admin in a new elevated PS window
function sudo {
    if ($args.Count -eq 0) { Start-Process pwsh -Verb RunAs }
    else { Start-Process pwsh -ArgumentList "-NoExit", "-Command", ($args -join " ") -Verb RunAs }
}

# man -> PowerShell help (same keyword as Linux)
function man  { param([string]$cmd) Get-Help $cmd -Full | more }

# open -> open a file or folder in Explorer (like Mac/Linux xdg-open)
function open {
    param([string]$Path = ".")
    Start-Process explorer (Resolve-Path $Path)
}

# env -> list all environment variables (like Linux env)
function env  { Get-ChildItem Env: | Sort-Object Name }

# kill -> stop a process by name or PID
function kill {
    param([string]$Name = "", [int]$Id = 0)
    if ($Id) { Stop-Process -Id $Id -Force }
    elseif ($Name) { Stop-Process -Name $Name -Force }
}

# ── Project navigation ────────────────────────────────────────────────────────
function ccode  { Set-Location "$HOME\code" }

# Open VS Code in current folder
function c. { code . }

# List all project folders sorted by most recently modified
function projects {
    Get-ChildItem "$HOME\code" -Directory |
        Select-Object Name, LastWriteTime | Sort-Object LastWriteTime -Descending
}
'@

foreach ($profilePath in @(
    "$HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1",
    "$HOME\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
)) {
    $profileDir = Split-Path $profilePath -Parent
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }

    $needsWrite = $true
    if (-not $ForceUpdate -and (Test-Path $profilePath)) {
        $existing = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
        if ($existing -like "*$ProfileMarker*") { $needsWrite = $false }
    }

    if ($needsWrite) {
        Set-Content -Path $profilePath -Value $ProfileContent -Encoding UTF8
        OK "Profile written: $profilePath"
    } else {
        Skipped "Profile already configured: $profilePath"
    }
}

# ── 8. CMD Config (Prompt + ANSI + Linux aliases) ────────────────────────────
Step 8 $Total "CMD Prompt, ANSI Colors, Linux Aliases..."

# Enable ANSI/VT100 in CMD
$ConRegPath = "HKCU:\Console"
if (-not (Test-Path $ConRegPath)) { New-Item -Path $ConRegPath -Force | Out-Null }
$vtLevel = (Get-ItemProperty $ConRegPath -Name VirtualTerminalLevel -ErrorAction SilentlyContinue).VirtualTerminalLevel
if ($ForceUpdate -or $vtLevel -ne 1) {
    Set-ItemProperty -Path $ConRegPath -Name "VirtualTerminalLevel" -Value 1 -Type DWORD
    INFO "ANSI color support enabled."
} else { Skipped "ANSI already enabled." }

# Write cmd_init.bat
$ToolsDir = "C:\Tools"
if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null }
$CmdInitPath = "$ToolsDir\cmd_init.bat"

$CmdInit = @'
@echo off
prompt $E[1;35m[ADMIN]$E[0m $E[1;32m$P$E[0m$_$G

:: Linux-style aliases for CMD
doskey ls=dir /b $*
doskey ll=dir $*
doskey la=dir /a $*
doskey l=dir /w $*
doskey cat=type $*
doskey grep=findstr $*
doskey rm=del $*
doskey cp=copy $*
doskey mv=move $*
doskey clear=cls
doskey pwd=cd
doskey mkdir=md $*
doskey touch=type nul >> $1
doskey which=where $*
doskey open=explorer $*
doskey env=set
doskey head=more /e +1 $*
doskey find=dir /s /b $*
doskey history=doskey /history
doskey sudo=powershell -Command "Start-Process cmd -Verb RunAs"

:: REGTeches shortcuts
doskey ps=pwsh %*
doskey py=python %*
doskey c.=code .
doskey ccode=cd /d %USERPROFILE%\code
'@

$needsCmdWrite = $ForceUpdate -or (-not (Test-Path $CmdInitPath))
if (-not $needsCmdWrite) {
    $existingCmd = Get-Content $CmdInitPath -Raw -ErrorAction SilentlyContinue
    if ($existingCmd -notlike "*REGTeches shortcuts*") { $needsCmdWrite = $true }
}
if ($needsCmdWrite) {
    Set-Content -Path $CmdInitPath -Value $CmdInit -Encoding ASCII
    INFO "cmd_init.bat written."
} else { Skipped "cmd_init.bat already configured." }

# Point CMD Autorun to cmd_init.bat
$CmdRegPath = "HKCU:\Software\Microsoft\Command Processor"
if (-not (Test-Path $CmdRegPath)) { New-Item -Path $CmdRegPath -Force | Out-Null }
$currentAutorun = (Get-ItemProperty $CmdRegPath -Name Autorun -ErrorAction SilentlyContinue).Autorun
if ($ForceUpdate -or $currentAutorun -ne $CmdInitPath) {
    Set-ItemProperty -Path $CmdRegPath -Name "Autorun" -Value $CmdInitPath -Type String
    INFO "CMD Autorun set."
} else { Skipped "CMD Autorun already set." }

# Set py launcher default to Python 3.11
$pyPython = [System.Environment]::GetEnvironmentVariable("PY_PYTHON", "Machine")
if ($ForceUpdate -or $pyPython -ne "3.11") {
    [System.Environment]::SetEnvironmentVariable("PY_PYTHON", "3.11", "Machine")
    $env:PY_PYTHON = "3.11"
    INFO "PY_PYTHON set to 3.11."
} else { Skipped "PY_PYTHON already set to 3.11." }

OK "CMD fully configured."

# ── 9. C:\Tools - ps / powershell shortcuts ──────────────────────────────────
Step 9 $Total "Creating ps / powershell shortcuts in C:\Tools..."

foreach ($bat in @("ps.bat", "powershell.bat")) {
    $batPath = "$ToolsDir\$bat"
    if ($ForceUpdate -or (-not (Test-Path $batPath))) {
        Set-Content -Path $batPath -Value '@pwsh.exe %*' -Encoding ASCII
        INFO "$bat created."
    } else { Skipped "$bat already exists." }
}

$SysPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
if ($SysPath -notlike "*$ToolsDir*") {
    [System.Environment]::SetEnvironmentVariable("Path", "$ToolsDir;$SysPath", "Machine")
    $env:Path = "$ToolsDir;" + $env:Path
    INFO "C:\Tools added to front of system PATH."
} else { Skipped "C:\Tools already in PATH." }

OK "Done."

# ── 10. Nerd Font - Cascadia Code NF ─────────────────────────────────────────
Step 10 $Total "Cascadia Code NF Font..."

$SysFonts    = "$env:SystemRoot\Fonts"
$FontCheck   = Join-Path $SysFonts "CaskaydiaCoveNerdFont-Regular.ttf"
$FontCheck2  = Join-Path $SysFonts "CascadiaCodeNF-Regular.ttf"

if (-not $ForceUpdate -and ((Test-Path $FontCheck) -or (Test-Path $FontCheck2))) {
    Skipped "Cascadia Code NF already installed."
    OK "Done."
} else {
    $FontZip     = "$env:TEMP\CascadiaCodeNF.zip"
    $FontDir     = "$env:TEMP\CascadiaCodeNF"
    $FallbackUrl = "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.2.1/CascadiaCode.zip"

    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "PowerShell")

        INFO "Checking latest Nerd Fonts release via GitHub API..."
        $FontUrl = $FallbackUrl
        try {
            $api   = $wc.DownloadString("https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest")
            $json  = $api | ConvertFrom-Json
            $asset = $json.assets | Where-Object { $_.name -eq "CascadiaCode.zip" } | Select-Object -First 1
            if ($asset) { $FontUrl = $asset.browser_download_url }
        } catch { INFO "API lookup failed, using pinned release URL." }

        INFO "Downloading from: $FontUrl"
        $wc.DownloadFile($FontUrl, $FontZip)

        INFO "Extracting..."
        if (Test-Path $FontDir) { Remove-Item $FontDir -Recurse -Force }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($FontZip, $FontDir)

        $installed = 0
        foreach ($font in (Get-ChildItem $FontDir -Recurse -Include "*.ttf","*.otf")) {
            $dest = Join-Path $SysFonts $font.Name
            if (-not (Test-Path $dest)) {
                Copy-Item $font.FullName -Destination $SysFonts -Force
                New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts" `
                    -Name ($font.BaseName + " (TrueType)") -Value $font.Name -PropertyType String -Force | Out-Null
                $installed++
            }
        }
        Remove-Item $FontZip, $FontDir -Recurse -Force -ErrorAction SilentlyContinue
        OK "$installed font files installed. Set Windows Terminal font to: CaskaydiaCove Nerd Font"
    } catch {
        WARN "Font install failed: $_"
        WARN "Download manually: https://www.nerdfonts.com/font-downloads (search CascadiaCode)"
    }
}

# ── 11. VS Code Extensions ───────────────────────────────────────────────────
Step 11 $Total "VS Code Extensions..."
if (Get-Command code -ErrorAction SilentlyContinue) {
    $Extensions = @(
        "ms-python.python",
        "ms-python.black-formatter",
        "ms-vscode.powershell",
        "dbaeumer.vscode-eslint",
        "esbenp.prettier-vscode",
        "ms-vscode.vscode-typescript-next",
        "formulahendry.auto-rename-tag",
        "pkief.material-icon-theme",
        "zhuangtongfa.material-theme",
        "github.copilot",
        "eamodio.gitlens",
        "ms-azuretools.vscode-docker",
        "mtxr.sqltools",
        "christian-kohler.path-intellisense"
    )

    # Get all installed extensions in one shot
    $installedExts = code --list-extensions 2>&1

    foreach ($ext in $Extensions) {
        if ($ForceUpdate -or ($installedExts -notcontains $ext)) {
            INFO "Installing $ext..."
            code --install-extension $ext --force 2>&1 | Out-Null
        } else {
            Skipped "$ext already installed."
        }
    }
    OK "VS Code extensions done."
} else {
    WARN "VS Code not found in PATH yet. Reboot and re-run to install extensions."
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Banner "ALL DONE! YOUR DEV ENVIRONMENT IS FULLY CONFIGURED." "Green"
Write-Host @"

  TIP: Re-run this script anytime - it skips what's already set up.
  Set ForceUpdate = $true at the top to force reinstall everything.

  NEXT STEPS (only needed once after first run):
  ---------------------------------------------------------
  1. REBOOT your PC so PATH changes take effect.

  2. Open Windows Terminal -> Settings -> Profiles -> Default
     -> Appearance -> Font face -> set to: CaskaydiaCove Nerd Font

  3. Right-click your PowerShell / CMD shortcuts in Start
     -> Properties -> Advanced -> check "Run as administrator"

  LINUX-STYLE COMMANDS (work in both PowerShell and CMD):
  ---------------------------------------------------------
  ls / ll / la  -> list files (ll=detailed, la=hidden too)
  cat           -> print file contents
  grep          -> search inside files
  touch         -> create empty file or update timestamp
  which         -> show where a command is located
  find          -> search for files by name
  head / tail   -> first/last N lines of a file
  df            -> disk free space on all drives
  du            -> size of a folder
  sudo          -> run as Admin
  open          -> open file or folder in Explorer
  env           -> list all environment variables
  kill          -> stop a process by name or PID
  man           -> show help for any command
  rm/cp/mv      -> already work natively in both

  SHORTCUTS:
  ---------------------------------------------------------
  ps         -> open PowerShell 7 as Admin
  powershell -> also opens PowerShell 7
  py         -> run Python 3.11
  c.         -> open VS Code in current folder

  PROJECT NAVIGATION (PowerShell and CMD):
  ---------------------------------------------------------
  ccode    -> your code folder (~\code)
  projects -> list all project folders  (PowerShell only)

"@ -ForegroundColor White

Read-Host "Press ENTER to close"
