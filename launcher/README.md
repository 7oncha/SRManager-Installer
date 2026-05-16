# Launcher distribucija (ZIP + embed)

## Datoteke

| Fajl | Namjena |
|------|---------|
| `manifest.json` | Verzija + **downloadUrl** za ZIP (launcher i web ga citaju) |
| `embed.json` | Discord embed (naslov, opis, link na ZIP) |
| `download.html` | Embed na webu (iframe) — ucitava manifest |

Nakon svakog releasea pokreni `Build-SRManagerZip.ps1` — azurira `manifest.json` i `embed.json`.

## Bot (Farmbuddy) — `/launcher/latest`

Trenutno bot vraca `SRManager.exe`. Promijeni u `server/routes.ts` (ili gdje je handler):

1. Na GitHub releaseu preferiraj asset **`SR_Manager.zip`**
2. `downloadUrl` = URL tog zipa
3. `file` = `SR_Manager.zip`
4. `installType` = `zip`

Ili ucitaj embed iz raw GitHuba:

`https://raw.githubusercontent.com/7oncha/SRManager-Installer/master/launcher/embed.json`

Discord poruka: koristi `embed.json` za `EmbedBuilder` + gumb link = `downloadUrl`.

## Web embed

```html
<iframe src="https://raw.githubusercontent.com/7oncha/SRManager-Installer/master/launcher/download.html"
        width="440" height="320" style="border:0;border-radius:12px"></iframe>
```

(Bolje hostati `download.html` na slavonska-ravnica.com/launcher)

## Launcher app

`SlavonskaRavnica.ps1` cita `launcher/manifest.json` za ZIP URL pri auto-updateu.
