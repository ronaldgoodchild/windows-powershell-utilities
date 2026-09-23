# Elevated Context Menu

Adds two entries to the Explorer right-click menu:

- **Run with PowerShell (Admin)** on `.ps1` files
- **Run with Python (Admin)** on `.py` files

Both launch elevated **with no UAC prompt**, using a Scheduled Task registered with "Highest privileges". Windows lets Task Scheduler start such a task silently for an Administrator account, which a plain right-click "Run as administrator" cannot do.

## Security note - please read

This is, by design, a **UAC bypass for your own administrator account**. Anything running unelevated as your user (for example malware you launched by mistake) could use the same mechanism to run code elevated without a prompt. Only install it:

- on **your own** personal or lab machines,
- under a **local Administrator** account you trust,
- never on shared, managed or client machines, and never on machines where you cannot afford that trade-off.

On a standard (non-admin) account the silent elevation does not work and you still get a UAC prompt.

## Install

No admin rights are needed to run the installer (it writes to `C:\ProgramData\ElevatedRunner` and `HKCU`).

```powershell
powershell -ExecutionPolicy Bypass -File Install.ps1
```

Then right-click any `.ps1` or `.py` file and choose the new "(Admin)" entry. A new elevated console window runs your script.

`python.exe` must be on `PATH` for the Python entry.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File Uninstall.ps1
```

## How it works

1. `Install.ps1` writes two tiny launcher scripts and registers two Scheduled Tasks (`ElevatedRunPS1`, `ElevatedRunPY`) with `RunLevel = Highest` and no trigger.
2. The right-click command (per-user registry, `HKCU`) writes the clicked file's path to a marker file and runs `schtasks /run /tn ElevatedRunPS1` (or `...PY`).
3. The task, already configured for Highest privileges, starts silently elevated and opens a new PowerShell / `cmd` window running your script.
