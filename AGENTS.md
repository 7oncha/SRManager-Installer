# SR Manager - Agent Instructions

## Jezik i stil koda

- **Komunikacija s korisnikom:** na **hrvatskom** jeziku
- **Kod i nazivi varijabli/funkcija:** na **engleskom**
- **Komentari u kodu:** na **hrvatskom**
- **Commit poruke i PR opisi:** na **engleskom** (GitHub standard)

## Cursor Cloud specific instructions

### Project overview

SR Manager is being migrated from a **Windows-only PowerShell/WPF GUI application** to a **Windows-only C#/.NET 8 WPF application** — a launcher/manager for the "Slavonska Ravnica" Farming Simulator 25 community. The legacy main application is a single PowerShell script (`SlavonskaRavnica.ps1`, ~5600 lines, 59 functions). The new C# project lives in `src/SRManager`.

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

- The full GUI **cannot run on Linux** — it requires Windows WPF, Windows Registry/DPAPI, and FS25-specific Windows paths.
- **PowerShell Core (`pwsh`)** may not be installed on every Cloud Agent image. If present, it can parse/syntax-check all `.ps1` scripts using the AST parser.
- **.NET SDK may not be installed** on every Cloud Agent image. If missing, a temporary SDK can be installed with `dotnet-install.sh` into `/tmp/dotnet` for validation.
- Non-GUI utility functions (SHA256 hashing, HTTP requests, JSON parsing) can be executed via `pwsh` on Linux for validation.

### Key commands

| Task | Command |
|------|---------|
| Build C# launcher | `dotnet build src/SRManager/SRManager.csproj -c Release` |
| Publish C# launcher | `dotnet publish src/SRManager/SRManager.csproj -c Release -r win-x64 --self-contained true` |
| Publish via helper script | `pwsh scripts/publish-srmanager.ps1` |
| Syntax-check a script | `pwsh -NoProfile -Command '[System.Management.Automation.Language.Parser]::ParseFile("SlavonskaRavnica.ps1", [ref]$null, [ref]$errors); if ($errors.Count -eq 0) { "OK" } else { $errors }'` |
| Validate JSON config | `pwsh -NoProfile -Command 'Get-Content sr_shared_config.json -Raw \| ConvertFrom-Json'` |
| Query game server | `pwsh -NoProfile -Command '$c=(Get-Content sr_shared_config.json -Raw \| ConvertFrom-Json).servers[0]; (Invoke-WebRequest "http://$($c.ip):$($c.webPort)/feed/dedicated-server-stats.xml?code=$($c.statsCode)" -UseBasicParsing -TimeoutSec 10).Content'` |

### Important files

- `src/SRManager` — new C#/.NET 8 WPF launcher project
- `SlavonskaRavnica.ps1` — legacy PowerShell application (all logic, UI, and networking), retained as migration fallback
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

### Auto-update flow

- Legacy PowerShell: `Check-ForUpdate`: bot endpoint (`/launcher/latest`) → fallback GitHub Releases API
- Legacy PowerShell: `Download-Update`: uvijek skida `.ps1` s GitHub raw + release assete (.exe/.zip)
- C# launcher: `UpdateService` checks bot endpoint → GitHub Releases fallback, then replaces `SRManager.exe` via a temporary `.cmd` updater.
- Bot dinamicki dohvaca najnoviji release — ne treba rucno azurirati `latest.json`

### Installer flow

- `Install_SRManager.bat` koristi `certutil` (ne PowerShell!) za download — izbjegava AV false positive
- Novi installer skida: `SRManager.exe` (GitHub release) + config + ikone. Ne skida vise PowerShell `.ps1` za nove instalacije.
- GUI installer (`Install_SRManager.ps1`) isto radi ali koristi PowerShell WPF GUI.
- `SR Manager.bat` / `SR Manager.vbs` prvo pokrecu `SRManager.exe`; ako ne postoji, fallback je legacy `SlavonskaRavnica.ps1`.

### Gotchas

- **`.gitattributes`** ima `*.ps1 -text` — CRLF se cuva u git blobovima jer `raw.githubusercontent.com` servira blob as-is. Bez toga, stari launcher pise LF fajlove koji ne rade na Windows PS 5.1.
- The game server XML feed includes a UTF-8 BOM. Trim with `.TrimStart([char]0xFEFF)` before parsing.
- Legacy `SRManager.exe` bio je samo wrapper (92 KB) koji pokrece `SlavonskaRavnica.ps1`. Nakon C# migracije `SRManager.exe` treba biti full self-contained app (~155 MB) iz `src/SRManager`.
- There are no automated tests. Validation is limited to syntax parsing.
- `$script:LicenseRepoOwner` i ostale licence konstante su **nekorištene** — licenciranje je potpuno preko HTTP API-ja.
- Licenca se veže na HWID (MachineGuid + CPU ID + Motherboard SN). Ako se HWID promijeni, `apiActivate` vraća `hwid_mismatch`. Rebind se može zatražiti kroz Discord admin panel.

### C# migracija - trenutno stanje

- Grana `cursor/stabilize-launcher-dd43` / PR #12 dodaje prvi C#/.NET 8 WPF port u `src/SRManager`.
- Cilj dizajna: stabilan kompajlirani `SRManager.exe` bez PowerShell source visibility, CRLF/LF problema i AV problema koje je imao skriptni launcher.
- PowerShell launcher ostaje u repozitoriju kao fallback dok se C# release artefakt ne objavi i dok postojece instalacije ne migriraju.
- Portani su kljucni servisi: config sync, license activate/heartbeat/session-end, server status XML, bot mod manifest + `mods.html` fallback, SHA-256 mod compare, mod download, `gameSettings.xml`, FS25 launch i exe self-update.
- UI u C# portu pokriva Dashboard/Modovi/Postavke/Log i licencni modal, ali nije jos 1:1 vizualna kopija cijelog starog PowerShell XAML-a.
- `.github/workflows/srmanager-dotnet.yml` builda C# launcher na PR/push i kod GitHub Release publish eventa upload-a `SRManager.exe` asset. Installer ocekuje asset tocno pod tim imenom.
- Prije release-a na Windows stroju proci `docs/windows-qa-checklist.md`; Linux agent moze buildati WPF projekt, ali ne moze otvoriti GUI ni testirati FS25 integraciju.

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

### ktomasic66-coder/Server-Bot (Farmbuddy Bot — privatni repo)

**URL produkcije:** `https://server-bot-production-a3a0.up.railway.app`
**Stack:** TypeScript, Express 5, Discord.js 14, Drizzle ORM, MySQL (runtime storage), Vite + React (admin panel), basic-ftp (telemetry)
**Node:** >=20.18.0 (`.nvmrc`: 22)

**Struktura:**
- `server/index.ts` — entry point (Express + Vite dev)
- `server/routes.ts` — svi API routes (~1900 linija), auth middleware, launcher distribucija
- `server/bot.ts` — Discord bot (~2000+ linija): slash komande, sync timeri, paneli, moderacija, muzika
- `server/license.ts` — licence sustav: `apiActivate`, `apiHeartbeat`, `apiSessionEnd`, `apiTrialRequest`
- `server/modSync.ts` — FTP poll `/profile/mods/*.zip`, SHA-256 hash, manifest
- `server/modScheduler.ts` — interval poll + notifikacije
- `server/sync.ts` — `FarmSyncService`: FTP telemetry (polja, vozila, silosi, životinje, vrijeme)
- `server/storage.ts` — MySQL-backed document collections (`app_documents` tablica)
- `shared/schema.ts` — Drizzle PostgreSQL schema (farms, fields, vehicles, players)
- `client/` — React admin panel (Dashboard, MojaFarma, StatusCard, BackupPanel...)

**Pokretanje:**
- `npm run dev` → `tsx server/index.ts` (Express + Vite dev server)
- `npm run build` → client build + esbuild server bundle
- `npm run start` → `node dist/index.mjs`

**Env varijable (ključne):**
- `DATABASE_URL` — MySQL connection string (runtime storage za licence, modove, kolekcije)
- `DISCORD_TOKEN` — Discord bot token
- `LICENSE_API_TOKEN` — Bearer token koji launcher šalje (ovo je ono u `sr_shared_config.json → licenseApi.token`)
- `FS25_SERVERS` — JSON array za multi-server FTP config
- `PORT` — HTTP port (default 3000)

**API endpointi koje launcher koristi:**

| Endpoint | Auth | Handler | Datoteka |
|----------|------|---------|----------|
| `POST /api/license/activate` | Bearer | `apiActivate()` | `server/license.ts` |
| `POST /api/license/heartbeat` | Bearer | `apiHeartbeat()` | `server/license.ts` |
| `POST /api/license/session-end` | Bearer | `apiSessionEnd()` | `server/license.ts` |
| `POST /api/license/trial` | Javni (IP rate limit) | `apiTrialRequest()` | `server/license.ts` |
| `GET /api/mods/manifest` | Bearer | `getManifest()` | `server/modSync.ts` |
| `GET /api/mods/changes-since` | Bearer | `getChangesSince()` | `server/modSync.ts` |

**FIXANO (PR #2, #3):**
1. Session middleware sada propušta `/mods/` putanje (isti pattern kao `/license/`)
2. `resolveServerId()` funkcija resolva server po ID-u ili imenu (launcher šalje ime jer config nema `id` polje)
