# SR Manager - Agent Instructions

## Jezik i stil koda

- **Komunikacija s korisnikom:** na **hrvatskom** jeziku
- **Kod i nazivi varijabli/funkcija:** na **engleskom**
- **Komentari u kodu:** na **hrvatskom**
- **Commit poruke i PR opisi:** na **engleskom** (GitHub standard)

## Cursor Cloud specific instructions

### Project overview

SR Manager is a **Windows-only PowerShell/WPF GUI application** — a launcher/manager for the "Slavonska Ravnica" Farming Simulator 25 community. The main application is a single PowerShell script (`SlavonskaRavnica.ps1`, ~5600 lines, 59 functions) with no package manager, no build system, and no test framework.

### Ecosystem — related repositories

This repo is part of a multi-repo ecosystem:

| Repo | Purpose | Stack |
|------|---------|-------|
| **7oncha/SRManager-Installer** (this repo) | Windows launcher + installer scripts | PowerShell/WPF |
| **ktomasic66-coder/FS-web** | Community website + Discord bot + farm dashboard | Node.js, Express 5, EJS, Discord.js, MongoDB, MySQL |
| **ktomasic66-coder/slavonska-ravnica** | Marketing landing page | Next.js 16, React 19, Tailwind 4 |
| **Farmbuddy bot API** (deployed on Railway) | License validation + mod manifest API | Separate codebase, not in accessible repos |

**How they connect:**

1. The **launcher** (`SlavonskaRavnica.ps1`) calls the **Farmbuddy bot API** (Railway) for:
   - License activation/heartbeat/session-end (`POST /api/license/*` with Bearer token)
   - Mod manifest with SHA-256 hashes (`GET /api/mods/manifest?server=<id>`)
   - Mod change detection (`GET /api/mods/changes-since?server=<id>&since=<date>`)
2. If the bot API is unreachable or returns no data, the launcher **falls back** to scraping `mods.html` from the game server directly (legacy path, no SHA-256 verification).
3. **FS-web** reads the same MongoDB that the Farmbuddy bot writes to (`player_links`, `farms`, `server_info`, etc.) for the community dashboard/farm pages.
4. The launcher auto-updates from **this repo's** raw GitHub content (not from the other repos).

**Config wiring:** `sr_shared_config.json` contains `licenseApi.url` and `licenseApi.token` used by the launcher to authenticate with the bot API via Bearer token.

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
- `sr_shared_config.json` — server IPs, ports, stats codes, license API config (`licenseApi.url`, `licenseApi.token`)
- `Install_SRManager.ps1` — GUI installer script
- `SR Manager.bat` / `SR Manager.vbs` — launcher wrappers

### External services

The app depends on external services (game server XML API, license API on Railway, GitHub raw content for auto-update). These are live production services — the game server at `176.57.169.250:8620` and license API at `server-bot-production-a3a0.up.railway.app` are reachable from the VM.

### Mod sync flow (launcher ↔ bot)

1. `Refresh-ModList` → calls `Get-ServerModList`
2. `Get-ServerModList` first tries `Get-ModManifestFromBot` → `Invoke-ModApi("manifest")` → `GET /api/mods/manifest?server=<id>` with Bearer token
3. If bot manifest succeeds, mods are compared by SHA-256 hash (preferred path)
4. If bot fails, falls back to scraping `mods.html` from game server (legacy, size-only comparison)

### Gotchas

- The game server XML feed includes a UTF-8 BOM (`\xEF\xBB\xBF`). When parsing in PowerShell Core on Linux, trim it with `.TrimStart([char]0xFEFF)` before loading as XML.
- The bot API mod endpoints currently return **HTTP 401** with the token in `sr_shared_config.json` — the token may need rotation or the bot API auth may have changed.
- There are no automated tests in this repo. Validation is limited to syntax parsing and manual testing of utility functions.
- The `.gitignore` excludes `*.exe` — the compiled .NET 8 WPF application (`SRManager.exe`) is distributed via GitHub Releases, not tracked in this repo.
- `$script:LicenseRepoOwner`, `$script:LicenseRepoName`, `$script:LicenseFile`, `$script:LicenseBranch` constants in the script reference a `licenses.json` file on GitHub but are **unused** — actual licensing is fully via the HTTP API.

---

## Kontekst povezanih repozitorija

### ktomasic66-coder/FS-web (Community website + Discord bot)

**Stack:** Node.js, Express 5, EJS, Discord.js 14, MongoDB, MySQL (optional), Passport-Discord OAuth

**Što radi:**
- Community web stranica s Discord OAuth loginom
- Discord bot (gallery, role sync, log channels)
- Dashboard: statistike, "Moja Farma", galerija, pravila, novosti
- Admin panel za upravljanje contentom
- Money transfer API između igrača (`/api/money-transfer`)

**Ključne datoteke:**
- `server.js` — sav backend + bot logic (~3400 linija)
- `player.js` — player count iz game servera (XML/Steam query)
- `views/*.ejs` — frontend stranice
- `public/` — statički resursi

**Važno:**
- Koristi **isti MongoDB** kao Farmbuddy bot (dijele kolekcije: `player_links`, `farms`, `players`, `fields`, `vehicles`, `silos`, `productions`, `animals`, `server_info`)
- **NE implementira** `/api/license/*` ni `/api/mods/*` — to je Farmbuddy bot API (zasebni codebase, deployan na Railway)
- Auth je Discord OAuth + session cookie, **ne** Bearer token
- Env varijable: `PORT`, `SESSION_SECRET`, `CLIENT_ID`, `CLIENT_SECRET`, `CALLBACK_URL`, `DISCORD_BOT_TOKEN`, `GUILD_ID`, `MONGO_URI`, `MONGO_URL`, `MYSQL_URL` (optional)

### ktomasic66-coder/slavonska-ravnica (Landing page)

**Stack:** Next.js 16, React 19, Tailwind CSS 4, TypeScript

**Što radi:**
- Jednostavna marketing/landing stranica za community
- Jedna stranica (`app/page.tsx`) — hero, "O Serveru", "Natjecateljski Model"
- **Nema API-ja**, nema backenda, nema baze

**Napomena:** `public/logo.png` je referenciran u kodu ali **nije** committan u repo — slike će biti broken bez tog filea.

### Farmbuddy Bot API (Railway deployment)

**URL:** `https://server-bot-production-a3a0.up.railway.app`
**Codebase:** Privatni/nedostupni repo (možda `ktomasic66-coder/Server-Bot` — treba pristup)

**API endpointi koje launcher koristi:**
- `POST /api/license/activate` — aktivacija licence (key + HWID)
- `POST /api/license/heartbeat` — heartbeat za aktivnu sesiju
- `POST /api/license/session-end` — kraj sesije
- `POST /api/license/trial` — trial licence
- `GET /api/mods/manifest?server=<id>` — lista modova s SHA-256 hashevima
- `GET /api/mods/changes-since?server=<id>&since=<date>` — promjene modova

**Auth:** Bearer token iz `sr_shared_config.json` → `licenseApi.token`

**Trenutni status:** Mod endpointi vraćaju HTTP 401 — token je vjerojatno istekao/promijenjen.
