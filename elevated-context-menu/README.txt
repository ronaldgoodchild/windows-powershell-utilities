Elevated PowerShell / Python right-click menu
==============================================

Installs a right-click entry on .ps1 and .py files:
  "Run with PowerShell (Admin)"
  "Run with Python (Admin)"

Both run elevated with NO UAC prompt, via a Scheduled Task registered with
"Highest privileges" — Windows lets Task Scheduler launch such a task for an
Administrator account silently, which a plain right-click "Run as
administrator" cannot do.

REQUIREMENT: your Windows account must be a local Administrator for the
silent part to work. On a standard account you'll still see a UAC prompt
(Windows won't skip it for non-admins, by design).

INSTALL (on each PC, no admin rights needed to run this step):
  1. Copy this whole folder to the target PC.
  2. Open a normal (non-admin) PowerShell window in the folder.
  3. Run:
       powershell -ExecutionPolicy Bypass -File Install.ps1

USE:
  Right-click any .ps1 or .py file -> pick the new "(Admin)" entry.
  A new elevated console window opens running the script.

UNINSTALL:
       powershell -ExecutionPolicy Bypass -File Uninstall.ps1

HOW IT WORKS (for reference):
  - Install.ps1 drops two tiny launcher scripts and two Scheduled Tasks
    (ElevatedRunPS1 / ElevatedRunPY) under C:\ProgramData\ElevatedRunner.
  - The right-click command (per-user registry, HKCU — no admin needed to
    install) writes the clicked file's path into a marker file, then runs
    `schtasks /run /tn ElevatedRunPS1` (or ...PY).
  - The scheduled task, already configured for Highest privileges, launches
    silently elevated and starts a new PowerShell/cmd window running your
    actual script.

NOTE: python.exe must be on PATH for the Python entry to work (Install.ps1
auto-detects it if present; otherwise edit Launcher-PY.ps1 to hardcode the
full path to python.exe).
