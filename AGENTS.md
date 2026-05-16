# SR Manager - Agent Instructions

## Cursor Cloud specific instructions

### Project overview

SR Manager is a **Windows-only PowerShell/WPF GUI application** — a launcher/manager for the "Slavonska Ravnica" Farming Simulator 25 community. The main application is a single PowerShell script (`SlavonskaRavnica.ps1`, ~5600 lines, 59 functions) with no package manager, no build system, and no test framework.

### Development on Linux (Cloud Agent environment)

- The full GUI **cannot run on Linux** — it requires Windows PowerShell 5.1+, WPF (PresentationFramework), Win32 P/Invoke (`user32.dll`, `kernel32.dll`, `shell32.dll`), WMI, Windows Registry, and DPAPI.
- **PowerShell Core (`pwsh`)** is installed on the VM and can parse/syntax-check all `.ps1` scripts using the AST parser.
- Non-GUI utility functions (SHA256 hashing, HTTP requests, JSON parsing) can be executed via `pwsh` on Linux for validation.

### Key commands

| Task | Command |
|------|---------|
| Syntax-check a script | `pwsh -NoProfile -Command '[System.Management.Automation.Language.Parser]::ParseFile("SlavonskaRavnica.ps1", [ref]$null, [ref]$errors); if ($errors.Count -eq 0) { "OK" } else { $errors }'` |
| Validate JSON config | `pwsh -NoProfile -Command 'Get-Content sr_shared_config.json -Raw \| ConvertFrom-Json'` |
| Query game server | `pwsh -NoProfile -Command '$c=(Get-Content sr_shared_config.json -Raw \| ConvertFrom-Json).servers[0]; (Invoke-WebRequest "http://$($c.ip):$($c.webPort)/feed/dedicated-server-stats.xml?code=$($c.statsCode)" -UseBasicParsing -TimeoutSec 10).Content'` |

### Important files

- `SlavonskaRavnica.ps1` — main application (all logic, UI, and networking)
- `sr_shared_config.json` — server IPs, ports, stats codes, license API config
- `Install_SRManager.ps1` — GUI installer script
- `SR Manager.bat` / `SR Manager.vbs` — launcher wrappers

### External services

The app depends on external services (game server XML API, license API on Railway, GitHub raw content for auto-update). These are live production services — the game server at `176.57.169.250:8620` and license API at `server-bot-production-a3a0.up.railway.app` are reachable from the VM.

### Gotchas

- The game server XML feed includes a UTF-8 BOM (`\xEF\xBB\xBF`). When parsing in PowerShell Core on Linux, trim it with `.TrimStart([char]0xFEFF)` before loading as XML.
- There are no automated tests. Validation is limited to syntax parsing and manual testing of utility functions.
- The `.gitignore` excludes `*.exe` — the compiled .NET 8 WPF application (`SRManager.exe`) is distributed via GitHub Releases, not tracked in this repo.
