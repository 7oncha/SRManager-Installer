# SR Manager C# Windows QA Checklist

Use this checklist before publishing a release that includes `SRManager.exe`.

## Build artifact

- Run `.\scripts\publish-srmanager.ps1`.
- Confirm `artifacts\SRManager\SRManager.exe` exists.
- Start `SRManager.exe` from a clean folder that contains:
  - `SRManager.exe`
  - `sr_shared_config.json`
  - `sr_logo.ico`
  - `sr_logo.png`

## First launch

- Confirm the main window opens without PowerShell.
- Confirm `sr_config.json` is created next to the exe.
- Confirm server list is loaded from `sr_shared_config.json` or the remote shared config.
- Confirm web and Discord buttons open the expected URLs.

## License

- Test with no cached license and confirm the license dialog appears.
- Activate with a valid license key.
- Restart and confirm the cached license is accepted.
- Temporarily block the license API and confirm the grace-period behavior works for a previously valid license.

## Server status

- Confirm the Dashboard shows online/offline status for the active server.
- Confirm map name, player count, and player list are parsed from the XML feed.
- Confirm switching server updates the status and mod list.

## Mods

- Set the FS25 mods folder in Settings.
- Run "Provjeri modove".
- Confirm missing, outdated, OK, and extra mods are classified correctly.
- Download missing mods and confirm zip files appear in the selected mods folder.
- Re-run the check and confirm downloaded mods move to OK.

## Game settings and launch

- Set `FarmingSimulator2025.exe` in Settings.
- Toggle intro scene and developer console, then confirm `gameSettings.xml` is updated.
- Confirm `modsDirectoryOverride` points to the selected mods folder.
- Click "Udi na server".
- Confirm server password is written to `gameSettings.xml` when configured.
- Confirm FS25 starts.
- Confirm launcher closes after the game starts.
- After exiting FS25, confirm `/api/license/session-end` is received by the backend.

## Update

- Publish a GitHub release with `SRManager.exe` asset.
- Confirm the launcher detects the newer version.
- Click update and confirm:
  - New exe downloads.
  - Old exe is replaced after shutdown.
  - Launcher restarts.
