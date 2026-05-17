# Sastavi SR_Manager.zip za GitHub release (bez installera)
# Pokreni:  pwsh -File Build-SRManagerZip.ps1
# Izlaz:    dist\SR_Manager.zip
# Referenca (generic hub, bez izvornog koda): FarmSim Hub MSI npr.
#   C:\Users\7onch\Desktop\FarmSim Hub_3.0.9_x64_en-US.msi
#   ili dist\farmsim_msi_extract\PFiles\FarmSim Hub\farmsim-hub.exe

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo = '7oncha/SRManager-Installer'
$botUrl = 'https://server-bot-production-a3a0.up.railway.app'
$rawBase = "https://raw.githubusercontent.com/$repo/master"
$releaseExe = 'https://github.com/7oncha/SRManager-Installer/releases/latest/download/SRManager.exe'
$ua = @{ 'User-Agent' = 'SRManager-BuildZip' }

$root = $PSScriptRoot
$stage = Join-Path $root 'dist\SR_Manager'
$zipPath = Join-Path $root 'dist\SR_Manager.zip'

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

function Get-Url([string]$url, [string]$dest) {
    Write-Host "  -> $([IO.Path]::GetFileName($dest))"
    Invoke-WebRequest -Uri $url -OutFile $dest -Headers $ua -UseBasicParsing
}

Write-Host '[1] SRManager.exe (release)...'
$exeDest = Join-Path $stage 'SRManager.exe'
try {
    Get-Url $releaseExe $exeDest
} catch {
    $localExe = @(
        (Join-Path $root '_gh_dl\extracted\SRManager.exe'),
        (Join-Path $root '_verify_zip\SRManager.exe')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($localExe) {
        Copy-Item $localExe $exeDest -Force
        Write-Host '  (lokalni SRManager.exe - GitHub download nije uspio)'
    } else { throw }
}
if ((Get-Item $exeDest).Length -lt 10KB) {
    throw 'SRManager.exe premali ili prazan - provjeri GitHub release.'
}

Write-Host '[2] Launcher skripta...'
$ps1 = Join-Path $stage 'SlavonskaRavnica.ps1'
$localPs1 = Join-Path $root 'SlavonskaRavnica.ps1'
if (Test-Path $localPs1) {
    Copy-Item $localPs1 $ps1 -Force
    Write-Host '  (lokalna SlavonskaRavnica.ps1)'
} else {
    try { Get-Url "$botUrl/launcher/script" $ps1 } catch { Get-Url "$rawBase/SlavonskaRavnica.ps1" $ps1 }
}

Write-Host '[3] Config (bot, fallback GitHub)...'
$cfg = Join-Path $stage 'sr_shared_config.json'
try {
    Get-Url "$botUrl/launcher/config" $cfg
} catch {
    Get-Url "$rawBase/sr_shared_config.json" $cfg
}

Write-Host '[4] Ikone + upute iz package/...'
Get-Url "$rawBase/sr_logo.ico" (Join-Path $stage 'sr_logo.ico')
try { Get-Url "$rawBase/sr_logo.png" (Join-Path $stage 'sr_logo.png') } catch {}

$pkg = Join-Path $root 'package'
Copy-Item (Join-Path $pkg 'CITAJME.txt') (Join-Path $stage 'CITAJME.txt') -Force
Copy-Item (Join-Path $pkg 'Pokreni SR Manager.bat') (Join-Path $stage 'Pokreni SR Manager.bat') -Force
Copy-Item (Join-Path $pkg 'SR Manager.vbs') (Join-Path $stage 'SR Manager.vbs') -Force
if (Test-Path (Join-Path $pkg 'TEST-POKRENI.bat')) {
    Copy-Item (Join-Path $pkg 'TEST-POKRENI.bat') (Join-Path $stage 'TEST-POKRENI.bat') -Force
}
if (Test-Path (Join-Path $pkg 'Fix-Desktop-Shortcut.bat')) {
    Copy-Item (Join-Path $pkg 'Fix-Desktop-Shortcut.bat') (Join-Path $stage 'Fix-Desktop-Shortcut.bat') -Force
}

Write-Host '[5] ZIP...'
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath)

$mb = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)

Write-Host '[6] manifest.json + embed.json...'
$localPs1ForVer = Join-Path $root 'SlavonskaRavnica.ps1'
$ver = $null
if (Test-Path $localPs1ForVer) {
    $m = [regex]::Match((Get-Content $localPs1ForVer -Raw), '\$script:AppVersion\s*=\s*"([^"]+)"')
    if ($m.Success) { $ver = $m.Groups[1].Value }
}
if (-not $ver) {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $ua
    $ver = ($rel.tag_name -replace '^v','')
}
$tag = if ($ver -match '^v') { $ver } else { "v$ver" }
$zipUrl = "https://github.com/$repo/releases/download/$tag/SR_Manager.zip"
$releasePageUrl = "https://github.com/$repo/releases/tag/$tag"

$launcherDir = Join-Path $root 'launcher'
if (-not (Test-Path $launcherDir)) { New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null }

$srFeatures = @(
    'Vise FS25 servera + ping i live status'
    'Licenca / HWID / probna 3 dana (bot API)'
    'SHA-256 mod manifest i sync (server-authoritative)'
    'GitHub auto-update (ZIP + SlavonskaRavnica.ps1)'
    'Admin mod, bot config sync, session heartbeat'
    'UI 2.2: vodic, sidebar sekcije, mod grid, scroll Savegame'
    'Mod thumbnails iz ZIP (modDesc), filter po kategoriji'
    'Desktop shortcut -> Pokreni SR Manager.bat'
)
$manifest = @{
    version         = $ver
    downloadFile    = 'SR_Manager.zip'
    installType     = 'zip'
    downloadUrl     = $zipUrl
    releasePageUrl  = $releasePageUrl
    updatedAt       = (Get-Date).ToUniversalTime().ToString('o')
    instructions    = 'Skini ZIP, raspakiraj u folder, pokreni Pokreni SR Manager.bat (NE SRManager.exe)'
    features        = $srFeatures
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $launcherDir 'manifest.json') -Encoding UTF8

$featBlock = ($srFeatures | ForEach-Object { "- $_" }) -join "`n"
$embed = @{
    title        = 'SR Manager - Slavonska Ravnica'
    description  = "Skini **SR_Manager.zip**, raspakiraj i pokreni **Pokreni SR Manager.bat** (ili SR Manager.vbs).`n`n**NE** pokreci SRManager.exe - to je stari installer.`n`nProblem? **TEST-POKRENI.bat**"
    color        = 16056599
    thumbnail    = @{ url = "$rawBase/sr_logo.png" }
    fields       = @(
        @{ name = 'Verzija'; value = $tag; inline = $true }
        @{ name = 'Datoteka'; value = 'SR_Manager.zip'; inline = $true }
        @{ name = 'Koraci'; value = "1. Skini ZIP`n2. Raspakiraj cijeli folder`n3. Pokreni Pokreni SR Manager.bat"; inline = $false }
        @{ name = 'SR Manager (vs generic hub)'; value = $featBlock; inline = $false }
    )
    url          = $zipUrl
    downloadUrl  = $zipUrl
    downloadFile = 'SR_Manager.zip'
    installType  = 'zip'
    buttonLabel  = 'Skini SR Manager (ZIP)'
}
$embed | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $launcherDir 'embed.json') -Encoding UTF8

Write-Host ""
Write-Host "Gotovo: $zipPath ($mb MB)" -ForegroundColor Green
Write-Host "Push na GitHub: dist/SR_Manager.zip + launcher/manifest.json + launcher/embed.json"
Write-Host "Uploadaj SR_Manager.zip na GitHub Release asset (tag $tag)."
