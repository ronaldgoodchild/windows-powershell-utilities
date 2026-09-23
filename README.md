# Windows PowerShell Utilities

A small collection of free, single-file Windows utilities written in PowerShell. No installers, no dependencies.

| Tool | Folder | What it does |
|------|--------|--------------|
| **Nerd Mode** | [`nerdmode/`](nerdmode/) | Read-only, WPF system inspector: live CPU/RAM/disk/network, hardware info, uptime, battery, top processes, JSON/text snapshot export. No admin needed. |
| **DevSetup** | [`devsetup/`](devsetup/) | One re-runnable script that sets up a full developer PC: PowerShell 7, Python, Git, VS Code and friends, plus PowerShell/CMD profiles with handy aliases. |
| **Elevated Context Menu** | [`elevated-context-menu/`](elevated-context-menu/) | Adds "Run with PowerShell (Admin)" / "Run with Python (Admin)" to the right-click menu, launching elevated **without a UAC prompt**. See the security note there. |

## Quick start

```powershell
git clone https://github.com/ronaldgoodchild/windows-powershell-utilities.git
cd windows-powershell-utilities

# Nerd Mode (no admin needed)
powershell -ExecutionPolicy Bypass -File .\nerdmode\NerdMode.ps1

# DevSetup (re-runnable, self-elevates)
powershell -ExecutionPolicy Bypass -File .\devsetup\DevSetup.ps1
```

`-ExecutionPolicy Bypass` only affects that one process; it does not change your system policy.

## Related projects

[windows-repair-tool](https://github.com/ronaldgoodchild/windows-repair-tool) - fix Windows Update and more - and [technicians-toolkit](https://github.com/ronaldgoodchild/technicians-toolkit) - an all-in-one technician GUI.

## Contributing

Ideas and pull requests welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) and [ROADMAP.md](ROADMAP.md).

## License

[MIT](LICENSE) (c) 2026 Ronald Goodchild / REGTeches
