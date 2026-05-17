#Requires -Version 5.1
# ============================================================
# Slavonska Ravnica Launcher v1.0
# Author: Anthony
# GitHub Auto-Update | Multi-Server | Admin/Player | Mod Sync
# ============================================================

# TEST-POKRENI.bat postavlja SR_MANAGER_TEST=1 - ne skrivaj konzolu (dijagnostika)
$script:IsTestLaunch = ($env:SR_MANAGER_TEST -eq '1')

# Sakrij konzolu ODMAH - koristimo user32.dll direktno bez Add-Type kompilacije
# Add-Type -MemberDefinition koristi csc.exe koji otvori konzolu, zato koristimo alternativu
if (-not $script:IsTestLaunch) { try {
    $sig = '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);'
    $sig += '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();'
    if (-not ([System.Management.Automation.PSTypeName]'HideConsole.W32').Type) {
        Add-Type -MemberDefinition $sig -Name W32 -Namespace HideConsole -ErrorAction SilentlyContinue
    }
    $hw = [HideConsole.W32]::GetConsoleWindow()
    if ($hw -ne [IntPtr]::Zero) { [HideConsole.W32]::ShowWindow($hw, 0) | Out-Null }
} catch {} }

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

function Show-EarlySplash {
    if ($script:EarlySplash) { return }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'SR Manager'
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $f.ClientSize = New-Object System.Drawing.Size(360, 100)
    $f.TopMost = $true
    $f.BackColor = [System.Drawing.Color]::FromArgb(13, 13, 13)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Ucitavanje SR Manager...'
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(245, 197, 24)
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Regular)
    $lbl.AutoSize = $true
    $lbl.Location = New-Object System.Drawing.Point(48, 38)
    $f.Controls.Add($lbl) | Out-Null
    $f.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $script:EarlySplash = $f
}
function Close-EarlySplash {
    try {
        if ($script:EarlySplash) {
            $script:EarlySplash.Close()
            $script:EarlySplash.Dispose()
            $script:EarlySplash = $null
        }
    } catch {}
}
Show-EarlySplash

# Postavi AppUserModelID za taskbar (da ne pokazuje PowerShell ikonu)
try {
    $appIdSig = '[DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);'
    if (-not ([System.Management.Automation.PSTypeName]'SRManager.AppId').Type) {
        Add-Type -MemberDefinition $appIdSig -Name AppId -Namespace SRManager -ErrorAction SilentlyContinue
    }
    [SRManager.AppId]::SetCurrentProcessExplicitAppUserModelID("SRManager.SlavonskaRavnica.1.0") | Out-Null
} catch {}

# ============================================================
# CONSTANTS
# ============================================================
$script:AppVersion = "2.2.0.3"
$script:ConfigPath = Join-Path $PSScriptRoot "sr_config.json"
$script:IsAdmin = $false
$script:GitHubRepo = ""
$script:LatestVersion = $null
$script:ModListCached = $false
$script:ModThumbsPath = Join-Path $env:APPDATA 'SR-Launcher\mod-thumbs'

# License system
$script:LicenseRepoOwner = "7oncha"
$script:LicenseRepoName  = "SlavonskaRavnica-apk"
$script:LicenseFile      = "licenses.json"
$script:LicenseBranch    = "main"
$script:LicenseCachePath = Join-Path $env:APPDATA "SR-Launcher\license.dat"
$script:UserSettingsPath = Join-Path $env:APPDATA "SR-Launcher\user-settings.json"
$script:LicenseGraceHours = 24
$script:IsFullscreen = $false
$script:WindowRestore = $null

# ============================================================
# UTILITY FUNCTIONS
# ============================================================
function Get-SHA256 {
    param([string]$text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $hash = $sha.ComputeHash($bytes)
    $sha.Dispose()
    return ([BitConverter]::ToString($hash) -replace '-','').ToLower()
}

# ============================================================
# LICENSE - HWID
# ============================================================
function Get-Hwid {
    try {
        # MachineGuid
        $mg = ""
        try {
            $mg = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -ErrorAction Stop).MachineGuid
        } catch {}
        # CPU ID
        $cpu = ""
        try { $cpu = (Get-WmiObject Win32_Processor -ErrorAction Stop | Select-Object -First 1).ProcessorId } catch {}
        # Motherboard SN
        $mb = ""
        try { $mb = (Get-WmiObject Win32_BaseBoard -ErrorAction Stop).SerialNumber } catch {}
        $raw = "$mg|$cpu|$mb"
        if ($raw -eq "||") { $raw = $env:COMPUTERNAME + "|" + $env:USERNAME }
        return Get-SHA256 $raw
    } catch {
        return Get-SHA256 ($env:COMPUTERNAME + "|" + $env:USERNAME)
    }
}

# ============================================================
# LICENSE - CACHE (DPAPI per-user encrypted)
# ============================================================
function Save-LicenseCache {
    param([hashtable]$data)
    try {
        $dir = Split-Path $script:LicenseCachePath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $json = $data | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        Add-Type -AssemblyName System.Security
        $enc = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        [System.IO.File]::WriteAllBytes($script:LicenseCachePath, $enc)
        return $true
    } catch { return $false }
}
function Get-LicenseCache {
    try {
        if (-not (Test-Path $script:LicenseCachePath)) { return $null }
        $enc = [System.IO.File]::ReadAllBytes($script:LicenseCachePath)
        Add-Type -AssemblyName System.Security
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $json = [System.Text.Encoding]::UTF8.GetString($bytes)
        return $json | ConvertFrom-Json
    } catch { return $null }
}
function Clear-LicenseCache {
    try { if (Test-Path $script:LicenseCachePath) { Remove-Item $script:LicenseCachePath -Force } } catch {}
}

function Update-LicenseUi {
    $hwid = Get-Hwid
    if ($txtHwidShort) {
        $short = if ($hwid.Length -gt 20) { "$($hwid.Substring(0, 16))..." } else { $hwid }
        $txtHwidShort.Text = "HWID: $short"
    }
    $disabled = $false
    try { $disabled = [bool]$script:LicenseSystemDisabled } catch {}
    if ($disabled) {
        if ($txtLicenseStatus) { $txtLicenseStatus.Text = 'Provjera licence iskljucena (nema licenseApi u konfiguraciji).' }
        if ($txtLicenseExpiry) { $txtLicenseExpiry.Text = 'Launcher radi bez kljuca - tipicno za dev/test paket.' }
        if ($licenseBadge) { $licenseBadge.Visibility = 'Collapsed' }
        return
    }
    $cache = Get-LicenseCache
    if (-not $cache -or -not $cache.key) {
        if ($txtLicenseStatus) { $txtLicenseStatus.Text = 'Nema spremljene licence na ovom racunalu.' }
        if ($txtLicenseExpiry) { $txtLicenseExpiry.Text = 'Klikni Promijeni licencu za aktivaciju ili probu (3 dana).' }
        if ($licenseBadge) { $licenseBadge.Visibility = 'Collapsed' }
        return
    }
    if ($txtLicenseStatus) { $txtLicenseStatus.Text = 'Licenca aktivna na ovom racunalu (HWID vezana).' }
    $expLine = ''
    try {
        if ($cache.permanent -eq $true) { $expLine = 'Trajna licenca' }
        elseif ($cache.expiresAt) {
            $exp = [datetime]::Parse($cache.expiresAt).ToLocalTime()
            $expLine = "Vrijedi do: $($exp.ToString('dd.MM.yyyy HH:mm'))"
        }
    } catch {}
    if ($txtLicenseExpiry) { $txtLicenseExpiry.Text = $expLine }
    if ($licenseBadge) {
        $licenseBadge.Visibility = 'Visible'
        if ($txtLicenseBadge) { $txtLicenseBadge.Text = 'LICENCA OK' }
    }
}

# ============================================================
# LICENSE - REMOTE API (farmbuddy bot HTTP API)
# Endpoints expect Bearer token from sr_shared_config.json -> licenseApi.token
#   POST /api/license/activate     {key, hwid, gameUid?, playerName?}
#   POST /api/license/heartbeat    {key, hwid, gameUid?, playerName?}
#   POST /api/license/session-end  {key, hwid, sessionMinutes?, ...}
# ============================================================
function Get-LicenseApiConfig {
    $sources = @()
    try { if ($script:Config -and $script:Config.licenseApi) { $sources += $script:Config.licenseApi } } catch {}
    try { if ($script:SharedConfig -and $script:SharedConfig.licenseApi) { $sources += $script:SharedConfig.licenseApi } } catch {}
    # Fallback: read sr_shared_config.json next to the script
    try {
        $localPath = Join-Path $PSScriptRoot 'sr_shared_config.json'
        if (Test-Path $localPath) {
            $local = Get-Content $localPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($local.licenseApi) { $sources += $local.licenseApi }
        }
    } catch {}
    foreach ($api in $sources) {
        if ($api -and $api.url -and $api.token -and ($api.url -notmatch 'REPLACE-ME') -and ($api.token -notmatch 'REPLACE')) {
            return @{ url = ([string]$api.url).TrimEnd('/'); token = [string]$api.token }
        }
    }
    return $null
}

function Invoke-LicenseApi {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('activate','heartbeat','session-end')][string]$Path,
        [hashtable]$Body
    )
    $api = Get-LicenseApiConfig
    if (-not $api) {
        return @{ ok = $false; reason = 'License API nije konfiguriran (sr_shared_config.json -> licenseApi).'; status = 'config' }
    }
    try {
        $url = "$($api.url)/api/license/$Path"
        $json = ($Body | ConvertTo-Json -Compress -Depth 4)
        $headers = @{
            'Authorization' = "Bearer $($api.token)"
            'Content-Type'  = 'application/json'
        }
        $resp = Invoke-WebRequest -Uri $url -Method POST -Headers $headers -Body $json -UseBasicParsing -TimeoutSec 12
        $obj = $resp.Content | ConvertFrom-Json
        # Convert PSCustomObject to hashtable-like access (already works via dot notation but normalise ok flag)
        if ($null -eq $obj.ok) { return @{ ok = $false; reason = 'Neispravan odgovor servera.'; status = 'unknown' } }
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    } catch {
        $msg = $_.Exception.Message
        $statusCode = $null
        try { $statusCode = $_.Exception.Response.StatusCode.Value__ } catch {}
        # Try parse JSON body of error
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $errBody = $reader.ReadToEnd()
                $errObj = $errBody | ConvertFrom-Json -ErrorAction Stop
                $h = @{}
                foreach ($p in $errObj.PSObject.Properties) { $h[$p.Name] = $p.Value }
                if (-not $h.reason) { $h.reason = "HTTP $statusCode" }
                if ($null -eq $h.ok) { $h.ok = $false }
                return $h
            }
        } catch {}
        return @{ ok = $false; reason = "Greska kod spajanja na server: $msg"; status = 'network' }
    }
}

# ============================================================
# MOD API (server-authoritative mod sync via farmbuddy bot)
# Endpoints (Bearer token, reuses licenseApi config):
#   GET /api/mods/manifest?server=<id>             -> {ok, mods:[{name, sha256, size, version, updatedAt}]}
#   GET /api/mods/changes-since?server=<id>&since= -> {ok, changes:[{filename, type, detectedAt, ...}]}
# ============================================================
function Get-ActiveServerId {
    try {
        $srv = Get-ActiveServer
        if ($srv -and $srv.id) { return [string]$srv.id }
        if ($srv -and $srv.name) { return [string]$srv.name }
    } catch {}
    return ''
}

function Invoke-ModApi {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [hashtable]$Query
    )
    $api = Get-LicenseApiConfig
    if (-not $api) { return $null }
    try {
        $qs = ''
        if ($Query) {
            $pairs = @()
            foreach ($k in $Query.Keys) {
                $v = [string]$Query[$k]
                if ($null -ne $v -and $v -ne '') {
                    $pairs += "$([uri]::EscapeDataString($k))=$([uri]::EscapeDataString($v))"
                }
            }
            if ($pairs.Count -gt 0) { $qs = '?' + ($pairs -join '&') }
        }
        $url = "$($api.url)/api/mods/$Path$qs"
        $headers = @{ 'Authorization' = "Bearer $($api.token)" }
        $resp = Invoke-WebRequest -Uri $url -Method GET -Headers $headers -UseBasicParsing -TimeoutSec 15
        $obj = $resp.Content | ConvertFrom-Json
        if ($obj -and $obj.ok) { return $obj }
        return $null
    } catch {
        Write-Log "Mod API ($Path) greska: $($_.Exception.Message)"
        return $null
    }
}

function Get-ModManifestFromBot {
    $srvId = Get-ActiveServerId
    $q = @{}
    if ($srvId) { $q['server'] = $srvId }
    $resp = Invoke-ModApi -Path 'manifest' -Query $q
    if (-not $resp -or -not $resp.mods) { return $null }
    $results = @()
    foreach ($m in $resp.mods) {
        $results += [PSCustomObject]@{
            Name      = [string]$m.name
            Sha256    = if ($m.sha256) { ([string]$m.sha256).ToLower() } else { '' }
            Size      = if ($m.size) { [long]$m.size } else { 0 }
            Version   = [string]$m.version
            UpdatedAt = [string]$m.updatedAt
            Url       = $null
            Source    = 'bot'
        }
    }
    return $results
}

function Get-ModChangesSinceFromBot {
    param([string]$SinceIso)
    $srvId = Get-ActiveServerId
    $q = @{}
    if ($srvId) { $q['server'] = $srvId }
    if ($SinceIso) { $q['since'] = $SinceIso }
    $resp = Invoke-ModApi -Path 'changes-since' -Query $q
    if (-not $resp -or -not $resp.changes) { return @() }
    return @($resp.changes)
}

# ============================================================
# LOCAL MOD HASH CACHE
# SHA-256 of file contents; keyed by full path. Invalidated when
# size or LastWriteTime changes. Persists in sr_config.json.
# ============================================================
function Get-FileSha256 {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $bytes = $sha.ComputeHash($fs)
                return ([BitConverter]::ToString($bytes) -replace '-','').ToLower()
            } finally { $sha.Dispose() }
        } finally { $fs.Dispose() }
    } catch { return '' }
}

function Get-LocalModHash {
    param([System.IO.FileInfo]$File)
    if (-not $script:Config.modHashCache) {
        try { $script:Config | Add-Member -NotePropertyName modHashCache -NotePropertyValue (@{}) -Force } catch {}
    }
    $cache = $script:Config.modHashCache
    $key = $File.FullName
    $sigNew = "$($File.Length)|$($File.LastWriteTimeUtc.Ticks)"
    try {
        $entry = $cache.$key
        if ($entry -and $entry.sig -eq $sigNew -and $entry.sha) { return [string]$entry.sha }
    } catch {}
    $sha = Get-FileSha256 -Path $File.FullName
    if ($sha) {
        try {
            $newEntry = [PSCustomObject]@{ sig = $sigNew; sha = $sha }
            if ($cache -is [hashtable]) { $cache[$key] = $newEntry }
            else { $cache | Add-Member -NotePropertyName $key -NotePropertyValue $newEntry -Force }
        } catch {}
    }
    return $sha
}

# ============================================================
# LICENSE - VALIDATION (legacy compatible wrapper)
# Returns: @{ ok=bool; reason=string; entry=@{expiresAt;discordId}; needsBind=bool }
# ============================================================
function Test-License {
    param([string]$key, [string]$hwid, [object]$remote = $null)
    if (-not $key) { return @{ ok=$false; reason='Nema kljuca.' } }
    # Try to fetch player name from gameSettings.xml; fall back to env user.
    $playerName = $env:USERNAME
    try {
        $gs = Get-GameSettingsPath
        if ($gs -and (Test-Path $gs)) {
            $xml = Get-Content $gs -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($xml -match '<player[^>]*name="([^"]+)"') { $playerName = $matches[1] }
            elseif ($xml -match '<player>\s*<name>([^<]+)</name>') { $playerName = $matches[1] }
        }
    } catch {}
    $gameUid = "$($env:COMPUTERNAME)/$($env:USERNAME)"
    $r = Invoke-LicenseApi -Path 'activate' -Body @{
        key = $key; hwid = $hwid; gameUid = $gameUid; playerName = $playerName
    }
    if ($r.ok) {
        $expIso = $null
        try { if ($r.expiresAt) { $expIso = ([datetime]'1970-01-01T00:00:00Z').AddMilliseconds([double]$r.expiresAt).ToUniversalTime().ToString('o') } } catch {}
        return @{
            ok = $true
            entry = @{ expiresAt = $expIso; discordId = [string]$r.discordId; permanent = [bool]$r.permanent }
            needsBind = $false
        }
    }
    $reason = if ($r.reason) { $r.reason } else { "Greska ($($r.status))" }
    return @{ ok = $false; reason = $reason; status = $r.status }
}

# ============================================================
# LICENSE - HEARTBEAT + SESSION END (out-of-band)
# ============================================================
function Send-LicenseHeartbeat {
    param([string]$Key)
    if (-not $Key) { return }
    try {
        $hwid = Get-Hwid
        $playerName = $env:USERNAME
        try {
            $gs = Get-GameSettingsPath
            if ($gs -and (Test-Path $gs)) {
                $xml = Get-Content $gs -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if ($xml -match '<player[^>]*name="([^"]+)"') { $playerName = $matches[1] }
                elseif ($xml -match '<player>\s*<name>([^<]+)</name>') { $playerName = $matches[1] }
            }
        } catch {}
        Invoke-LicenseApi -Path 'heartbeat' -Body @{
            key = $Key; hwid = $hwid; gameUid = "$($env:COMPUTERNAME)/$($env:USERNAME)"; playerName = $playerName
        } | Out-Null
    } catch {}
}

function Start-LicenseSessionWatcher {
    <#
        Spawns a detached background PowerShell that survives launcher shutdown.
        Waits for FS25 process to exit, then POSTs /api/license/session-end with elapsed minutes.
    #>
    param([string]$Key)
    if (-not $Key) { return }
    $api = Get-LicenseApiConfig
    if (-not $api) { return }
    $hwid = Get-Hwid
    $gameUid = "$($env:COMPUTERNAME)/$($env:USERNAME)"
    $startIso = (Get-Date).ToUniversalTime().ToString('o')
    # Build child script body
    $body = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$key = '$Key'
`$hwid = '$hwid'
`$gameUid = '$gameUid'
`$url = '$($api.url)/api/license/session-end'
`$token = '$($api.token)'
`$start = [datetime]'$startIso'
# Wait up to 5 min for game to actually appear
`$attempts = 0
while (-not (Get-Process -Name 'FarmingSimulator2025*' -ErrorAction SilentlyContinue) -and `$attempts -lt 60) {
    Start-Sleep -Seconds 5
    `$attempts++
}
# Wait until game exits
while (Get-Process -Name 'FarmingSimulator2025*' -ErrorAction SilentlyContinue) {
    Start-Sleep -Seconds 30
}
`$minutes = [int]([Math]::Floor(((Get-Date) - `$start).TotalMinutes))
`$json = @{ key = `$key; hwid = `$hwid; gameUid = `$gameUid; sessionMinutes = `$minutes } | ConvertTo-Json -Compress
try {
    Invoke-WebRequest -Uri `$url -Method POST -Headers @{ Authorization = "Bearer `$token"; 'Content-Type' = 'application/json' } -Body `$json -UseBasicParsing -TimeoutSec 15 | Out-Null
} catch {}
"@
    try {
        $tmp = Join-Path $env:TEMP ("sr-session-" + [guid]::NewGuid().ToString('N') + ".ps1")
        Set-Content -Path $tmp -Value $body -Encoding UTF8
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$tmp) -WindowStyle Hidden | Out-Null
        Write-Log "License session watcher started (PID detached)."
    } catch {
        Write-Log "Failed to start license session watcher: $($_.Exception.Message)"
    }
}

function Find-GamePath {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Farming Simulator 2025\FarmingSimulator2025.exe",
        "$env:ProgramFiles\Farming Simulator 2025\FarmingSimulator2025.exe",
        "D:\Farming Simulator 2025\FarmingSimulator2025.exe",
        "D:\Games\Farming Simulator 2025\FarmingSimulator2025.exe",
        "E:\Farming Simulator 2025\FarmingSimulator2025.exe",
        "${env:ProgramFiles(x86)}\Steam\steamapps\common\Farming Simulator 25\FarmingSimulator2025.exe",
        "$env:ProgramFiles\Steam\steamapps\common\Farming Simulator 25\FarmingSimulator2025.exe",
        "D:\SteamLibrary\steamapps\common\Farming Simulator 25\FarmingSimulator2025.exe"
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    try {
        $reg = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*Farming Simulator 2025*" -or $_.DisplayName -like "*Farming Simulator 25*" } |
            Select-Object -First 1
        if ($reg -and $reg.InstallLocation) {
            $exe = Join-Path $reg.InstallLocation "FarmingSimulator2025.exe"
            if (Test-Path $exe) { return $exe }
        }
    } catch {}
    return ""
}

function Find-ModsPath {
    $path = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "My Games\FarmingSimulator2025\mods"
    if (Test-Path $path) { return $path }
    $parent = Split-Path $path
    if (Test-Path $parent) {
        New-Item -Path $path -ItemType Directory -Force | Out-Null
        return $path
    }
    return ""
}

function Find-SavegamesPath {
    $root = Get-FS25UserDataPath
    if ($root) { return $root }
    $path = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "My Games\FarmingSimulator2025"
    if (Test-Path $path) { return $path }
    return ""
}

function Find-DlcPath {
    param([string]$ExePath)
    if ($ExePath -and (Test-Path $ExePath)) {
        $data = Join-Path (Split-Path $ExePath -Parent) "data"
        if (Test-Path $data) { return $data }
    }
    return ""
}

function Get-GamePlatformFromPath {
    param([string]$ExePath)
    if (-not $ExePath) { return 'steam' }
    $dir = Split-Path $ExePath -Parent
    if ($ExePath -match '\\WindowsApps\\|\\Packages\\') { return 'xbox' }
    if (Test-Path (Join-Path $dir 'steam_api64.dll')) { return 'steam' }
    $parent = Split-Path $dir -Parent
    if ((Test-Path (Join-Path $dir 'GiantsLauncher.exe')) -or (Test-Path (Join-Path $parent 'GiantsLauncher.exe'))) {
        return 'giants'
    }
    if ($ExePath -match 'Steam\\steamapps') { return 'steam' }
    if ($ExePath -match 'Farming Simulator 2025') { return 'giants' }
    return 'steam'
}

function Find-XboxFS25ExePaths {
    $found = [System.Collections.Generic.List[string]]::new()
    try {
        $pkgRoot = Join-Path $env:LOCALAPPDATA 'Packages'
        if (Test-Path $pkgRoot) {
            Get-ChildItem $pkgRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'FarmingSimulator|GIANTS.*Farm' } |
                ForEach-Object {
                    $hits = Get-ChildItem $_.FullName -Recurse -Filter 'FarmingSimulator2025.exe' -ErrorAction SilentlyContinue
                    foreach ($h in $hits) { [void]$found.Add($h.FullName) }
                }
        }
    } catch {}
    try {
        $winApps = "${env:ProgramFiles}\WindowsApps"
        if (Test-Path $winApps) {
            Get-ChildItem $winApps -Recurse -Filter 'FarmingSimulator2025.exe' -ErrorAction SilentlyContinue |
                Select-Object -First 3 |
                ForEach-Object { [void]$found.Add($_.FullName) }
        }
    } catch {}
    return @($found | Select-Object -Unique)
}

function Find-GamePathForPlatform {
    param([string]$Platform = 'auto')
    $p = if ($Platform) { $Platform.ToLowerInvariant().Trim() } else { 'auto' }
    $steam = @(
        "${env:ProgramFiles(x86)}\Steam\steamapps\common\Farming Simulator 25\FarmingSimulator2025.exe",
        "$env:ProgramFiles\Steam\steamapps\common\Farming Simulator 25\FarmingSimulator2025.exe",
        "D:\SteamLibrary\steamapps\common\Farming Simulator 25\FarmingSimulator2025.exe",
        "E:\SteamLibrary\steamapps\common\Farming Simulator 25\FarmingSimulator2025.exe"
    )
    $giants = @(
        "${env:ProgramFiles(x86)}\Farming Simulator 2025\FarmingSimulator2025.exe",
        "$env:ProgramFiles\Farming Simulator 2025\FarmingSimulator2025.exe",
        "D:\Farming Simulator 2025\FarmingSimulator2025.exe",
        "D:\Games\Farming Simulator 2025\FarmingSimulator2025.exe",
        "E:\Farming Simulator 2025\FarmingSimulator2025.exe"
    )
    if ($p -eq 'auto') {
        foreach ($path in ($steam + $giants + @(Find-XboxFS25ExePaths))) {
            if ($path -and (Test-Path $path)) { return $path }
        }
        return Find-GamePath
    }
    $list = switch ($p) {
        'steam'  { $steam }
        'giants' { $giants }
        'xbox'   { @(Find-XboxFS25ExePaths) }
        default  { @() }
    }
    foreach ($path in $list) {
        if ($path -and (Test-Path $path)) { return $path }
    }
    if ($p -eq 'giants') {
        try {
            $reg = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like "*Farming Simulator 2025*" -or $_.DisplayName -like "*Farming Simulator 25*" } |
                Select-Object -First 1
            if ($reg -and $reg.InstallLocation) {
                $exe = Join-Path $reg.InstallLocation "FarmingSimulator2025.exe"
                if (Test-Path $exe) { return $exe }
            }
        } catch {}
    }
    return ""
}

function Get-SelectedGamePlatform {
    if ($platformSteam -and $platformSteam.IsChecked) { return 'steam' }
    if ($platformGiants -and $platformGiants.IsChecked) { return 'giants' }
    if ($platformXbox -and $platformXbox.IsChecked) { return 'xbox' }
    if ($script:Config.gamePlatform) { return [string]$script:Config.gamePlatform }
    return 'steam'
}

function Set-PlatformRadio {
    param([string]$Platform)
    $p = if ($Platform) { $Platform.ToLowerInvariant().Trim() } else { 'steam' }
    if ($platformSteam)  { $platformSteam.IsChecked  = ($p -eq 'steam') }
    if ($platformGiants) { $platformGiants.IsChecked = ($p -eq 'giants') }
    if ($platformXbox)   { $platformXbox.IsChecked   = ($p -eq 'xbox') }
}

function Get-GameLaunchArgs {
    $args = [System.Collections.Generic.List[string]]::new()
    $skipIntro = $true
    try {
        if ($null -ne $script:Config.launchSkipIntro) { $skipIntro = [bool]$script:Config.launchSkipIntro }
        elseif ($chkLaunchSkipIntro) { $skipIntro = [bool]$chkLaunchSkipIntro.IsChecked }
        else {
            $gs = Read-GameSettings
            $skipIntro = -not [bool]$gs.introScene
        }
    } catch {}
    if ($skipIntro) { [void]$args.Add('-skipStartVideos') }

    $cheats = $false
    try {
        if ($null -ne $script:Config.launchCheats) { $cheats = [bool]$script:Config.launchCheats }
        elseif ($chkLaunchCheats) { $cheats = [bool]$chkLaunchCheats.IsChecked }
    } catch {}
    if ($cheats) { [void]$args.Add('-cheats') }
    return @($args.ToArray())
}

function Start-FS25Game {
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [string[]]$ExtraArgs = @()
    )
    if (-not (Test-Path $ExePath)) {
        throw "Exe ne postoji: $ExePath"
    }
    $gameDir = Split-Path $ExePath -Parent
    $launchArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($a in (Get-GameLaunchArgs + $ExtraArgs)) {
        if ($a -and ($launchArgs -notcontains $a)) { [void]$launchArgs.Add($a) }
    }
    if ($launchArgs -contains '-skipStartVideos') {
        Write-GameSetting 'isIntroActive' 'false' | Out-Null
    }
    $argLine = if ($launchArgs.Count -gt 0) { $launchArgs -join ' ' } else { '(none)' }
    Write-Log "Start-FS25: $ExePath | cwd=$gameDir | args=$argLine | platform=$(Get-GamePlatformFromPath $ExePath)"
    $procArgs = @{
        FilePath         = $ExePath
        WorkingDirectory = $gameDir
    }
    if ($launchArgs.Count -gt 0) { $procArgs['ArgumentList'] = @($launchArgs.ToArray()) }
    Start-Process @procArgs
}

function Merge-UserGameSettings {
    param($Config)
    if (-not (Test-Path $script:UserSettingsPath)) { return $Config }
    try {
        $u = Get-Content $script:UserSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in @(
            'gamePlatform','gamePath','modsPath','savegamesPath','dlcPath',
            'launchCheats','launchSkipIntro','windowFullscreen','windowMaximize'
        )) {
            if ($u.PSObject.Properties.Name -contains $name -and $null -ne $u.$name -and "$($u.$name)" -ne '') {
                $Config | Add-Member -NotePropertyName $name -NotePropertyValue $u.$name -Force
            }
        }
    } catch {
        Write-Log "WARN user-settings.json: $($_.Exception.Message)"
    }
    return $Config
}

function Save-UserGameSettings {
    $dir = Split-Path $script:UserSettingsPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $obj = [ordered]@{
        gamePlatform    = if ($script:Config.gamePlatform) { [string]$script:Config.gamePlatform } else { 'steam' }
        gamePath        = if ($script:Config.gamePath) { [string]$script:Config.gamePath } else { '' }
        modsPath        = if ($script:Config.modsPath) { [string]$script:Config.modsPath } else { '' }
        savegamesPath   = if ($script:Config.savegamesPath) { [string]$script:Config.savegamesPath } else { '' }
        dlcPath         = if ($script:Config.dlcPath) { [string]$script:Config.dlcPath } else { '' }
        launchCheats    = [bool]$script:Config.launchCheats
        launchSkipIntro = [bool]$script:Config.launchSkipIntro
        windowFullscreen= [bool]$script:Config.windowFullscreen
        windowMaximize  = [bool]$script:Config.windowMaximize
        savedAt         = (Get-Date).ToUniversalTime().ToString('o')
    }
    ($obj | ConvertTo-Json -Depth 3) | Set-Content $script:UserSettingsPath -Encoding UTF8
}

function Sync-GameLaunchUiFromConfig {
    if ($txtGameExe -and $script:Config.gamePath) { $txtGameExe.Text = [string]$script:Config.gamePath }
    if ($txtModsPath -and $script:Config.modsPath) { $txtModsPath.Text = [string]$script:Config.modsPath }
    if ($txtSavegamesPath -and $script:Config.savegamesPath) { $txtSavegamesPath.Text = [string]$script:Config.savegamesPath }
    if ($txtDlcPath -and $script:Config.dlcPath) { $txtDlcPath.Text = [string]$script:Config.dlcPath }
    Set-PlatformRadio ([string]$script:Config.gamePlatform)
    if ($chkLaunchSkipIntro -and $null -ne $script:Config.launchSkipIntro) {
        $chkLaunchSkipIntro.IsChecked = [bool]$script:Config.launchSkipIntro
    }
    if ($chkLaunchCheats -and $null -ne $script:Config.launchCheats) {
        $chkLaunchCheats.IsChecked = [bool]$script:Config.launchCheats
    }
    if ($chkWindowMaximize -and $null -ne $script:Config.windowMaximize) {
        $chkWindowMaximize.IsChecked = [bool]$script:Config.windowMaximize
    }
}

function Apply-GameLaunchDefaults {
    if (-not $script:Config.gamePlatform -and $script:Config.gamePath) {
        $script:Config | Add-Member -NotePropertyName gamePlatform -NotePropertyValue (Get-GamePlatformFromPath $script:Config.gamePath) -Force
    }
    if (-not $script:Config.PSObject.Properties['launchSkipIntro']) {
        $script:Config | Add-Member -NotePropertyName launchSkipIntro -NotePropertyValue $true -Force
    }
    if (-not $script:Config.PSObject.Properties['launchCheats']) {
        $script:Config | Add-Member -NotePropertyName launchCheats -NotePropertyValue $false -Force
    }
    if (-not $script:Config.savegamesPath) {
        $sg = Find-SavegamesPath
        if ($sg) { $script:Config | Add-Member -NotePropertyName savegamesPath -NotePropertyValue $sg -Force }
    }
    if (-not $script:Config.dlcPath -and $script:Config.gamePath) {
        $dlc = Find-DlcPath -ExePath $script:Config.gamePath
        if ($dlc) { $script:Config | Add-Member -NotePropertyName dlcPath -NotePropertyValue $dlc -Force }
    }
}

function Set-WindowFullscreen {
    param([bool]$On)
    if ($On) {
        if (-not $script:IsFullscreen) {
            $script:WindowRestore = @{
                Left = $window.Left; Top = $window.Top
                Width = $window.Width; Height = $window.Height
                WindowState = $window.WindowState
            }
        }
        $window.WindowState = 'Maximized'
        $script:IsFullscreen = $true
        if ($btnFullscreen) { $btnFullscreen.ToolTip = 'Izlaz iz cijelog zaslona (F11)' }
    } else {
        $window.WindowState = 'Normal'
        if ($script:WindowRestore) {
            $window.Width  = $script:WindowRestore.Width
            $window.Height = $script:WindowRestore.Height
            $window.Left   = $script:WindowRestore.Left
            $window.Top    = $script:WindowRestore.Top
        }
        $script:IsFullscreen = $false
        if ($btnFullscreen) { $btnFullscreen.ToolTip = 'Cijeli zaslon (F11)' }
    }
    try {
        $script:Config | Add-Member -NotePropertyName windowFullscreen -NotePropertyValue $script:IsFullscreen -Force
        Save-Config
        Save-UserGameSettings
    } catch {}
}

function Toggle-WindowFullscreen {
    Set-WindowFullscreen (-not $script:IsFullscreen)
}

function Test-PlaceholderGameVersion {
    param([string]$Version)
    if (-not $Version) { return $true }
    $v = $Version.Trim()
    if ($v -eq '0.0.0.0') { return $true }
    # FS25 .exe PE resources often report Windows placeholder 10.0.0.0 - not the game patch.
    if ($v -match '^10\.\d+\.\d+\.\d+$') { return $true }
    return $false
}

function Get-VersionFromXmlText {
    param([string]$Content)
    if (-not $Content) { return '' }
    if ($Content -match '<version\s+[^>]*\bnumber="([^"]+)"') { return $Matches[1].Trim() }
    if ($Content -match '<version[^>]*>([^<]+)</version>') { return $Matches[1].Trim() }
    if ($Content -match '<version\s+value="([^"]+)"') { return $Matches[1].Trim() }
    if ($Content -match '<gameVersion>([^<]+)</gameVersion>') { return $Matches[1].Trim() }
    return ''
}

function Get-FS25GameVersion {
    param([string]$ExePath)
    if (-not $ExePath -or -not (Test-Path $ExePath)) { return '' }

    $gameDir = Split-Path $ExePath -Parent
    $versionXml = Join-Path $gameDir 'version.xml'
    if (Test-Path $versionXml) {
        try {
            $v = Get-VersionFromXmlText (Get-Content $versionXml -Raw -Encoding UTF8 -ErrorAction Stop)
            if ($v -and -not (Test-PlaceholderGameVersion $v)) {
                Write-Log "Verzija igre (version.xml): $v"
                return $v
            }
        } catch {
            Write-Log "WARN version.xml: $($_.Exception.Message)"
        }
    }

    $gsPath = Get-GameSettingsPath
    if (Test-Path $gsPath) {
        try {
            $gsContent = Get-Content $gsPath -Raw -Encoding UTF8 -ErrorAction Stop
            $v = Get-VersionFromXmlText $gsContent
            if ($v -and -not (Test-PlaceholderGameVersion $v)) {
                Write-Log "Verzija igre (gameSettings.xml): $v"
                return $v
            }
        } catch {
            Write-Log "WARN gameSettings verzija: $($_.Exception.Message)"
        }
    }

    try {
        $vi = (Get-Item $ExePath).VersionInfo
        foreach ($cand in @($vi.ProductVersion, $vi.FileVersion)) {
            if ($cand -and -not (Test-PlaceholderGameVersion $cand)) {
                $v = $cand.Trim()
                Write-Log "Verzija igre (exe VersionInfo): $v"
                return $v
            }
        }
    } catch {
        Write-Log "WARN exe VersionInfo: $($_.Exception.Message)"
    }

    Write-Log "WARN: Verzija igre nije odredena (ignoriram PE placeholder 10.0.0.0)."
    return ''
}

function Get-NormalizedModZipName {
    param([string]$Name)
    if (-not $Name) { return '' }
    $n = $Name.Trim()
    if ($n -notmatch '\.zip$') { $n = "$n.zip" }
    return $n.ToLowerInvariant()
}

# Kanonski kljuc za usporedbu: FS25_ prefiks, razmaci/crtice, sufiks verzije (v1.0.0.9).
function Get-CanonicalModKey {
    param([string]$Name)
    if (-not $Name) { return '' }
    $base = ($Name -replace '\.zip$', '').Trim()
    if ($base -match '(?i)^fs25[_\-\s]*(.*)$') { $base = $Matches[1].Trim() }
    $base = $base -replace '(?i)[\s_\-]+v?\d+(\.\d+){1,3}([\s_\-].*)?$', ''
    $base = $base -replace '(?i)[\s_\-]*(beta|alpha|rc\d*)$', ''
    return ($base -replace '[^a-z0-9]', '').ToLowerInvariant()
}

function Build-LocalModIndex {
    param([array]$LocalMods)
    $byNorm = @{}
    $byCanon = @{}
    foreach ($m in $LocalMods) {
        $nk = Get-NormalizedModZipName $m.Name
        if ($nk -and -not $byNorm.ContainsKey($nk)) { $byNorm[$nk] = $m }
        $ck = Get-CanonicalModKey $m.Name
        if ($ck -and -not $byCanon.ContainsKey($ck)) { $byCanon[$ck] = $m }
        if ($m.BaseName) {
            $bk = Get-CanonicalModKey $m.BaseName
            if ($bk -and -not $byCanon.ContainsKey($bk)) { $byCanon[$bk] = $m }
        }
    }
    return @{ ByNorm = $byNorm; ByCanon = $byCanon }
}

function Find-LocalModEntry {
    param(
        [hashtable]$LocalIndex,
        [string]$ServerName
    )
    if (-not $LocalIndex) { return $null }
    $bn = $LocalIndex.ByNorm
    $bc = $LocalIndex.ByCanon
    $key = Get-NormalizedModZipName $ServerName
    if ($key -and $bn -and $bn.ContainsKey($key)) { return $bn[$key] }
    $ck = Get-CanonicalModKey $ServerName
    if ($ck -and $bc -and $bc.ContainsKey($ck)) { return $bc[$ck] }
    return $null
}

function New-ModSyncItem {
    param(
        [string]$Status,
        [string]$DisplayName,
        [string]$ZipName,
        [string]$Local,
        [string]$Server,
        [string]$Size,
        [string]$StatusDetail = '',
        [string]$LocalSha = '',
        [string]$ServerSha = '',
        [string]$Version = '-',
        [string]$ModType = 'Other',
        [string]$LocalZipPath = ''
    )
    if (-not $ModType) { $ModType = 'Other' }
    $ModType = Normalize-ModTypeLabel $ModType
    $initial = if ($DisplayName) { ([string]$DisplayName).Substring(0, 1).ToUpper() } else { '?' }
    $tip = "$DisplayName`nStatus: $Status ($((Get-ModSyncStatusLabel $Status)))"
    if ($StatusDetail) { $tip += " - $StatusDetail" }
    $tip += "`nKategorija: $ModType`nZIP: $ZipName`nLokalno: $Local  |  Server: $Server  |  Velicina: $Size"
    if ($Version -and $Version -ne '-') { $tip += "`nVerzija: $Version" }
    if ($LocalSha -or $ServerSha) {
        if ($LocalSha) { $tip += "`nLokal SHA: $LocalSha" }
        if ($ServerSha) { $tip += "`nServer SHA: $ServerSha" }
    }
    return [PSCustomObject]@{
        Status        = $Status
        Name          = $DisplayName
        ZipName       = $ZipName
        Local         = $Local
        Server        = $Server
        Size          = $Size
        Version       = $Version
        Category      = $ModType
        ModType       = $ModType
        ModTypeSort   = (Get-ModTypeSortOrder $ModType)
        Initial       = $initial
        StatusDetail  = $StatusDetail
        ToolTipText   = $tip
        LocalZipPath  = $LocalZipPath
        ThumbSource   = $null
        HasThumb      = $false
        ThumbLoading  = $false
        FavoriteKey   = ''
        IsFavorite    = $false
        FavoriteStar  = [char]0x2606
    }
}

function Get-MissingSyncModItems {
    if (-not $script:AllModItems) { return @() }
    return @($script:AllModItems | Where-Object { $_.Status -eq 'FALI' -or $_.Status -eq 'ZASTARIO' })
}

function Resolve-ServerModEntry {
    param(
        [array]$ServerMods,
        [string]$DisplayOrZipName
    )
    if (-not $ServerMods -or -not $DisplayOrZipName) { return $null }
    $exact = $ServerMods | Where-Object {
        $_.Name -eq $DisplayOrZipName -or
        $_.Name -eq "$DisplayOrZipName.zip" -or
        ($_.Name -replace '\.zip$','') -eq $DisplayOrZipName
    } | Select-Object -First 1
    if ($exact) { return $exact }
    $ck = Get-CanonicalModKey $DisplayOrZipName
    if (-not $ck) { return $null }
    foreach ($sm in $ServerMods) {
        if ((Get-CanonicalModKey $sm.Name) -eq $ck) { return $sm }
    }
    return $null
}

# ============================================================
# SAVEGAME & MOD PROFILES (Phase 1 - pregled, bez opasnih editova)
# ============================================================
$script:ModProfilesPath = Join-Path $env:APPDATA "SR-Launcher\mod-profiles.json"
$script:ModFavoritesPath = Join-Path $env:APPDATA "SR-Launcher\mod-favorites.json"
$script:MultiplayerFoldersPath = Join-Path $env:APPDATA "SR-Launcher\multiplayer-folders.json"
$script:WalkthroughPath = Join-Path $env:APPDATA "SR-Launcher\walkthrough.json"

function Get-WalkthroughSettings {
    $default = [PSCustomObject]@{
        skipOnLaunch = $false
        completed    = $false
        lastStep     = 0
    }
    if (-not (Test-Path $script:WalkthroughPath)) { return $default }
    try {
        $raw = Get-Content $script:WalkthroughPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [PSCustomObject]@{
            skipOnLaunch = [bool]$raw.skipOnLaunch
            completed    = [bool]$raw.completed
            lastStep     = [int]$raw.lastStep
        }
    } catch { return $default }
}

function Save-WalkthroughSettings {
    param($Settings)
    $dir = Split-Path $script:WalkthroughPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    @{
        skipOnLaunch = [bool]$Settings.skipOnLaunch
        completed    = [bool]$Settings.completed
        lastStep     = [int]$Settings.lastStep
    } | ConvertTo-Json | Set-Content $script:WalkthroughPath -Encoding UTF8
}

function Get-ModSyncStatusLabel {
    param([string]$Status)
    switch ($Status) {
        'OK'        { return 'Sinkronizirano' }
        'FALI'      { return 'Nedostaje' }
        'ZASTARIO'  { return 'Azuriraj' }
        'Extra'     { return 'Lokalno extra' }
        'Lokalno'   { return 'Lokalno' }
        default     { return 'Mod' }
    }
}

function Get-ModTypeSortOrder {
    param([string]$ModType)
    switch ($ModType) {
        'Map'       { return 0 }
        'Vehicle'   { return 1 }
        'Placeable' { return 2 }
        'Script'    { return 3 }
        'Tool'      { return 4 }
        'Animal'    { return 5 }
        'Other'     { return 6 }
        default     { return 7 }
    }
}

function Normalize-ModTypeLabel {
    param([string]$Raw)
    if (-not $Raw) { return 'Other' }
    $t = $Raw.Trim().ToLowerInvariant()
    switch -Regex ($t) {
        '^(map|maps)$' { return 'Map' }
        '^(vehicle|vehicles|tractor|trailer|implement|tool|handtool|handtools)$' { return 'Vehicle' }
        '^(placeable|placeables|building|production)$' { return 'Placeable' }
        '^(script|scripts|specialization)$' { return 'Script' }
        '^(animal|animals)$' { return 'Animal' }
        default {
            if ($t -match 'vehicle|tractor|trailer|implement') { return 'Vehicle' }
            if ($t -match 'placeable|building') { return 'Placeable' }
            if ($t -match 'map') { return 'Map' }
            if ($t -match 'script') { return 'Script' }
            if ($t.Length -gt 1) { return ($t.Substring(0,1).ToUpper() + $t.Substring(1)) }
            return $t.ToUpper()
        }
    }
}

function Get-ModTypeFromModDescXml {
    param([string]$XmlText)
    if (-not $XmlText) { return 'Other' }
    try {
        [xml]$doc = $XmlText
        $root = $doc.modDesc
        if (-not $root) { return 'Other' }
        if ($root.map) { return 'Map' }
        if ($root.vehicle -or $root.vehicles) { return 'Vehicle' }
        if ($root.placeable -or $root.placeables) { return 'Placeable' }
        if ($root.animal -or $root.animals) { return 'Animal' }
        if ($root.script -or $root.scripts) { return 'Script' }
        if ($root.handTool -or $root.handTools) { return 'Tool' }
        foreach ($attr in @('type', 'modType', 'category')) {
            try {
                $val = $root.$attr
                if ($val) { return (Normalize-ModTypeLabel ([string]$val)) }
            } catch {}
        }
        $store = $root.storeItems
        if ($store) {
            $si = @($store.storeItem)[0]
            if ($si) {
                foreach ($attr in @('type', 'category')) {
                    try {
                        $val = $si.$attr
                        if ($val) { return (Normalize-ModTypeLabel ([string]$val)) }
                    } catch {}
                }
            }
        }
    } catch {}
    if ($XmlText -match '<map[\s>]' ) { return 'Map' }
    if ($XmlText -match '<vehicle[\s>]' ) { return 'Vehicle' }
    if ($XmlText -match '<placeable[\s>]' ) { return 'Placeable' }
    if ($XmlText -match '<script[\s>]' ) { return 'Script' }
    return 'Other'
}

function Get-ModIconFilenameFromModDescXml {
    param([string]$XmlText)
    if (-not $XmlText) { return $null }
    foreach ($pat in @(
        '<iconFilename>\s*([^<]+)\s*</iconFilename>',
        'iconFilename\s*=\s*"([^"]+)"',
        '<storeIcon>\s*([^<]+)\s*</storeIcon>',
        'storeIcon\s*=\s*"([^"]+)"'
    )) {
        if ($XmlText -match $pat) { return $Matches[1].Trim() }
    }
    return $null
}

function Get-ModDescEntryFromZip {
    param([System.IO.Compression.ZipArchive]$Zip)
    $best = $null
    foreach ($e in $Zip.Entries) {
        if ($e.FullName -notmatch '(?i)modDesc\.xml$') { continue }
        if (-not $best) { $best = $e; continue }
        $depth = ($e.FullName -split '/').Count
        $bestDepth = ($best.FullName -split '/').Count
        if ($depth -lt $bestDepth) { $best = $e }
    }
    return $best
}

function Find-ModIconZipEntry {
    param(
        [System.IO.Compression.ZipArchive]$Zip,
        [string]$IconFilename,
        [string]$ModDescPath
    )
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($IconFilename) {
        $candidates.Add($IconFilename)
        $candidates.Add((Split-Path $IconFilename -Leaf))
    }
    $candidates.AddRange(@('icon.png', 'store_icon.png', 'icon.dds', 'store_icon.dds', 'icon.jpg'))
    $modDir = ''
    if ($ModDescPath -and $ModDescPath -match '[\\/]') {
        $modDir = ($ModDescPath -replace '(?i)modDesc\.xml$', '').TrimEnd('\', '/')
    }
    foreach ($name in $candidates) {
        if (-not $name) { continue }
        $leaf = ($name -replace '\\', '/')
        foreach ($e in $Zip.Entries) {
            $fn = ($e.FullName -replace '\\', '/').TrimStart('/')
            if ($fn -ieq $leaf) { return $e }
            if ($modDir -and ($fn -ieq "$modDir/$leaf")) { return $e }
            if ($fn -ieq (Split-Path $leaf -Leaf)) { return $e }
        }
    }
    foreach ($e in $Zip.Entries) {
        $fn = ($e.FullName -replace '\\', '/')
        if ($fn -imatch '(^|/)(store_)?icon\.(png|jpg|jpeg|dds)$') { return $e }
    }
    return $null
}

function Get-ModThumbnailCachePath {
    param([string]$ZipPath)
    if (-not $ZipPath -or -not (Test-Path $ZipPath)) { return $null }
    try {
        $fi = Get-Item $ZipPath -ErrorAction Stop
        $key = Get-SHA256 "$($fi.FullName)|$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
        return (Join-Path $script:ModThumbsPath "$key.png")
    } catch { return $null }
}

function Convert-DdsBytesToPngFile {
    param([byte[]]$Bytes, [string]$OutPath)
    if (-not $Bytes -or $Bytes.Length -lt 128) { return $false }
    try {
        if ([Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -ne 'DDS ') { return $false }
        $h = [BitConverter]::ToInt32($Bytes, 12)
        $w = [BitConverter]::ToInt32($Bytes, 16)
        if ($w -le 0 -or $h -le 0 -or $w -gt 2048 -or $h -gt 2048) { return $false }
        $pf = [BitConverter]::ToUInt32($Bytes, 84)
        $dataOff = 128
        if ($Bytes.Length -lt ($dataOff + 8)) { return $false }
        $rgba = New-Object byte[] ($w * $h * 4)
        if ($pf -eq 0x31545844) {
            # DXT1
            $blocksX = [Math]::Max(1, [int][Math]::Ceiling($w / 4.0))
            $blocksY = [Math]::Max(1, [int][Math]::Ceiling($h / 4.0))
            $pos = $dataOff
            for ($by = 0; $by -lt $blocksY; $by++) {
                for ($bx = 0; $bx -lt $blocksX; $bx++) {
                    if ($pos + 8 -gt $Bytes.Length) { return $false }
                    $c0 = [BitConverter]::ToUInt16($Bytes, $pos); $pos += 2
                    $c1 = [BitConverter]::ToUInt16($Bytes, $pos); $pos += 2
                    $bits = [BitConverter]::ToUInt32($Bytes, $pos); $pos += 4
                    $pal = New-Object uint32[] 4
                    $pal[0] = Convert-Rgb565ToArgb $c0 255
                    $pal[1] = Convert-Rgb565ToArgb $c1 255
                    $pal[2] = Convert-Rgb565ToArgb ([uint16](($c0 + $c1) / 2)) 255
                    $pal[3] = 0
                    if ($c0 -le $c1) { $pal[2] = Convert-Rgb565ToArgb ([uint16](($c0 + $c1) / 2)) 255; $pal[3] = 0 }
                    for ($py = 0; $py -lt 4; $py++) {
                        for ($px = 0; $px -lt 4; $px++) {
                            $x = $bx * 4 + $px; $y = $by * 4 + $py
                            if ($x -ge $w -or $y -ge $h) { continue }
                            $idx = [int](($bits -shr (2 * ($py * 4 + $px))) -band 3)
                            $c = $pal[$idx]
                            $o = ($y * $w + $x) * 4
                            $rgba[$o]     = [byte]($c -band 0xFF)
                            $rgba[$o + 1] = [byte](($c -shr 8) -band 0xFF)
                            $rgba[$o + 2] = [byte](($c -shr 16) -band 0xFF)
                            $rgba[$o + 3] = if ($idx -eq 3 -and $c0 -gt $c1) { 0 } else { 255 }
                        }
                    }
                }
            }
        } elseif ($pf -eq 0x20534444) {
            # Uncompressed 32-bit (rare)
            $need = $dataOff + ($w * $h * 4)
            if ($Bytes.Length -lt $need) { return $false }
            [Array]::Copy($Bytes, $dataOff, $rgba, 0, $rgba.Length)
        } else {
            return $false
        }
        Save-RgbaBitmapAsPng -Rgba $rgba -Width $w -Height $h -OutPath $OutPath
        return $true
    } catch { return $false }
}

function Convert-Rgb565ToArgb {
    param([uint16]$C, [byte]$A = 255)
    $r = (($C -shr 11) -band 0x1F) * 255 / 31
    $g = (($C -shr 5) -band 0x3F) * 255 / 63
    $b = ($C -band 0x1F) * 255 / 31
    return [uint32]($b -bor ($g -shl 8) -bor ($r -shl 16) -bor ($A -shl 24))
}

function Save-RgbaBitmapAsPng {
    param([byte[]]$Rgba, [int]$Width, [int]$Height, [string]$OutPath)
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $bmp = New-Object System.Drawing.Bitmap $Width, $Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bd = $bmp.LockBits([System.Drawing.Rectangle]::FromLTRB(0, 0, $Width, $Height),
        [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        [System.Runtime.InteropServices.Marshal]::Copy($Rgba, 0, $bd.Scan0, $Rgba.Length)
    } finally {
        $bmp.UnlockBits($bd)
    }
    $dir = Split-Path $OutPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

function Export-ModIconEntryToPng {
    param(
        [System.IO.Compression.ZipArchiveEntry]$Entry,
        [string]$OutPath
    )
    if (-not $Entry) { return $false }
    $ms = New-Object System.IO.MemoryStream
    try {
        $s = $Entry.Open()
        try { $s.CopyTo($ms) } finally { $s.Dispose() }
        $bytes = $ms.ToArray()
    } finally { $ms.Dispose() }
    $leaf = Split-Path $Entry.FullName -Leaf
    if ($leaf -match '\.(png|jpg|jpeg)$') {
        $dir = Split-Path $OutPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllBytes($OutPath, $bytes)
        return $true
    }
    if ($leaf -match '\.dds$') {
        return (Convert-DdsBytesToPngFile -Bytes $bytes -OutPath $OutPath)
    }
    return $false
}

function Get-ModMetaFromZip {
    param([string]$ZipPath)
    $result = [PSCustomObject]@{
        ModType  = 'Other'
        Version  = ''
        IconFile = ''
    }
    if (-not $ZipPath -or -not (Test-Path $ZipPath)) { return $result }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            $desc = Get-ModDescEntryFromZip -Zip $zip
            if (-not $desc) { return $result }
            $sr = New-Object System.IO.StreamReader($desc.Open())
            try { $xml = $sr.ReadToEnd() } finally { $sr.Dispose() }
            $result.ModType = Get-ModTypeFromModDescXml -XmlText $xml
            if ($xml -match '<version>\s*([^<]+)\s*</version>') { $result.Version = $Matches[1].Trim() }
            elseif ($xml -match 'version\s*=\s*"([^"]+)"') { $result.Version = $Matches[1].Trim() }
            $iconName = Get-ModIconFilenameFromModDescXml -XmlText $xml
            $iconEntry = Find-ModIconZipEntry -Zip $zip -IconFilename $iconName -ModDescPath $desc.FullName
            if ($iconEntry) { $result.IconFile = $iconEntry.FullName }
        } finally {
            $zip.Dispose()
        }
    } catch {}
    return $result
}

function Get-ModThumbnailFromZip {
    param([string]$ZipPath)
    $cache = Get-ModThumbnailCachePath -ZipPath $ZipPath
    if (-not $cache) { return $null }
    if (Test-Path $cache) { return $cache }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            $desc = Get-ModDescEntryFromZip -Zip $zip
            if (-not $desc) { return $null }
            $sr = New-Object System.IO.StreamReader($desc.Open())
            try { $xml = $sr.ReadToEnd() } finally { $sr.Dispose() }
            $iconName = Get-ModIconFilenameFromModDescXml -XmlText $xml
            $iconEntry = Find-ModIconZipEntry -Zip $zip -IconFilename $iconName -ModDescPath $desc.FullName
            if (-not $iconEntry) { return $null }
            if (Export-ModIconEntryToPng -Entry $iconEntry -OutPath $cache) { return $cache }
        } finally {
            $zip.Dispose()
        }
    } catch {}
    return $null
}

function New-ModBitmapImage {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    try {
        $img = New-Object System.Windows.Media.Imaging.BitmapImage
        $img.BeginInit()
        $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $img.UriSource = [Uri]((Resolve-Path $Path).Path)
        $img.EndInit()
        $img.Freeze()
        return $img
    } catch { return $null }
}

function Start-ModThumbnailLoads {
    param([array]$Items)
    if (-not $Items -or $Items.Count -eq 0) { return }
    if (-not $window) { return }
    foreach ($item in @($Items)) {
        if ($item.HasThumb -or $item.ThumbLoading) { continue }
        if (-not $item.LocalZipPath -or -not (Test-Path $item.LocalZipPath)) { continue }
        $cached = Get-ModThumbnailCachePath -ZipPath $item.LocalZipPath
        if ($cached -and (Test-Path $cached)) {
            $item.ThumbSource = New-ModBitmapImage $cached
            $item.HasThumb = ($null -ne $item.ThumbSource)
            continue
        }
        $item.ThumbLoading = $true
        $zipPath = [string]$item.LocalZipPath
        $itRef = $item
        $cb = [System.Threading.WaitCallback]{
            param($state)
            $path = $null
            try { $path = Get-ModThumbnailFromZip -ZipPath $state.Zip } catch {}
            $state.Window.Dispatcher.BeginInvoke([Action]{
                try {
                    if ($path -and (Test-Path $path)) {
                        $img = New-ModBitmapImage $path
                        if ($img) {
                            $state.Item.ThumbSource = $img
                            $state.Item.HasThumb = $true
                        }
                    }
                } catch {}
                finally { $state.Item.ThumbLoading = $false }
            }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
        }
        [void][System.Threading.ThreadPool]::QueueUserWorkItem($cb, @{
            Zip    = $zipPath
            Item   = $itRef
            Window = $window
        })
    }
}

function Get-FS25UserDataPath {
    $candidates = @(
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) "My Games\FarmingSimulator2025"),
        (Join-Path $env:USERPROFILE "Documents\My Games\FarmingSimulator2025"),
        (Join-Path $env:USERPROFILE "OneDrive\Documents\My Games\FarmingSimulator2025")
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Get-SavegameSlotInfo {
    param([string]$SlotDir, [int]$SlotNumber)
    $info = [PSCustomObject]@{
        Slot       = $SlotNumber
        Folder     = $SlotDir
        Name       = "savegame$SlotNumber"
        MapTitle   = ""
        Money      = ""
        PlayTime   = ""
        LastWrite  = ""
        HasCareer  = $false
        SizeMb     = 0.0
    }
    try {
        $dirItem = Get-Item $SlotDir -ErrorAction SilentlyContinue
        if ($dirItem) { $info.LastWrite = $dirItem.LastWriteTime.ToString("dd.MM.yyyy HH:mm") }
        $total = (Get-ChildItem $SlotDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($total) { $info.SizeMb = [Math]::Round($total / 1MB, 1) }
    } catch {}
    $careerPath = Join-Path $SlotDir "careerSavegame.xml"
    if (Test-Path $careerPath) {
        $info.HasCareer = $true
        try {
            $xml = Get-Content $careerPath -Raw -Encoding UTF8 -ErrorAction Stop
            if ($xml -match '<savegameName>([^<]*)</savegameName>') { $info.Name = $Matches[1].Trim() }
            if ($xml -match 'savegameName="([^"]*)"') { $info.Name = $Matches[1].Trim() }
            if ($xml -match '<mapTitle>([^<]*)</mapTitle>') { $info.MapTitle = $Matches[1].Trim() }
            if ($xml -match 'mapTitle="([^"]*)"') { $info.MapTitle = $Matches[1].Trim() }
            if ($xml -match '<money>([^<]*)</money>') { $info.Money = $Matches[1].Trim() }
            if ($xml -match '<playTime>([^<]*)</playTime>') { $info.PlayTime = $Matches[1].Trim() }
        } catch {}
    }
    if (-not $info.MapTitle) {
        foreach ($thumb in @('mapPreview.png', 'overview.png')) {
            if (Test-Path (Join-Path $SlotDir $thumb)) { $info.MapTitle = "(mapa)"; break }
        }
    }
    return $info
}

function Get-FS25SavegameList {
    $root = Get-FS25UserDataPath
    if (-not $root) { return @() }
    $list = New-Object System.Collections.ArrayList
    1..20 | ForEach-Object {
        $slotDir = Join-Path $root "savegame$_"
        if (Test-Path $slotDir) {
            [void]$list.Add((Get-SavegameSlotInfo -SlotDir $slotDir -SlotNumber $_))
        }
    }
    return @($list.ToArray())
}

function Get-ModProfilesStore {
    $default = [PSCustomObject]@{
        version         = 1
        activeProfileId = ""
        profiles        = @{}
    }
    if (-not (Test-Path $script:ModProfilesPath)) { return $default }
    try {
        $raw = Get-Content $script:ModProfilesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $raw.profiles) { $raw | Add-Member -NotePropertyName profiles -NotePropertyValue (@{}) -Force }
        return $raw
    } catch {
        return $default
    }
}

function Save-ModProfilesStore {
    param($Store)
    $dir = Split-Path $script:ModProfilesPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Store | ConvertTo-Json -Depth 6 | Set-Content $script:ModProfilesPath -Encoding UTF8
}

function Get-ModFavoritesStore {
    $default = [PSCustomObject]@{ version = 1; favorites = @() }
    if (-not (Test-Path $script:ModFavoritesPath)) { return $default }
    try {
        $raw = Get-Content $script:ModFavoritesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $list = @()
        if ($raw.favorites) { $list = @($raw.favorites | ForEach-Object { [string]$_ }) }
        return [PSCustomObject]@{ version = 1; favorites = $list }
    } catch { return $default }
}

function Save-ModFavoritesStore {
    param($Store)
    $dir = Split-Path $script:ModFavoritesPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Store | ConvertTo-Json -Depth 4 | Set-Content $script:ModFavoritesPath -Encoding UTF8
}

function Get-ModFavoriteKey {
    param($Item)
    if (-not $Item) { return '' }
    if ($Item.ZipName) { return (Get-CanonicalModKey ($Item.ZipName -replace '\.zip$','')) }
    return (Get-CanonicalModKey $Item.Name)
}

function Sync-ModFavoriteFlags {
    $fav = Get-ModFavoritesStore
    $set = @{}
    foreach ($k in @($fav.favorites)) {
        if ($k) { $set[[string]$k] = $true }
    }
    foreach ($item in @($script:AllModItems)) {
        $key = Get-ModFavoriteKey $item
        $isFav = $key -and $set.ContainsKey($key)
        $item | Add-Member -NotePropertyName FavoriteKey -NotePropertyValue $key -Force
        $item | Add-Member -NotePropertyName IsFavorite -NotePropertyValue $isFav -Force
        $item | Add-Member -NotePropertyName FavoriteStar -NotePropertyValue $(if ($isFav) { [char]0x2605 } else { [char]0x2606 }) -Force
    }
}

function Set-ModFavorite {
    param(
        $Item,
        [bool]$Favorite
    )
    $key = Get-ModFavoriteKey $Item
    if (-not $key) { return }
    $store = Get-ModFavoritesStore
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($k in @($store.favorites)) {
        if ($k -and $k -ne $key) { [void]$list.Add([string]$k) }
    }
    if ($Favorite) { [void]$list.Add($key) }
    Save-ModFavoritesStore ([PSCustomObject]@{ version = 1; favorites = @($list.ToArray()) })
    Sync-ModFavoriteFlags
}

function Get-ModCategoryHrLabel {
    param([string]$Key)
    switch ($Key) {
        'All'         { return 'Svi modovi' }
        'Favourites'  { return 'Favoriti' }
        'Vehicle'     { return 'Vozila' }
        'Placeable'   { return 'Objekti' }
        'Map'         { return 'Mape' }
        'Script'      { return 'Skripte' }
        'Animal'      { return 'Zivotinje' }
        default       { return 'Ostalo' }
    }
}

function Get-ModCategoryCounts {
    $counts = @{
        All          = @($script:AllModItems).Count
        Favourites   = 0
        Vehicle      = 0
        Placeable    = 0
        Map          = 0
        Script       = 0
        Animal       = 0
        Other        = 0
    }
    foreach ($item in @($script:AllModItems)) {
        if ($item.IsFavorite) { $counts.Favourites++ }
        $mt = if ($item.ModType) { $item.ModType } else { 'Other' }
        if (-not $counts.ContainsKey($mt)) { $counts.Other++ } else { $counts[$mt]++ }
    }
    return $counts
}

function Update-ModShowCombo {
    if (-not $cmbModShow) { return }
    $prevKey = 'All'
    try {
        if ($cmbModShow.SelectedItem -and $cmbModShow.SelectedItem.Key) {
            $prevKey = [string]$cmbModShow.SelectedItem.Key
        }
    } catch {}
    Sync-ModFavoriteFlags
    $counts = Get-ModCategoryCounts
    $keys = @('All', 'Favourites', 'Vehicle', 'Placeable', 'Map', 'Script', 'Animal', 'Other')
    $items = New-Object System.Collections.ArrayList
    foreach ($k in $keys) {
        $n = [int]$counts[$k]
        [void]$items.Add([PSCustomObject]@{
            Key   = $k
            Label = "$(Get-ModCategoryHrLabel $k) ($n)"
        })
    }
    $script:ModShowComboUpdating = $true
    try {
        $cmbModShow.ItemsSource = @($items.ToArray())
        $sel = $items | Where-Object { $_.Key -eq $prevKey } | Select-Object -First 1
        if (-not $sel) { $sel = $items[0] }
        $cmbModShow.SelectedItem = $sel
    } finally {
        $script:ModShowComboUpdating = $false
    }
}

function Get-ServerModProfileId {
    $server = Get-ActiveServer
    $slug = ($server.name -replace '[^a-zA-Z0-9\-]', '-').ToLower().Trim('-')
    if (-not $slug) { $slug = "server$($script:Config.activeServer)" }
    return "server:$slug"
}

function Ensure-ServerModProfile {
    $store = Get-ModProfilesStore
    $id = Get-ServerModProfileId
    $server = Get-ActiveServer
    $profiles = @{}
    if ($store.profiles) {
        $store.profiles.PSObject.Properties | ForEach-Object { $profiles[$_.Name] = $_.Value }
    }
    if (-not $profiles.ContainsKey($id)) {
        $profiles[$id] = [PSCustomObject]@{
            id          = $id
            label       = $server.name
            type        = "server"
            serverIndex = [int]$script:Config.activeServer
            modsPath    = if ($script:Config.modsPath) { $script:Config.modsPath } else { "" }
            launchArgs  = @()
            notes       = "Auto profil za SR server"
            updatedAt   = (Get-Date).ToString("o")
        }
        $store.profiles = $profiles
        if (-not $store.activeProfileId) { $store.activeProfileId = $id }
        Save-ModProfilesStore $store
    }
    return $store
}

function Get-ModProfileList {
    $store = Ensure-ServerModProfile
    $items = New-Object System.Collections.ArrayList
    if ($store.profiles) {
        $store.profiles.PSObject.Properties | ForEach-Object {
            $p = $_.Value
            $label = if ($p.label) { $p.label } else { $_.Name }
            $type = if ($p.type) { $p.type } else { "custom" }
            [void]$items.Add([PSCustomObject]@{
                Id    = $_.Name
                Label = $label
                Type  = $type
                Mods  = if ($p.modsPath) { $p.modsPath } else { "" }
            })
        }
    }
    return @($items.ToArray())
}

function Refresh-IgraPage {
    if (-not $txtIgraSavePath -or -not $lstSavegames) { return }
    $root = Get-FS25UserDataPath
    if ($root) {
        $txtIgraSavePath.Text = $root
        $txtIgraSavePath.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#aaa")
    } else {
        $txtIgraSavePath.Text = 'FS25 user data nije pronaden (My Games\FarmingSimulator2025)'
        $txtIgraSavePath.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#E5484D")
    }
    $lstSavegames.ItemsSource = $null
    $saves = Get-FS25SavegameList
    if ($saves.Count -gt 0) {
        $lstSavegames.ItemsSource = $saves
        $txtIgraSaveHint.Text = ('{0} slotova - samo pregled (Phase 1). Uredi save tek nakon backupa (kasnije).' -f $saves.Count)
    } else {
        $txtIgraSaveHint.Text = "Nema savegame foldera. Spremi igru u FS25 pa osvjezi."
    }
    if ($cmbModProfiles) {
        $profiles = Get-ModProfileList
        $cmbModProfiles.ItemsSource = $profiles
        $cmbModProfiles.DisplayMemberPath = "Label"
        $store = Get-ModProfilesStore
        if ($store.activeProfileId) {
            $sel = $profiles | Where-Object { $_.Id -eq $store.activeProfileId } | Select-Object -First 1
            if ($sel) { $cmbModProfiles.SelectedItem = $sel }
        }
        if (-not $cmbModProfiles.SelectedItem -and $profiles.Count -gt 0) {
            $cmbModProfiles.SelectedIndex = 0
        }
    }
}

# ============================================================
# MULTIPLAYER FOLDERS (Phase 1 - JSON, UI skeleton, join path)
# ============================================================
function Get-MultiplayerFoldersStore {
    $default = [PSCustomObject]@{
        version          = 1
        mainLibraryPath  = ""
        selectedByServer = @{}
        folders          = @{}
    }
    if (-not (Test-Path $script:MultiplayerFoldersPath)) { return $default }
    try {
        $raw = Get-Content $script:MultiplayerFoldersPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $raw.folders) { $raw | Add-Member -NotePropertyName folders -NotePropertyValue (@{}) -Force }
        if (-not $raw.selectedByServer) { $raw | Add-Member -NotePropertyName selectedByServer -NotePropertyValue (@{}) -Force }
        return $raw
    } catch { return $default }
}

function Save-MultiplayerFoldersStore {
    param($Store)
    $dir = Split-Path $script:MultiplayerFoldersPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Store | ConvertTo-Json -Depth 8 | Set-Content $script:MultiplayerFoldersPath -Encoding UTF8
}

function Get-ServerMpFolderId {
    return Get-ServerModProfileId
}

function Get-MpFolderRecord {
    param([string]$FolderId, $Store)
    if (-not $Store) { $Store = Get-MultiplayerFoldersStore }
    if (-not $FolderId -or -not $Store.folders) { return $null }
    $rec = $null
    $Store.folders.PSObject.Properties | ForEach-Object {
        if ($_.Name -eq $FolderId) { $rec = $_.Value }
    }
    return $rec
}

function Ensure-ServerMpFolder {
    $store = Get-MultiplayerFoldersStore
    $id = Get-ServerMpFolderId
    $server = Get-ActiveServer
    $folders = @{}
    if ($store.folders) {
        $store.folders.PSObject.Properties | ForEach-Object { $folders[$_.Name] = $_.Value }
    }
    $main = if ($script:Config.modsPath) { [string]$script:Config.modsPath } else { "" }
    if (-not $store.mainLibraryPath -and $main) { $store.mainLibraryPath = $main }
    if (-not $folders.ContainsKey($id)) {
        $parent = if ($main) { Split-Path $main -Parent } else { Join-Path $env:USERPROFILE "Documents\My Games\FarmingSimulator2025" }
        $slug = ($server.name -replace '[^a-zA-Z0-9]', '') 
        if (-not $slug) { $slug = "Server$($script:Config.activeServer)" }
        $path = Join-Path $parent "SR-Mods-$slug"
        $folders[$id] = [PSCustomObject]@{
            id             = $id
            label          = $server.name
            serverId       = $id
            path           = $path
            isFavorite     = $false
            useMainLibrary = $false
            notes          = "Auto folder za multiplayer server"
            updatedAt      = (Get-Date).ToString("o")
        }
        $store.folders = $folders
        $sel = @{}
        if ($store.selectedByServer) {
            $store.selectedByServer.PSObject.Properties | ForEach-Object { $sel[$_.Name] = $_.Value }
        }
        if (-not $sel.ContainsKey($id)) { $sel[$id] = $id }
        $store.selectedByServer = $sel
        Save-MultiplayerFoldersStore $store
    }
    return $store
}

function Get-MpFolderList {
    $store = Ensure-ServerMpFolder
    $items = New-Object System.Collections.ArrayList
    if ($store.folders) {
        $store.folders.PSObject.Properties | ForEach-Object {
            $f = $_.Value
            $label = if ($f.label) { $f.label } else { $_.Name }
            $star = if ($f.isFavorite) { [char]0x2605 } else { [char]0x2606 }
            $path = if ($f.useMainLibrary) { $store.mainLibraryPath } elseif ($f.path) { $f.path } else { "" }
            [void]$items.Add([PSCustomObject]@{
                Id             = $_.Name
                Label          = $label
                Path           = [string]$path
                IsFavorite     = [bool]$f.isFavorite
                FavoriteStar   = $star
                UseMainLibrary = [bool]$f.useMainLibrary
                ServerId       = if ($f.serverId) { $f.serverId } else { "" }
            })
        }
    }
    return @($items.ToArray())
}

function Get-ActiveMultiplayerFolder {
    $store = Ensure-ServerMpFolder
    $serverId = Get-ServerMpFolderId
    $folderId = $serverId
    if ($store.selectedByServer) {
        $store.selectedByServer.PSObject.Properties | ForEach-Object {
            if ($_.Name -eq $serverId -and $_.Value) { $folderId = [string]$_.Value }
        }
    }
    $rec = Get-MpFolderRecord -FolderId $folderId -Store $store
    if (-not $rec) { $rec = Get-MpFolderRecord -FolderId $serverId -Store $store }
    if (-not $rec) { return $null }
    if ([bool]$rec.useMainLibrary) {
        return [PSCustomObject]@{
            Id    = $rec.id
            Label = if ($rec.label) { $rec.label } else { 'Glavna biblioteka' }
            Path  = if ($store.mainLibraryPath) { $store.mainLibraryPath } else { $script:Config.modsPath }
            UseMainLibrary = $true
        }
    }
    return [PSCustomObject]@{
        Id    = $rec.id
        Label = if ($rec.label) { $rec.label } else { $rec.id }
        Path  = if ($rec.path) { [string]$rec.path } else { "" }
        UseMainLibrary = $false
    }
}

function Get-EffectiveModsPath {
    $active = Get-ActiveMultiplayerFolder
    if ($active -and $active.Path) {
        $p = [string]$active.Path.Trim()
        if ($p) { return $p }
    }
    return $script:Config.modsPath
}

function Set-ActiveMpFolderForServer {
    param([string]$FolderId)
    if (-not $FolderId) { return }
    $store = Ensure-ServerMpFolder
    $serverId = Get-ServerMpFolderId
    $sel = @{}
    if ($store.selectedByServer) {
        $store.selectedByServer.PSObject.Properties | ForEach-Object { $sel[$_.Name] = $_.Value }
    }
    $sel[$serverId] = $FolderId
    $store.selectedByServer = $sel
    Save-MultiplayerFoldersStore $store
    Write-Log "Multiplayer folder: $FolderId za server $serverId"
}

function Set-MpFolderFavorite {
    param([string]$FolderId, [bool]$Favorite)
    if (-not $FolderId) { return }
    $store = Get-MultiplayerFoldersStore
    $rec = Get-MpFolderRecord -FolderId $FolderId -Store $store
    if (-not $rec) { return }
    $rec.isFavorite = $Favorite
    $rec.updatedAt = (Get-Date).ToString("o")
    Save-MultiplayerFoldersStore $store
}

function Reset-MpFolderToMainLibrary {
    $store = Ensure-ServerMpFolder
    $serverId = Get-ServerMpFolderId
    $rec = Get-MpFolderRecord -FolderId $serverId -Store $store
    if ($rec) {
        $rec.useMainLibrary = $true
        $rec.updatedAt = (Get-Date).ToString("o")
    }
    Set-ActiveMpFolderForServer $serverId
    Save-MultiplayerFoldersStore $store
}

function Get-LibrarySidebarCounts {
    $counts = @{ Mods = 0; Maps = 0; DLC = 0; Scripts = 0; Favourites = 0 }
    try {
        $fav = Get-ModFavoritesStore
        $counts.Favourites = @($fav.favorites).Count
    } catch {}
    $path = $script:Config.modsPath
    if (-not $path -or -not (Test-Path $path)) { return $counts }
    $zips = @(Get-ChildItem $path -Filter "*.zip" -ErrorAction SilentlyContinue)
    $counts.Mods = $zips.Count
    foreach ($z in $zips) {
        try {
            $meta = Resolve-LocalModMeta -LocalFile $z
            $mt = if ($meta.ModType) { $meta.ModType } else { 'Other' }
            switch ($mt) {
                'Map' { $counts.Maps++ }
                'Script' { $counts.Scripts++ }
                default {
                    if ($z.Name -match 'dlc|DLC') { $counts.DLC++ }
                }
            }
        } catch {}
    }
    return $counts
}

function Update-SidebarLibraryCounts {
    if (-not $txtNavModsBadge) { return }
    $c = Get-LibrarySidebarCounts
    if ($txtNavModsBadge) { $txtNavModsBadge.Text = [string]$c.Mods }
    if ($txtNavMapsBadge) { $txtNavMapsBadge.Text = [string]$c.Maps }
    if ($txtNavDlcBadge) { $txtNavDlcBadge.Text = [string]$c.DLC }
    if ($txtNavScriptsBadge) { $txtNavScriptsBadge.Text = [string]$c.Scripts }
    if ($txtNavFavBadge) { $txtNavFavBadge.Text = [string]$c.Favourites }
}

function Refresh-MpFoldersPage {
    if (-not $lstMpFolders) { return }
    $folders = Get-MpFolderList
    $lstMpFolders.ItemsSource = $null
    $lstMpFolders.ItemsSource = $folders
    $serverId = Get-ServerMpFolderId
    $active = Get-ActiveMultiplayerFolder
    if ($cmbMpFolderSelect) {
        $cmbMpFolderSelect.ItemsSource = $folders
        $cmbMpFolderSelect.DisplayMemberPath = "Label"
        if ($active) {
            $sel = $folders | Where-Object { $_.Id -eq $active.Id } | Select-Object -First 1
            if ($sel) { $cmbMpFolderSelect.SelectedItem = $sel }
        }
        if (-not $cmbMpFolderSelect.SelectedItem -and $folders.Count -gt 0) {
            $cmbMpFolderSelect.SelectedIndex = 0
        }
    }
    if ($txtMpFolderPath) {
        $eff = Get-EffectiveModsPath
        $txtMpFolderPath.Text = if ($eff) { $eff } else { "(nije postavljeno)" }
    }
    if ($txtMpFolderJsonPath) {
        $txtMpFolderJsonPath.Text = $script:MultiplayerFoldersPath
    }
    if ($txtMpInFolderCount) {
        $eff = Get-EffectiveModsPath
        $n = 0
        if ($eff -and (Test-Path $eff)) {
            $n = @(Get-ChildItem $eff -Filter "*.zip" -ErrorAction SilentlyContinue).Count
        }
        $txtMpInFolderCount.Text = "$n modova u odabranom folderu"
    }
    Update-SidebarLibraryCounts
    Sync-MpFolderQuickPick
}

function Sync-MpFolderQuickPick {
    if (-not $cmbMpFolderQuick) { return }
    $folders = Get-MpFolderList
    $favFirst = @($folders | Sort-Object { -not $_.IsFavorite }, Label)
    $cmbMpFolderQuick.ItemsSource = $favFirst
    $cmbMpFolderQuick.DisplayMemberPath = "Label"
    $active = Get-ActiveMultiplayerFolder
    if ($active) {
        $sel = $favFirst | Where-Object { $_.Id -eq $active.Id } | Select-Object -First 1
        if ($sel) { $cmbMpFolderQuick.SelectedItem = $sel }
    }
}

function Show-PasswordDialog {
    param([string]$dialogTitle, [string]$dialogPrompt)
    $dlg = New-Object System.Windows.Window
    $dlg.Title = $dialogTitle
    $dlg.Width = 380; $dlg.SizeToContent = "Height"
    $dlg.WindowStartupLocation = "CenterScreen"
    $dlg.WindowStyle = "None"; $dlg.AllowsTransparency = $true
    $dlg.Background = [System.Windows.Media.Brushes]::Transparent
    $dlg.ShowInTaskbar = $false; $dlg.ResizeMode = "NoResize"; $dlg.Topmost = $true

    $border = New-Object System.Windows.Controls.Border
    $border.CornerRadius = "10"
    $border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#161616")
    $border.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F5C518")
    $border.BorderThickness = "1"; $border.Padding = "28"

    $sp = New-Object System.Windows.Controls.StackPanel

    $ttl = New-Object System.Windows.Controls.TextBlock
    $ttl.Text = $dialogTitle
    $ttl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F5C518")
    $ttl.FontSize = 16; $ttl.FontWeight = "Bold"
    $ttl.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
    $ttl.Margin = "0,0,0,8"
    $sp.Children.Add($ttl) | Out-Null

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = $dialogPrompt
    $lbl.Foreground = [System.Windows.Media.Brushes]::White
    $lbl.FontSize = 13; $lbl.TextWrapping = "Wrap"
    $lbl.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
    $lbl.Margin = "0,0,0,14"
    $sp.Children.Add($lbl) | Out-Null

    $pwd = New-Object System.Windows.Controls.PasswordBox
    $pwd.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#1a1a1a")
    $pwd.Foreground = [System.Windows.Media.Brushes]::White
    $pwd.Padding = "10,8"; $pwd.FontSize = 13
    $pwd.CaretBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F5C518")
    $pwd.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#333")
    $pwd.BorderThickness = "1"; $pwd.Margin = "0,0,0,18"
    $sp.Children.Add($pwd) | Out-Null

    $bp = New-Object System.Windows.Controls.StackPanel
    $bp.Orientation = "Horizontal"; $bp.HorizontalAlignment = "Right"

    $ok = New-Object System.Windows.Controls.Button
    $ok.Content = "Potvrdi"; $ok.Width = 100; $ok.Padding = "0,10,0,10"
    $ok.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F5C518")
    $ok.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#111")
    $ok.FontWeight = "Bold"; $ok.BorderThickness = "0"; $ok.Cursor = "Hand"; $ok.Margin = "0,0,8,0"
    $ok.Add_Click({ $dlg.Tag = $pwd.Password; $dlg.DialogResult = $true })
    $bp.Children.Add($ok) | Out-Null

    $cn = New-Object System.Windows.Controls.Button
    $cn.Content = "Odustani"; $cn.Width = 100; $cn.Padding = "0,10,0,10"
    $cn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#333")
    $cn.Foreground = [System.Windows.Media.Brushes]::White
    $cn.BorderThickness = "0"; $cn.Cursor = "Hand"
    $cn.Add_Click({ $dlg.DialogResult = $false })
    $bp.Children.Add($cn) | Out-Null

    $sp.Children.Add($bp) | Out-Null
    $border.Child = $sp; $dlg.Content = $border

    $pwd.Add_KeyDown({
        if ($_.Key -eq [System.Windows.Input.Key]::Return) {
            $dlg.Tag = $pwd.Password; $dlg.DialogResult = $true
        }
    })
    try { $dlg.Owner = $window } catch {}
    if ($dlg.ShowDialog()) { return $dlg.Tag }
    return $null
}

# ============================================================
# THEMED DIALOG (replaces System.Windows.MessageBox)
# ============================================================
function Show-SRDialog {
    param(
        [string]$message,
        [string]$title = "SR Launcher",
        [string]$icon = "Info"  # Info, Warning, Error, Success
    )
    $dlg = New-Object System.Windows.Window
    $dlg.Title = $title
    $dlg.Width = 420; $dlg.SizeToContent = "Height"
    $dlg.WindowStartupLocation = "CenterScreen"
    $dlg.WindowStyle = "None"; $dlg.AllowsTransparency = $true
    $dlg.Background = [System.Windows.Media.Brushes]::Transparent
    $dlg.ShowInTaskbar = $false; $dlg.ResizeMode = "NoResize"; $dlg.Topmost = $true

    $accentColor = switch ($icon) {
        "Warning" { "#FFB224" }
        "Error"   { "#E5484D" }
        "Success" { "#30A46C" }
        default   { "#F5C518" }
    }
    $iconSymbol = switch ($icon) {
        "Warning" { [char]0x26A0 }
        "Error"   { [char]0x2716 }
        "Success" { [char]0x2714 }
        default   { [char]0x2139 }
    }

    $border = New-Object System.Windows.Controls.Border
    $border.CornerRadius = "12"
    $border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#161616")
    $border.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($accentColor)
    $border.BorderThickness = "1"; $border.Padding = "28,24"

    $sp = New-Object System.Windows.Controls.StackPanel

    # Icon + Title row
    $headerPanel = New-Object System.Windows.Controls.StackPanel
    $headerPanel.Orientation = "Horizontal"
    $headerPanel.Margin = "0,0,0,12"

    $iconTb = New-Object System.Windows.Controls.TextBlock
    $iconTb.Text = $iconSymbol
    $iconTb.FontSize = 20
    $iconTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($accentColor)
    $iconTb.Margin = "0,0,10,0"
    $iconTb.VerticalAlignment = "Center"
    $headerPanel.Children.Add($iconTb) | Out-Null

    $ttl = New-Object System.Windows.Controls.TextBlock
    $ttl.Text = $title
    $ttl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($accentColor)
    $ttl.FontSize = 16; $ttl.FontWeight = "Bold"
    $ttl.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
    $ttl.VerticalAlignment = "Center"
    $headerPanel.Children.Add($ttl) | Out-Null

    $sp.Children.Add($headerPanel) | Out-Null

    $msg = New-Object System.Windows.Controls.TextBlock
    $msg.Text = $message
    $msg.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#ccc")
    $msg.FontSize = 13; $msg.TextWrapping = "Wrap"
    $msg.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
    $msg.Margin = "0,0,0,20"
    $sp.Children.Add($msg) | Out-Null

    $ok = New-Object System.Windows.Controls.Button
    $ok.Content = "U redu"; $ok.HorizontalAlignment = "Right"
    $ok.Width = 110; $ok.Padding = "0,10,0,10"
    $ok.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($accentColor)
    $ok.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#111")
    $ok.FontWeight = "Bold"; $ok.FontSize = 13; $ok.BorderThickness = "0"; $ok.Cursor = "Hand"
    $ok.Add_Click({ $dlg.DialogResult = $true })
    $sp.Children.Add($ok) | Out-Null

    $border.Child = $sp; $dlg.Content = $border
    try { $dlg.Owner = $window } catch {}
    $dlg.ShowDialog() | Out-Null
}

function Show-SRConfirm {
    param(
        [string]$message,
        [string]$title = "Potvrda",
        [string]$yesText = "Da",
        [string]$noText = "Ne",
        [switch]$showCancel
    )
    $dlg = New-Object System.Windows.Window
    $dlg.Title = $title
    $dlg.Width = 440; $dlg.SizeToContent = "Height"
    $dlg.WindowStartupLocation = "CenterScreen"
    $dlg.WindowStyle = "None"; $dlg.AllowsTransparency = $true
    $dlg.Background = [System.Windows.Media.Brushes]::Transparent
    $dlg.ShowInTaskbar = $false; $dlg.ResizeMode = "NoResize"; $dlg.Topmost = $true
    $dlg.Tag = "No"

    $border = New-Object System.Windows.Controls.Border
    $border.CornerRadius = "12"
    $border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#161616")
    $border.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F5C518")
    $border.BorderThickness = "1"; $border.Padding = "28,24"

    $sp = New-Object System.Windows.Controls.StackPanel

    $headerPanel = New-Object System.Windows.Controls.StackPanel
    $headerPanel.Orientation = "Horizontal"
    $headerPanel.Margin = "0,0,0,12"

    $iconTb = New-Object System.Windows.Controls.TextBlock
    $iconTb.Text = "?"
    $iconTb.FontSize = 22; $iconTb.FontWeight = "Bold"
    $iconTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F5C518")
    $iconTb.Margin = "0,0,10,0"
    $iconTb.VerticalAlignment = "Center"
    $headerPanel.Children.Add($iconTb) | Out-Null

    $ttl = New-Object System.Windows.Controls.TextBlock
    $ttl.Text = $title
    $ttl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F5C518")
    $ttl.FontSize = 16; $ttl.FontWeight = "Bold"
    $ttl.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
    $ttl.VerticalAlignment = "Center"
    $headerPanel.Children.Add($ttl) | Out-Null

    $sp.Children.Add($headerPanel) | Out-Null

    $msg = New-Object System.Windows.Controls.TextBlock
    $msg.Text = $message
    $msg.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#ccc")
    $msg.FontSize = 13; $msg.TextWrapping = "Wrap"
    $msg.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
    $msg.Margin = "0,0,0,20"
    $sp.Children.Add($msg) | Out-Null

    $bp = New-Object System.Windows.Controls.StackPanel
    $bp.Orientation = "Horizontal"; $bp.HorizontalAlignment = "Right"

    $yes = New-Object System.Windows.Controls.Button
    $yes.Content = $yesText; $yes.Width = 100; $yes.Padding = "0,10,0,10"
    $yes.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F5C518")
    $yes.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#111")
    $yes.FontWeight = "Bold"; $yes.FontSize = 13; $yes.BorderThickness = "0"; $yes.Cursor = "Hand"
    $yes.Margin = "0,0,8,0"
    $yes.Add_Click({ $dlg.Tag = "Yes"; $dlg.DialogResult = $true })
    $bp.Children.Add($yes) | Out-Null

    $no = New-Object System.Windows.Controls.Button
    $no.Content = $noText; $no.Width = 100; $no.Padding = "0,10,0,10"
    $no.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#333")
    $no.Foreground = [System.Windows.Media.Brushes]::White
    $no.FontSize = 13; $no.BorderThickness = "0"; $no.Cursor = "Hand"
    $no.Margin = "0,0,8,0"
    $no.Add_Click({ $dlg.Tag = "No"; $dlg.DialogResult = $true })
    $bp.Children.Add($no) | Out-Null

    if ($showCancel) {
        $cancel = New-Object System.Windows.Controls.Button
        $cancel.Content = "Odustani"; $cancel.Width = 100; $cancel.Padding = "0,10,0,10"
        $cancel.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#222")
        $cancel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#888")
        $cancel.FontSize = 13; $cancel.BorderThickness = "0"; $cancel.Cursor = "Hand"
        $cancel.Add_Click({ $dlg.Tag = "Cancel"; $dlg.DialogResult = $true })
        $bp.Children.Add($cancel) | Out-Null
    }

    $sp.Children.Add($bp) | Out-Null
    $border.Child = $sp; $dlg.Content = $border
    try { $dlg.Owner = $window } catch {}
    $dlg.ShowDialog() | Out-Null
    return $dlg.Tag
}

# ============================================================
# AUTO-UPDATE
# 1. Bot endpoint (/launcher/latest) - dinamicki dohvaca najnoviji GitHub release
# 2. Fallback: GitHub Releases API - direktno provjerava releaseove
# ============================================================
$script:UpdateGitHubRepo = "7oncha/SRManager-Installer"
$script:LauncherZipName = "SR_Manager.zip"

function Get-LauncherManifest {
    try {
        $url = "https://raw.githubusercontent.com/$($script:UpdateGitHubRepo)/master/launcher/manifest.json?nocache=$([DateTime]::UtcNow.Ticks)"
        return Invoke-RestMethod -Uri $url -Headers @{ "User-Agent" = "SlavonskaRavnica-Launcher" } -TimeoutSec 10
    } catch { return $null }
}

function Get-LauncherZipDownloadUrl {
    param($ReleaseAssets, $TagName)
    $manifest = Get-LauncherManifest
    if ($manifest -and $manifest.downloadUrl) { return [string]$manifest.downloadUrl }
    if ($ReleaseAssets) {
        $zip = $ReleaseAssets | Where-Object { $_.name -eq $script:LauncherZipName } | Select-Object -First 1
        if ($zip -and $zip.browser_download_url) { return [string]$zip.browser_download_url }
    }
    if ($TagName) {
        $tag = if ($TagName -match '^v') { $TagName } else { "v$TagName" }
        return "https://github.com/$($script:UpdateGitHubRepo)/releases/download/$tag/$($script:LauncherZipName)"
    }
    return "https://github.com/$($script:UpdateGitHubRepo)/releases/latest/download/$($script:LauncherZipName)"
}

function Get-LauncherInstallDir {
    $dir = $PSScriptRoot
    if (-not $dir) {
        $dir = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    if (-not $dir) {
        $dir = Split-Path -Parent $PSCommandPath
    }
    return [string]$dir
}

function Get-AppVersionFromScript {
    param([string]$Path)
    if (-not $Path) {
        if ($PSCommandPath) { $Path = $PSCommandPath }
        else { $Path = Join-Path (Get-LauncherInstallDir) 'SlavonskaRavnica.ps1' }
    }
    try {
        if (Test-Path $Path) {
            $m = [regex]::Match((Get-Content $Path -Raw -ErrorAction Stop), '\$script:AppVersion\s*=\s*"([^"]+)"')
            if ($m.Success) { return $m.Groups[1].Value }
        }
    } catch {}
    return $null
}

function Sync-AppVersionFromScript {
    param([string]$Path)
    $v = Get-AppVersionFromScript -Path $Path
    if ($v) { $script:AppVersion = $v }
    return $script:AppVersion
}

function Update-AppVersionDisplay {
    if ($txtVersion) { $txtVersion.Text = "v$($script:AppVersion)" }
}

function Copy-LauncherPayloadToInstallDir {
    param([string]$SourceDir, [string]$DestDir)
    foreach ($item in Get-ChildItem $SourceDir -Force) {
        $dest = Join-Path $DestDir $item.Name
        if ($item.PSIsContainer) {
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            Copy-LauncherPayloadToInstallDir -SourceDir $item.FullName -DestDir $dest
        } else {
            try { if (Test-Path $dest) { Copy-Item $dest "$dest.bak" -Force -ErrorAction SilentlyContinue } } catch {}
            Copy-Item $item.FullName $dest -Force
            Write-Log "Azurirano: $($item.Name) ($DestDir)"
        }
    }
}

function Start-LauncherFromInstallDir {
    param([string]$InstallDir)
    $bat = Join-Path $InstallDir 'Pokreni SR Manager.bat'
    $vbs = Join-Path $InstallDir 'SR Manager.vbs'
    $ps1 = Join-Path $InstallDir 'SlavonskaRavnica.ps1'
    if (Test-Path $bat) {
        Start-Process -FilePath $bat -WorkingDirectory $InstallDir
        return
    }
    if (Test-Path $vbs) {
        Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$vbs`"" -WorkingDirectory $InstallDir
        return
    }
    if (Test-Path $ps1) {
        $args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$ps1`""
        Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WorkingDirectory $InstallDir
    }
}

function New-SRManagerDesktopShortcut {
    param([string]$InstallDir = (Get-LauncherInstallDir))
    if (-not $InstallDir -or -not (Test-Path $InstallDir)) { return $false }
    $ws = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shortcut = $ws.CreateShortcut((Join-Path $desktop 'SR Manager.lnk'))
    $bat = Join-Path $InstallDir 'Pokreni SR Manager.bat'
    if (-not (Test-Path $bat)) { $bat = Join-Path $InstallDir 'SR Manager.bat' }
    if (-not (Test-Path $bat)) { $bat = Join-Path $InstallDir 'SR Manager.vbs' }
    $shortcut.TargetPath = $bat
    $shortcut.Arguments = ''
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.Description = 'Slavonska Ravnica - SR Manager'
    $logo = Join-Path $InstallDir 'sr_logo.ico'
    if (Test-Path $logo) { $shortcut.IconLocation = "$logo,0" }
    $shortcut.WindowStyle = 7
    $shortcut.Save()
    return $true
}

function Test-DesktopShortcutNeedsRepair {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop 'SR Manager.lnk'
    if (-not (Test-Path $lnkPath)) { return $true }
    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnkPath)
        $target = [string]$sc.TargetPath
        if ($target -match '(?i)wscript|powershell') { return $true }
        if ($target -match '(?i)SRManager\.exe$') { return $true }
        $bat = Join-Path (Get-LauncherInstallDir) 'Pokreni SR Manager.bat'
        if ((Test-Path $bat) -and ($target -ne $bat)) { return $true }
    } catch { return $true }
    return $false
}

function Repair-SRManagerDesktopShortcut {
    try {
        if (New-SRManagerDesktopShortcut) {
            Write-Log 'Desktop shortcut azuriran (Pokreni SR Manager.bat).'
            return $true
        }
    } catch {
        Write-Log "WARN shortcut: $($_.Exception.Message)"
    }
    return $false
}

function Apply-ZipToLatestVersion {
    param($Version, $Notes, $ReleaseAssets, $TagName)
    $zipUrl = Get-LauncherZipDownloadUrl -ReleaseAssets $ReleaseAssets -TagName $TagName
    $script:LatestVersion = @{
        version = $Version
        url     = $zipUrl
        notes   = $Notes
        assets  = @(@{ name = $script:LauncherZipName; browser_download_url = $zipUrl })
    }
}

function Check-ForUpdate {
    $headers = @{ "User-Agent" = "SlavonskaRavnica-Launcher" }

    # 1. Primarni izvor: bot endpoint (vraca verziju i download URL iz GitHub releasea)
    try {
        $api = Get-LicenseApiConfig
        if ($api) {
            $url = "$($api.url)/launcher/latest"
            Write-Log "Provjeravam update (bot): $url"
            $latest = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 10
            if ($latest -and $latest.version -and $latest.version -ne $script:AppVersion) {
                $tag = if ($latest.version -match '^v') { $latest.version } else { "v$($latest.version)" }
                Apply-ZipToLatestVersion -Version $latest.version -Notes $latest.notes -TagName $tag
                Write-Log "Nova verzija (bot): v$($latest.version) | ZIP: $($script:LatestVersion.url)"
                return $true
            }
            Write-Log "Aplikacija je azurna (bot endpoint)."
            return $false
        }
    } catch {
        Write-Log "Bot update endpoint nedostupan: $($_.Exception.Message)"
    }

    # 2. Fallback: GitHub Releases API
    try {
        $url = "https://api.github.com/repos/$($script:UpdateGitHubRepo)/releases/latest"
        Write-Log "Provjeravam update (GitHub): $url"
        $release = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 10
        $remoteVersion = $release.tag_name -replace '^v',''
        if ($remoteVersion -and $remoteVersion -ne $script:AppVersion) {
            Apply-ZipToLatestVersion -Version $remoteVersion -Notes $release.body -ReleaseAssets $release.assets -TagName $release.tag_name
            Write-Log "Nova verzija (GitHub): v$remoteVersion | ZIP: $($script:LatestVersion.url)"
            return $true
        }
        Write-Log "Aplikacija je azurna (GitHub)."
    } catch {
        Write-Log "GitHub API greska: $($_.Exception.Message)"
    }
    return $false
}

function Download-Update {
    if (-not $script:LatestVersion) { return }

    $installDir = Get-LauncherInstallDir
    $targetVer = [string]$script:LatestVersion.version
    $tag = if ($targetVer -match '^v') { $targetVer } else { "v$targetVer" }
    Write-Log "Update: ciljni folder = $installDir (trenutno v$($script:AppVersion) -> v$targetVer)"

    $updated = $false
    $wc = $null

    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "SlavonskaRavnica-Launcher")

        $zipUrl = $null
        if ($script:LatestVersion.url) { $zipUrl = [string]$script:LatestVersion.url }
        if (-not $zipUrl) {
            $zipUrl = Get-LauncherZipDownloadUrl -ReleaseAssets $script:LatestVersion.assets -TagName $tag
        }

        $asset = $null
        if ($script:LatestVersion.assets) {
            $asset = $script:LatestVersion.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
            if (-not $asset) {
                $asset = $script:LatestVersion.assets | Where-Object { $_.name -like "*.exe" } | Select-Object -First 1
            }
        }
        if ($asset -and $asset.browser_download_url) { $zipUrl = [string]$asset.browser_download_url }

        if ($zipUrl -and $zipUrl -like "*.zip*") {
            $tempZip = Join-Path $env:TEMP "SlavonskaRavnica_update_$([Guid]::NewGuid().ToString('N')).zip"
            $tempDir = Join-Path $env:TEMP "SlavonskaRavnica_update_$([Guid]::NewGuid().ToString('N'))"
            Write-Log "Skidam ZIP: $zipUrl"
            $wc.DownloadFile($zipUrl, $tempZip)

            if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            [System.IO.Compression.ZipFile]::ExtractToDirectory($tempZip, $tempDir)

            $srcDir = $tempDir
            $nested = Get-ChildItem $tempDir -Directory | Where-Object { $_.Name -eq 'SR_Manager' } | Select-Object -First 1
            if ($nested) { $srcDir = $nested.FullName }
            if (-not (Get-ChildItem $srcDir -File -ErrorAction SilentlyContinue)) {
                $onlySub = Get-ChildItem $srcDir -Directory | Select-Object -First 1
                if ($onlySub) { $srcDir = $onlySub.FullName }
            }

            Copy-LauncherPayloadToInstallDir -SourceDir $srcDir -DestDir $installDir
            Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            $updated = $true
        } elseif ($asset -and $asset.browser_download_url -and $asset.name -like "*.exe") {
            $dest = Join-Path $installDir "SRManager.exe"
            try { Copy-Item $dest "$dest.bak" -Force -ErrorAction SilentlyContinue } catch {}
            Write-Log "Skidam .exe: $($asset.browser_download_url)"
            $wc.DownloadFile($asset.browser_download_url, $dest)
            $updated = $true
        } else {
            try {
                $rawUrl = "https://raw.githubusercontent.com/$($script:UpdateGitHubRepo)/refs/tags/$tag/SlavonskaRavnica.ps1?nocache=$([DateTime]::UtcNow.Ticks)"
                Write-Log "ZIP nije dostupan, skidam .ps1 s taga: $rawUrl"
                $ps1Content = $wc.DownloadString($rawUrl)
                if ($ps1Content -and $ps1Content.Length -gt 1000) {
                    $dest = Join-Path $installDir "SlavonskaRavnica.ps1"
                    try { Copy-Item $dest "$dest.bak" -Force -ErrorAction SilentlyContinue } catch {}
                    [System.IO.File]::WriteAllText($dest, $ps1Content, [System.Text.UTF8Encoding]::new($false))
                    Write-Log "Skripta azurirana s release taga."
                    $updated = $true
                }
            } catch { Write-Log "GRESKA ps1 s taga: $($_.Exception.Message)" }
        }
    } catch {
        Write-Log "GRESKA update download: $($_.Exception.Message)"
        if ($script:LatestVersion.url) { Start-Process $script:LatestVersion.url }
        return
    } finally {
        if ($wc) { $wc.Dispose() }
    }

    if (-not $updated) {
        Write-Log "Update nije uspio - otvaram stranicu releasea."
        if ($script:LatestVersion.url) { Start-Process $script:LatestVersion.url }
        return
    }

    $ps1Path = Join-Path $installDir 'SlavonskaRavnica.ps1'
    $installedVer = Sync-AppVersionFromScript -Path $ps1Path
    Update-AppVersionDisplay
    Write-Log "Update zavrsen u: $installDir | verzija u datoteci: v$installedVer"

    if ($targetVer -and $installedVer -and $installedVer -ne $targetVer) {
        Write-Log "UPOZORENJE: ocekivano v$targetVer, u ps1 je v$installedVer - provjeri GitHub release ZIP."
    }

    $showVer = if ($installedVer) { $installedVer } else { $targetVer }
    $r = Show-SRConfirm "Nova verzija v$showVer instalirana u:`n$installDir`n`nRestartati launcher sada (preporuceno)?" "Update" "Restart" "Kasnije"
    if ($r -eq 'Yes') {
        Write-Log "Ponovno pokretanje iz: $installDir"
        Start-LauncherFromInstallDir -InstallDir $installDir
        try { $window.Close() } catch {}
        return
    }
    Show-SRDialog "Update spremljen u:`n$installDir`n`nZatvori prozor i pokreni Ponovno SR Manager.bat iz istog foldera." "Update" "Success"
}

# ============================================================
# CONFIG
# ============================================================
function Load-Config {
    if (Test-Path $script:ConfigPath) {
        try {
            $json = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            if ($json.servers) { return (Merge-UserGameSettings $json) }
        } catch {}
    }
    $config = [PSCustomObject]@{
        version      = "2.1"
        adminHash    = ""
        gamePath     = ""
        modsPath     = ""
        activeServer = 0
        lastSync     = ""
        githubRepo   = ""
        servers      = @(
            [PSCustomObject]@{
                name      = "Slavonska Ravnica"
                ip        = "176.57.169.250"
                webPort   = 8620
                gamePort  = 8600
                statsCode = "oXuXiWxTnqiShUny"
                password  = ""
            },
            [PSCustomObject]@{
                name      = "Test Server"
                ip        = "147.93.161.239"
                webPort   = 8140
                gamePort  = 8140
                statsCode = "IFXRc8mlk4NAunjg"
                password  = ""
            }
        )
    }
    $config | ConvertTo-Json -Depth 5 | Set-Content $script:ConfigPath -Encoding UTF8
    return (Merge-UserGameSettings $config)
}

function Save-Config {
    $script:Config | ConvertTo-Json -Depth 5 | Set-Content $script:ConfigPath -Encoding UTF8
}

# ============================================================
# SHARED CONFIG (serveri, linkovi - sync sa GitHuba ili weba)
# ============================================================
function Sync-SharedConfig {
    $urls = @(
        "https://raw.githubusercontent.com/7oncha/SRManager-Installer/master/sr_shared_config.json",
        "https://slavonska-ravnica.com/sr_shared_config.json"
    )
    $shared = $null
    foreach ($url in $urls) {
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "SRManager")
            $json = $wc.DownloadString($url)
            $wc.Dispose()
            $parsed = $json | ConvertFrom-Json
            if ($parsed.servers) {
                $shared = $parsed
                break
            }
        } catch { }
    }
    if (-not $shared) { return $false }

    # Merge servere - shared serveri uvijek zamjene lokalne po imenu
    $updated = $false
    foreach ($remoteSrv in $shared.servers) {
        $localMatch = $script:Config.servers | Where-Object { $_.name -eq $remoteSrv.name }
        if ($localMatch) {
            # Azuriraj postojeci server
            $localMatch.ip        = $remoteSrv.ip
            $localMatch.webPort   = $remoteSrv.webPort
            $localMatch.gamePort  = $remoteSrv.gamePort
            $localMatch.statsCode = $remoteSrv.statsCode
            if ($remoteSrv.password) { $localMatch.password = $remoteSrv.password }
            $updated = $true
        } else {
            # Dodaj novi server
            $script:Config.servers += [PSCustomObject]@{
                name      = $remoteSrv.name
                ip        = $remoteSrv.ip
                webPort   = $remoteSrv.webPort
                gamePort  = $remoteSrv.gamePort
                statsCode = if ($remoteSrv.statsCode) { $remoteSrv.statsCode } else { "" }
                password  = if ($remoteSrv.password) { $remoteSrv.password } else { "" }
            }
            $updated = $true
        }
    }

    # Ukloni servere koji vise ne postoje u shared configu (ali zadrzi custom servere)
    if ($shared.servers) {
        $remoteNames = $shared.servers | ForEach-Object { $_.name }
        $script:Config.servers = @($script:Config.servers | Where-Object {
            ($remoteNames -contains $_.name) -or
            ($_.PSObject.Properties.Name -contains 'isCustom' -and $_.isCustom)
        })
        # Popravi activeServer index
        if ([int]$script:Config.activeServer -ge $script:Config.servers.Count) {
            $script:Config.activeServer = 0
        }
        $updated = $true
    }

    # Merge linkove ako postoje
    if ($shared.webUrl) { $script:SharedWebUrl = $shared.webUrl }
    if ($shared.discordUrl) { $script:SharedDiscordUrl = $shared.discordUrl }
    if ($shared.githubRepo) {
        $script:Config.githubRepo = $shared.githubRepo
    }
    if ($shared.licenseApi -and $shared.licenseApi.url -and $shared.licenseApi.token) {
        $script:Config | Add-Member -NotePropertyName 'licenseApi' -NotePropertyValue $shared.licenseApi -Force
        $script:SharedConfig = $shared
        $updated = $true
    }

    if ($updated) { Save-Config }
    return $true
}

# Config + game paths: inicijalizira se na splash ekranu (brzi start)

# ============================================================
# SERVER COMMUNICATION
# ============================================================
function Initialize-LauncherConfig {
    $script:Config = Load-Config
    Apply-GameLaunchDefaults
    if ($script:Config.githubRepo) {
        $repo = $script:Config.githubRepo -replace '^https?://github\.com/','' -replace '/$',''
        $script:GitHubRepo = $repo
    }
    if (-not $script:Config.gamePath) {
        $plat = if ($script:Config.gamePlatform) { $script:Config.gamePlatform } else { 'auto' }
        $detected = Find-GamePathForPlatform -Platform $plat
        if ($detected) {
            $script:Config.gamePath = $detected
            if (-not $script:Config.gamePlatform) {
                $script:Config | Add-Member -NotePropertyName gamePlatform -NotePropertyValue (Get-GamePlatformFromPath $detected) -Force
            }
            Save-Config
        }
    }
    if (-not $script:Config.modsPath) {
        $detected = Find-ModsPath
        if ($detected) { $script:Config.modsPath = $detected; Save-Config }
    }
}
function Get-ActiveServer {
    $idx = [Math]::Max(0, [Math]::Min([int]$script:Config.activeServer, $script:Config.servers.Count - 1))
    return $script:Config.servers[$idx]
}

function Get-ServerStatus {
    $server = Get-ActiveServer
    if (-not $server.statsCode) { return @{ online = $false } }
    $url = "http://$($server.ip):$($server.webPort)/feed/dedicated-server-stats.xml?code=$($server.statsCode)"
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
        # Ukloni BOM ako postoji
        $xmlText = $response.Content -replace '^\xEF\xBB\xBF',''
        $xmlText = $xmlText.Trim()
        [xml]$xml = $xmlText
        $s = $xml.Server
        $playerNames = @()
        $playerObjs = @()
        if ($s.Slots -and $s.Slots.Player) {
            foreach ($p in @($s.Slots.Player)) {
                if ($p -is [System.Xml.XmlElement]) {
                    if ($p.GetAttribute('isUsed') -eq 'true') {
                        $n = $p.InnerText
                        if (-not $n -and $p.HasAttribute('name')) { $n = $p.GetAttribute('name') }
                        if ($n) {
                            $playerNames += $n
                            $upMin = 0
                            try { $upMin = [int]$p.GetAttribute('uptime') } catch {}
                            $isAdm = ($p.GetAttribute('isAdmin') -eq 'true')
                            $playerObjs += [PSCustomObject]@{
                                Name = $n
                                Uptime = $upMin
                                UptimeStr = if ($upMin -ge 60) { "{0}h {1}m" -f ([int]($upMin/60)), ($upMin%60) } else { "$upMin min" }
                                IsAdmin = $isAdm
                                Discord = $null
                            }
                        }
                    }
                }
            }
        }
        # Map Discord (config.playerDiscord = @{ playerName = @{ id, name, avatar } })
        if ($script:Config.playerDiscord) {
            foreach ($po in $playerObjs) {
                $key = $po.Name
                if ($script:Config.playerDiscord.PSObject.Properties.Name -contains $key) {
                    $po.Discord = $script:Config.playerDiscord.$key
                }
            }
        }
        $srvName = if ($s.GetAttribute('name')) { $s.GetAttribute('name') } else { $server.name }
        $mapName = if ($s.GetAttribute('mapName')) { $s.GetAttribute('mapName') } else { '?' }
        $gameVer = if ($s.GetAttribute('version')) { $s.GetAttribute('version') } else { '' }
        return @{
            online        = $true
            name          = $srvName
            map           = $mapName
            playersOnline = [int]$s.Slots.GetAttribute('numUsed')
            playersMax    = [int]$s.Slots.GetAttribute('capacity')
            players       = $playerNames
            playerObjs    = $playerObjs
            gameVersion   = $gameVer
        }
    } catch {
        return @{ online = $false }
    }
}

function Get-ServerModList {
    $script:ModListSource = 'html'
    # Try authoritative bot manifest first (includes SHA-256 hashes).
    try {
        $manifest = Get-ModManifestFromBot
        if ($manifest -and $manifest.Count -gt 0) {
            $script:ModListSource = 'bot-sha256'
            $server = Get-ActiveServer
            # Attach download URLs derived from the active server's web mod list.
            foreach ($m in $manifest) {
                if (-not $m.Url -and $server) {
                    $m.Url = "http://$($server.ip):$($server.webPort)/mods/$($m.Name)"
                }
            }
            return $manifest
        }
    } catch {}

    # Fallback: scrape mods.html (legacy path, no SHA-256 available).
    $server = Get-ActiveServer
    $url = "http://$($server.ip):$($server.webPort)/mods.html"
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
        $html = $response.Content
        $results = @()
        $regex = [regex]'href="([^"]*?([^/"]+\.zip))"'
        $regexMatches = $regex.Matches($html)
        foreach ($m in $regexMatches) {
            $href = $m.Groups[1].Value
            $name = $m.Groups[2].Value
            if (-not $href.StartsWith("http")) {
                if ($href.StartsWith("/")) {
                    $href = "http://$($server.ip):$($server.webPort)$href"
                } else {
                    $href = "http://$($server.ip):$($server.webPort)/$href"
                }
            }
            if (-not ($results | Where-Object { $_.Name -eq $name })) {
                $results += [PSCustomObject]@{ Name = $name; Url = $href; Sha256 = ''; Size = 0; Source = 'html' }
            }
        }
        return $results
    } catch {
        return $null
    }
}

# ============================================================
# SR LOGO (embedded SVG-style path data rendered as WPF)
# ============================================================
function Get-LogoBase64 {
    # Download SR logo from website and cache it locally
    $logoCache = Join-Path $PSScriptRoot "sr_logo.png"
    if (Test-Path $logoCache) {
        $bytes = [System.IO.File]::ReadAllBytes($logoCache)
        return [Convert]::ToBase64String($bytes)
    }
    try {
        $wc = New-Object System.Net.WebClient
        $bytes = $wc.DownloadData("https://slavonska-ravnica.com/sr_logo.png")
        $wc.Dispose()
        [System.IO.File]::WriteAllBytes($logoCache, $bytes)
        return [Convert]::ToBase64String($bytes)
    } catch {
        # Try favicon
        try {
            $wc2 = New-Object System.Net.WebClient
            $bytes2 = $wc2.DownloadData("https://slavonska-ravnica.com/favicon.ico")
            $wc2.Dispose()
            [System.IO.File]::WriteAllBytes($logoCache, $bytes2)
            return [Convert]::ToBase64String($bytes2)
        } catch { return $null }
    }
}

# ============================================================
# SPLASH / LOADING SCREEN
# ============================================================
function Show-SplashScreen {
    Close-EarlySplash
    $splash = New-Object System.Windows.Window
    $splash.WindowStyle = "None"
    $splash.AllowsTransparency = $true
    $splash.Background = [System.Windows.Media.Brushes]::Transparent
    $splash.Width = 420; $splash.Height = 260
    $splash.WindowStartupLocation = "CenterScreen"
    $splash.ResizeMode = "NoResize"
    $splash.Topmost = $true
    $splash.ShowInTaskbar = $true

    $border = New-Object System.Windows.Controls.Border
    $border.CornerRadius = "16"
    $border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0d0d0d")
    $border.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F5C518")
    $border.BorderThickness = "1"
    $border.Padding = "30,24"

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.VerticalAlignment = "Center"

    # Logo - try PNG first, then ICO, skip if none found
    $logoLoaded = $false
    foreach ($logoFile in @("sr_logo.png", "sr_logo.ico")) {
        $logoPath = Join-Path $PSScriptRoot $logoFile
        if ((Test-Path $logoPath) -and (Get-Item $logoPath).Length -gt 100) {
            try {
                $img = New-Object System.Windows.Controls.Image
                $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
                $bmp.BeginInit()
                $bmp.UriSource = New-Object System.Uri($logoPath)
                $bmp.CacheOption = "OnLoad"
                $bmp.EndInit()
                $img.Source = $bmp; $img.Width = 48; $img.Height = 48; $img.Margin = "0,0,0,12"
                $img.HorizontalAlignment = "Center"
                $sp.Children.Add($img) | Out-Null
                $logoLoaded = $true
                break
            } catch { }
        }
    }

    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = "Slavonska Ravnica"
    $title.FontSize = 20; $title.FontWeight = "Bold"
    $title.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F5C518")
    $title.HorizontalAlignment = "Center"
    $title.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
    $title.Margin = "0,0,0,6"
    $sp.Children.Add($title) | Out-Null

    $ver = New-Object System.Windows.Controls.TextBlock
    $ver.Text = "v$($script:AppVersion)"
    $ver.FontSize = 11; $ver.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#666")
    $ver.HorizontalAlignment = "Center"
    $ver.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
    $ver.Margin = "0,0,0,20"
    $sp.Children.Add($ver) | Out-Null

    $status = New-Object System.Windows.Controls.TextBlock
    $status.Text = "Ucitavam..."
    $status.FontSize = 12; $status.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#aaa")
    $status.HorizontalAlignment = "Center"
    $status.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
    $status.Margin = "0,0,0,10"
    $sp.Children.Add($status) | Out-Null

    # Progress bar
    $progressBorder = New-Object System.Windows.Controls.Border
    $progressBorder.Height = 4; $progressBorder.CornerRadius = "2"
    $progressBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#222")
    $progressBorder.HorizontalAlignment = "Stretch"
    $progressGrid = New-Object System.Windows.Controls.Grid
    $progressFill = New-Object System.Windows.Controls.Border
    $progressFill.Height = 4; $progressFill.CornerRadius = "2"
    $progressFill.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F5C518")
    $progressFill.HorizontalAlignment = "Left"; $progressFill.Width = 0
    $progressGrid.Children.Add($progressFill) | Out-Null
    $progressBorder.Child = $progressGrid
    $sp.Children.Add($progressBorder) | Out-Null

    $border.Child = $sp
    $splash.Content = $border

    # Store references for updating
    $script:SplashStatus = $status
    $script:SplashProgress = $progressFill
    $script:SplashWindow = $splash
    $script:SplashMaxWidth = 360

    return $splash
}

function Update-Splash {
    param([string]$msg, [int]$pct)
    try {
        $script:SplashStatus.Text = $msg
        $script:SplashProgress.Width = [Math]::Max(0, $script:SplashMaxWidth * $pct / 100)
    } catch {}
}

function Invoke-SplashPump {
    try {
        if ($script:SplashWindow) {
            $script:SplashWindow.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
        }
    } catch {}
}

function Set-SplashStep {
    param([string]$Message, [int]$Percent)
    Update-Splash -msg $Message -pct $Percent
    Invoke-SplashPump
}

function Close-StartupSplash {
    try {
        if ($script:SplashWindow) {
            $script:SplashWindow.Close()
            $script:SplashWindow = $null
        }
    } catch {}
    Close-EarlySplash
}

$script:PreloadedServerStatus = $null
$script:PreloadedModList = $null
$script:PreloadedGameSettings = $null
$script:PreloadedLocalModCount = $null

# ============================================================
# XAML UI
# ============================================================
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Slavonska Ravnica" Width="1080" Height="740"
        WindowStartupLocation="CenterScreen" Background="Transparent"
        WindowStyle="None" AllowsTransparency="True"
        ResizeMode="CanResizeWithGrip" MinWidth="940" MinHeight="660">

    <Window.Resources>
        <SolidColorBrush x:Key="Gold" Color="#F5C518"/>
        <SolidColorBrush x:Key="GoldDim" Color="#BF9B0F"/>
        <SolidColorBrush x:Key="GoldBright" Color="#FFD84D"/>
        <SolidColorBrush x:Key="DangerRed" Color="#E5484D"/>
        <SolidColorBrush x:Key="SuccessGreen" Color="#30A46C"/>

        <Style x:Key="BtnPrimary" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource Gold}"/>
            <Setter Property="Foreground" Value="#111"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Padding" Value="20,10"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                CornerRadius="8" Padding="{TemplateBinding Padding}" BorderThickness="0"
                                RenderTransformOrigin="0.5,0.5">
                            <Border.RenderTransform>
                                <ScaleTransform x:Name="bpScale" ScaleX="1" ScaleY="1"/>
                            </Border.RenderTransform>
                            <Border.Effect>
                                <DropShadowEffect x:Name="bpGlow" Color="#F5C518" BlurRadius="22" ShadowDepth="0" Opacity="0"/>
                            </Border.Effect>
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="{StaticResource GoldBright}"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="bpGlow" Storyboard.TargetProperty="Opacity"
                                                             To="0.75" Duration="0:0:0.25"/>
                                            <DoubleAnimation Storyboard.TargetName="bpScale" Storyboard.TargetProperty="ScaleX"
                                                             To="1.03" Duration="0:0:0.18">
                                                <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                            </DoubleAnimation>
                                            <DoubleAnimation Storyboard.TargetName="bpScale" Storyboard.TargetProperty="ScaleY"
                                                             To="1.03" Duration="0:0:0.18">
                                                <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                            </DoubleAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="bpGlow" Storyboard.TargetProperty="Opacity"
                                                             To="0" Duration="0:0:0.25"/>
                                            <DoubleAnimation Storyboard.TargetName="bpScale" Storyboard.TargetProperty="ScaleX"
                                                             To="1" Duration="0:0:0.2"/>
                                            <DoubleAnimation Storyboard.TargetName="bpScale" Storyboard.TargetProperty="ScaleY"
                                                             To="1" Duration="0:0:0.2"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="{StaticResource GoldDim}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Background" Value="#333"/>
                                <Setter Property="Foreground" Value="#666"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BtnGhost" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource Gold}"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Padding" Value="16,9"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                CornerRadius="8" Padding="{TemplateBinding Padding}"
                                BorderThickness="1" BorderBrush="#333">
                            <Border.Effect>
                                <DropShadowEffect x:Name="bgGlow" Color="#F5C518" BlurRadius="14" ShadowDepth="0" Opacity="0"/>
                            </Border.Effect>
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1a1a1a"/>
                                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Gold}"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="bgGlow" Storyboard.TargetProperty="Opacity"
                                                             To="0.45" Duration="0:0:0.22"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="bgGlow" Storyboard.TargetProperty="Opacity"
                                                             To="0" Duration="0:0:0.22"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#222"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BtnFlat" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#888"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Padding" Value="12,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                              VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1a1a1a"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BtnDanger" TargetType="Button">
            <Setter Property="Background" Value="#2a1515"/>
            <Setter Property="Foreground" Value="#E5484D"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Padding" Value="16,9"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                CornerRadius="8" Padding="{TemplateBinding Padding}" BorderThickness="0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#3a2020"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BtnUpdate" TargetType="Button">
            <Setter Property="Background" Value="#1a2a1a"/>
            <Setter Property="Foreground" Value="#30A46C"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Padding" Value="12,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                CornerRadius="6" Padding="{TemplateBinding Padding}"
                                BorderThickness="1" BorderBrush="#30A46C">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#2a3a2a"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ModernTextBox" TargetType="TextBox">
            <Setter Property="Background" Value="#1a1a1a"/>
            <Setter Property="Foreground" Value="#eee"/>
            <Setter Property="BorderBrush" Value="#333"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12,10"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="CaretBrush" Value="{StaticResource Gold}"/>
            <Setter Property="SelectionBrush" Value="{StaticResource GoldDim}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ScrollViewer x:Name="PART_ContentHost"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Gold}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ModernPasswordBox" TargetType="PasswordBox">
            <Setter Property="Background" Value="#1a1a1a"/>
            <Setter Property="Foreground" Value="#eee"/>
            <Setter Property="BorderBrush" Value="#333"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12,10"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="CaretBrush" Value="{StaticResource Gold}"/>
        </Style>

        <!-- ListView Themed Styles -->
        <Style TargetType="GridViewColumnHeader">
            <Setter Property="Background" Value="#1a1a1a"/>
            <Setter Property="Foreground" Value="#F5C518"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="BorderBrush" Value="#333"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="GridViewColumnHeader">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ListViewItem">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#ddd"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Padding" Value="6,6"/>
            <Setter Property="BorderBrush" Value="#1a1a1a"/>
            <Setter Property="BorderThickness" Value="0,0,0,1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListViewItem">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                Padding="{TemplateBinding Padding}">
                            <GridViewRowPresenter VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1e1e1e"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1a1a0a"/>
                                <Setter TargetName="bd" Property="BorderBrush" Value="#F5C518"/>
                                <Setter TargetName="bd" Property="BorderThickness" Value="2,0,0,0"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Toggle Switch Style -->
        <Style x:Key="ToggleSwitch" TargetType="CheckBox">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel Orientation="Horizontal">
                            <Border x:Name="track" Width="44" Height="24" CornerRadius="12"
                                    Background="#333" Padding="2" VerticalAlignment="Center">
                                <Ellipse x:Name="thumb" Width="20" Height="20" Fill="#888"
                                         HorizontalAlignment="Left"/>
                            </Border>
                            <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="track" Property="Background" Value="#F5C518"/>
                                <Setter TargetName="thumb" Property="Fill" Value="#111"/>
                                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="track" Property="BorderBrush" Value="#F5C518"/>
                                <Setter TargetName="track" Property="BorderThickness" Value="1"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Filter Button Style -->
        <Style x:Key="BtnFilter" TargetType="RadioButton">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#888"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                CornerRadius="6" Padding="{TemplateBinding Padding}"
                                BorderThickness="1" BorderBrush="#333">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#F5C518"/>
                                <Setter Property="Foreground" Value="#111"/>
                                <Setter Property="FontWeight" Value="SemiBold"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1a1a1a"/>
                                <Setter TargetName="bd" Property="BorderBrush" Value="#F5C518"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="NavBtn" TargetType="RadioButton">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#888"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontWeight" Value="Normal"/>
            <Setter Property="Padding" Value="18,12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                Padding="{TemplateBinding Padding}" CornerRadius="6" Margin="0,2"
                                RenderTransformOrigin="0.5,0.5">
                            <Border.RenderTransform>
                                <TranslateTransform x:Name="navTrans" X="0"/>
                            </Border.RenderTransform>
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Border x:Name="indicator" Width="3" CornerRadius="2"
                                        Background="Transparent" Margin="0,0,12,0" VerticalAlignment="Stretch"
                                        RenderTransformOrigin="0.5,0.5">
                                    <Border.RenderTransform>
                                        <ScaleTransform x:Name="indScale" ScaleY="0"/>
                                    </Border.RenderTransform>
                                </Border>
                                <ContentPresenter Grid.Column="1" VerticalAlignment="Center"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1a1408"/>
                                <Setter TargetName="indicator" Property="Background" Value="{StaticResource Gold}"/>
                                <Setter Property="Foreground" Value="{StaticResource Gold}"/>
                                <Setter Property="FontWeight" Value="SemiBold"/>
                                <Setter TargetName="indicator" Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Color="#F5C518" BlurRadius="10" ShadowDepth="0" Opacity="0.85"/>
                                    </Setter.Value>
                                </Setter>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="indScale"
                                                             Storyboard.TargetProperty="ScaleY"
                                                             From="0" To="1" Duration="0:0:0.25">
                                                <DoubleAnimation.EasingFunction>
                                                    <CubicEase EasingMode="EaseOut"/>
                                                </DoubleAnimation.EasingFunction>
                                            </DoubleAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="indScale"
                                                             Storyboard.TargetProperty="ScaleY"
                                                             To="0" Duration="0:0:0.15"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#151515"/>
                                <Setter Property="Foreground" Value="#ddd"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="navTrans"
                                                             Storyboard.TargetProperty="X"
                                                             To="3" Duration="0:0:0.18">
                                                <DoubleAnimation.EasingFunction>
                                                    <CubicEase EasingMode="EaseOut"/>
                                                </DoubleAnimation.EasingFunction>
                                            </DoubleAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="navTrans"
                                                             Storyboard.TargetProperty="X"
                                                             To="0" Duration="0:0:0.18"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="NavSection" TargetType="TextBlock">
            <Setter Property="FontSize" Value="9"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Foreground" Value="#555"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Margin" Value="14,8,0,4"/>
        </Style>

        <Style x:Key="ModCardListItem" TargetType="ListBoxItem">
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="VerticalContentAlignment" Value="Stretch"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="Margin" Value="0,0,10,10"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <ContentPresenter/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ContextMenu / MenuItem dark style (uklanja bijele kvadratice za icon column) -->
        <Style TargetType="ContextMenu">
            <Setter Property="Background" Value="#161616"/>
            <Setter Property="Foreground" Value="#eee"/>
            <Setter Property="BorderBrush" Value="#333"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="4"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ContextMenu">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <StackPanel IsItemsHost="True"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="MenuItem">
            <Setter Property="Foreground" Value="#eee"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="MenuItem">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter ContentSource="Header"
                                              VerticalAlignment="Center"
                                              TextBlock.Foreground="{TemplateBinding Foreground}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#262626"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.5"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="Separator">
            <Setter Property="Background" Value="#2a2a2a"/>
            <Setter Property="Height" Value="1"/>
            <Setter Property="Margin" Value="2,4"/>
        </Style>

        <!-- Icon button (mali kruzni gumb sa Segoe MDL2 ikonom + glow) -->
        <Style x:Key="IconBtn" TargetType="Button">
            <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Foreground" Value="#bbb"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Width" Value="34"/>
            <Setter Property="Height" Value="34"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                CornerRadius="17" BorderBrush="#2a2a2a" BorderThickness="1">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                              TextElement.FontFamily="{TemplateBinding FontFamily}"
                                              TextElement.FontSize="{TemplateBinding FontSize}"
                                              TextElement.Foreground="{TemplateBinding Foreground}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1f1a0a"/>
                                <Setter TargetName="bd" Property="BorderBrush" Value="#F5C518"/>
                                <Setter Property="Foreground" Value="#F5C518"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#2a2410"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Border CornerRadius="14" BorderThickness="1" ClipToBounds="True">
        <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                <GradientStop Color="#0f0f10" Offset="0"/>
                <GradientStop Color="#0a0a0b" Offset="1"/>
            </LinearGradientBrush>
        </Border.Background>
        <Border.BorderBrush>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#3a2e10" Offset="0"/>
                <GradientStop Color="#1a1a1a" Offset="0.5"/>
                <GradientStop Color="#3a2e10" Offset="1"/>
            </LinearGradientBrush>
        </Border.BorderBrush>
        <Border.Effect>
            <DropShadowEffect Color="Black" BlurRadius="24" ShadowDepth="0" Opacity="0.7"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="60"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <!-- ANIMIRANI POZADINSKI SLOJ -->
            <Canvas x:Name="bgCanvas" Grid.RowSpan="2" Panel.ZIndex="0"
                    IsHitTestVisible="False" ClipToBounds="True">
                <Ellipse Width="520" Height="520" Canvas.Left="-140" Canvas.Top="-160" Opacity="0.22">
                    <Ellipse.Fill>
                        <RadialGradientBrush>
                            <GradientStop Color="#F5C518" Offset="0"/>
                            <GradientStop Color="#00F5C518" Offset="1"/>
                        </RadialGradientBrush>
                    </Ellipse.Fill>
                    <Ellipse.RenderTransform>
                        <TranslateTransform x:Name="bgT1" X="0" Y="0"/>
                    </Ellipse.RenderTransform>
                </Ellipse>
                <Ellipse Width="640" Height="640" Canvas.Left="540" Canvas.Top="220" Opacity="0.16">
                    <Ellipse.Fill>
                        <RadialGradientBrush>
                            <GradientStop Color="#7a5a10" Offset="0"/>
                            <GradientStop Color="#007a5a10" Offset="1"/>
                        </RadialGradientBrush>
                    </Ellipse.Fill>
                    <Ellipse.RenderTransform>
                        <TranslateTransform x:Name="bgT2" X="0" Y="0"/>
                    </Ellipse.RenderTransform>
                </Ellipse>
                <Ellipse Width="380" Height="380" Canvas.Left="200" Canvas.Top="450" Opacity="0.14">
                    <Ellipse.Fill>
                        <RadialGradientBrush>
                            <GradientStop Color="#3a8b3a" Offset="0"/>
                            <GradientStop Color="#003a8b3a" Offset="1"/>
                        </RadialGradientBrush>
                    </Ellipse.Fill>
                    <Ellipse.RenderTransform>
                        <TranslateTransform x:Name="bgT3" X="0" Y="0"/>
                    </Ellipse.RenderTransform>
                </Ellipse>
                <Canvas.Triggers>
                    <EventTrigger RoutedEvent="FrameworkElement.Loaded">
                        <BeginStoryboard>
                            <Storyboard RepeatBehavior="Forever" AutoReverse="True">
                                <DoubleAnimation Storyboard.TargetName="bgT1" Storyboard.TargetProperty="X"
                                                 From="0" To="220" Duration="0:0:18"/>
                                <DoubleAnimation Storyboard.TargetName="bgT1" Storyboard.TargetProperty="Y"
                                                 From="0" To="160" Duration="0:0:22"/>
                                <DoubleAnimation Storyboard.TargetName="bgT2" Storyboard.TargetProperty="X"
                                                 From="0" To="-260" Duration="0:0:24"/>
                                <DoubleAnimation Storyboard.TargetName="bgT2" Storyboard.TargetProperty="Y"
                                                 From="0" To="-180" Duration="0:0:20"/>
                                <DoubleAnimation Storyboard.TargetName="bgT3" Storyboard.TargetProperty="X"
                                                 From="0" To="180" Duration="0:0:26"/>
                                <DoubleAnimation Storyboard.TargetName="bgT3" Storyboard.TargetProperty="Y"
                                                 From="0" To="-220" Duration="0:0:28"/>
                            </Storyboard>
                        </BeginStoryboard>
                    </EventTrigger>
                </Canvas.Triggers>
            </Canvas>

            <!-- TOAST OVERLAY -->
            <StackPanel x:Name="toastHost" Grid.Row="1" Panel.ZIndex="1000"
                        VerticalAlignment="Top" HorizontalAlignment="Right"
                        Margin="0,18,18,0" Background="Transparent"/>

            <!-- TITLE BAR -->
            <Border x:Name="titleBar" Grid.Row="0" CornerRadius="14,14,0,0" Padding="20,0">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                        <GradientStop Color="#161208" Offset="0"/>
                        <GradientStop Color="#0d0d0d" Offset="0.55"/>
                        <GradientStop Color="#0d0d0d" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <Grid>
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Border Width="40" Height="40" CornerRadius="8" Margin="0,0,12,0"
                                Background="#0a0a0a" BorderBrush="#3a2e10" BorderThickness="1">
                            <Image x:Name="imgLogo" Width="34" Height="34"
                                   RenderOptions.BitmapScalingMode="HighQuality"/>
                        </Border>
                        <StackPanel VerticalAlignment="Center">
                            <TextBlock Text="SLAVONSKA RAVNICA" FontSize="15" FontWeight="Bold"
                                       Foreground="#F5C518" FontFamily="Segoe UI"
                                       Padding="0" Margin="0">
                                <TextBlock.Effect>
                                    <DropShadowEffect Color="#F5C518" BlurRadius="8" ShadowDepth="0" Opacity="0.35"/>
                                </TextBlock.Effect>
                            </TextBlock>
                            <TextBlock Text="FS25 LAUNCHER" FontSize="9" FontWeight="SemiBold"
                                       Foreground="#777" FontFamily="Segoe UI" Margin="0,1,0,0"/>
                        </StackPanel>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Button x:Name="btnLinkWeb" Style="{StaticResource IconBtn}" Margin="0,0,6,0"
                                Content="&#xE774;" ToolTip="Otvori web stranicu (slavonska-ravnica.com)"/>
                        <Button x:Name="btnLinkDiscord" Style="{StaticResource IconBtn}" Margin="0,0,12,0"
                                Content="&#xE8BD;" ToolTip="Otvori Discord server"/>
                        <Button x:Name="btnUpdateNotify" Content="Nova verzija!" Visibility="Collapsed"
                                Style="{StaticResource BtnUpdate}" Margin="0,0,12,0"/>
                        <Border x:Name="licenseBadge" Visibility="Collapsed" CornerRadius="4"
                                Background="#13301f" BorderBrush="#30A46C" BorderThickness="1"
                                Padding="8,3" Margin="0,0,10,0" VerticalAlignment="Center"
                                ToolTip="Licenca aktivirana na ovom racunalu">
                            <TextBlock x:Name="txtLicenseBadge" Text="LICENCA" FontSize="9"
                                       FontWeight="Bold" Foreground="#30A46C" FontFamily="Segoe UI"/>
                        </Border>
                        <Ellipse x:Name="statusDot" Width="8" Height="8" Fill="#E5484D" Margin="0,0,6,0"/>
                        <TextBlock x:Name="txtStatus" Text="OFFLINE" FontSize="10"
                                   FontWeight="Bold" Foreground="#E5484D" Margin="0,0,16,0"
                                   VerticalAlignment="Center" FontFamily="Segoe UI"/>
                        <Button x:Name="btnFullscreen" Style="{StaticResource IconBtn}" Margin="0,0,4,0"
                                Content="&#xE740;" FontSize="12" ToolTip="Cijeli zaslon (F11)"/>
                        <Button x:Name="btnMinimize" Style="{StaticResource IconBtn}" Margin="0,0,4,0"
                                Content="&#xE921;" FontSize="12" ToolTip="Minimiziraj"/>
                        <Button x:Name="btnClose" Style="{StaticResource IconBtn}"
                                Content="&#xE8BB;" FontSize="12" ToolTip="Zatvori"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- CONTENT -->
            <Grid Grid.Row="1">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="218"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <!-- SIDEBAR -->
                <Border Grid.Column="0" BorderBrush="#1a1a1a" BorderThickness="0,0,1,0">
                    <Border.Background>
                        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                            <GradientStop Color="#101010" Offset="0"/>
                            <GradientStop Color="#0a0a0a" Offset="1"/>
                        </LinearGradientBrush>
                    </Border.Background>
                    <DockPanel>
                        <!-- Server Selector -->
                        <StackPanel DockPanel.Dock="Top" Margin="8,12,8,0">
                            <Grid Margin="10,0,0,6">
                                <TextBlock Text="SERVER" FontSize="9" Foreground="#555" FontWeight="Bold"
                                           FontFamily="Segoe UI"/>
                                <Button x:Name="btnAddCustomServer" Content="+ Novi" FontSize="10"
                                        Style="{StaticResource BtnFlat}" Padding="6,2" Margin="0,-4,8,0"
                                        HorizontalAlignment="Right" Foreground="#F5C518"
                                        ToolTip="Dodaj svoj server (samo lokalno, nece se sinkronizirati)"/>
                            </Grid>
                            <StackPanel x:Name="serverButtonsPanel"/>
                        </StackPanel>

                        <Border DockPanel.Dock="Top" Height="1" Background="#1a1a1a" Margin="12,10,12,6"/>

                        <!-- Nav -->
                        <StackPanel DockPanel.Dock="Top" Margin="8,0">
                            <TextBlock Text="RADNI PROSTOR" Style="{StaticResource NavSection}"/>
                            <RadioButton x:Name="navDash" Content="Nadzorna ploca"
                                         Style="{StaticResource NavBtn}" IsChecked="True" GroupName="nav"
                                         ToolTip="Status servera, igraci, brzi ulaz u igru"/>
                            <RadioButton x:Name="navMods" Content="Upravitelj modova"
                                         Style="{StaticResource NavBtn}" GroupName="nav"
                                         ToolTip="Grid modova, pretraga, sync i download"/>
                            <RadioButton x:Name="navIgra" Content="Konfiguriraj save"
                                         Style="{StaticResource NavBtn}" GroupName="nav"
                                         ToolTip="Savegame slotovi i mod profili (FS25)"/>
                            <RadioButton x:Name="navMpFolders" Content="Multiplayer folderi"
                                         Style="{StaticResource NavBtn}" GroupName="nav"
                                         ToolTip="Dedicated mod folderi po serveru (Phase 1)"/>
                            <TextBlock Text="BIBLIOTEKA" Style="{StaticResource NavSection}" Margin="14,14,0,4"/>
                            <Button x:Name="btnNavFavorites" Style="{StaticResource BtnFlat}"
                                    HorizontalContentAlignment="Stretch" Foreground="#888"
                                    Margin="8,0,8,2" Padding="18,10"
                                    ToolTip="Favoriti u Upravitelju modova">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="&#x2605; Favoriti" VerticalAlignment="Center"/>
                                    <Border Grid.Column="1" Background="#222" CornerRadius="8" Padding="6,2" Margin="8,0,0,0">
                                        <TextBlock x:Name="txtNavFavBadge" Text="0" FontSize="9" Foreground="#F5C518"/>
                                    </Border>
                                </Grid>
                            </Button>
                            <Button x:Name="btnNavLibraryMods" Style="{StaticResource BtnFlat}"
                                    HorizontalContentAlignment="Stretch" Foreground="#888"
                                    Margin="8,0,8,2" Padding="18,10"
                                    ToolTip="Isti pregled kao Upravitelj modova">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="Modovi" VerticalAlignment="Center"/>
                                    <Border Grid.Column="1" Background="#222" CornerRadius="8" Padding="6,2" Margin="8,0,0,0">
                                        <TextBlock x:Name="txtNavModsBadge" Text="0" FontSize="9" Foreground="#F5C518"/>
                                    </Border>
                                </Grid>
                            </Button>
                            <Button x:Name="btnNavMaps" Style="{StaticResource BtnFlat}"
                                    HorizontalContentAlignment="Stretch" Foreground="#666"
                                    Margin="8,0,8,2" Padding="18,8" IsEnabled="False"
                                    ToolTip="Mape iz lokalne biblioteke (uskoro)">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="Mape" VerticalAlignment="Center"/>
                                    <Border Grid.Column="1" Background="#1a1a1a" CornerRadius="8" Padding="6,2" Margin="8,0,0,0">
                                        <TextBlock x:Name="txtNavMapsBadge" Text="0" FontSize="9" Foreground="#666"/>
                                    </Border>
                                </Grid>
                            </Button>
                            <Button x:Name="btnNavDlc" Style="{StaticResource BtnFlat}"
                                    HorizontalContentAlignment="Stretch" Foreground="#666"
                                    Margin="8,0,8,2" Padding="18,8" IsEnabled="False"
                                    ToolTip="DLC prepoznavanje (uskoro)">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="DLC" VerticalAlignment="Center"/>
                                    <Border Grid.Column="1" Background="#1a1a1a" CornerRadius="8" Padding="6,2" Margin="8,0,0,0">
                                        <TextBlock x:Name="txtNavDlcBadge" Text="0" FontSize="9" Foreground="#666"/>
                                    </Border>
                                </Grid>
                            </Button>
                            <Button x:Name="btnNavScripts" Style="{StaticResource BtnFlat}"
                                    HorizontalContentAlignment="Stretch" Foreground="#666"
                                    Margin="8,0,8,6" Padding="18,8" IsEnabled="False"
                                    ToolTip="Skripte iz lokalne biblioteke (uskoro)">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="Skripte" VerticalAlignment="Center"/>
                                    <Border Grid.Column="1" Background="#1a1a1a" CornerRadius="8" Padding="6,2" Margin="8,0,0,0">
                                        <TextBlock x:Name="txtNavScriptsBadge" Text="0" FontSize="9" Foreground="#666"/>
                                    </Border>
                                </Grid>
                            </Button>
                            <TextBlock Text="ZBIRKE" Style="{StaticResource NavSection}" Margin="14,8,0,4"/>
                            <Button x:Name="btnNavNewCollection" Content="+ Nova zbirka (uskoro)"
                                    Style="{StaticResource BtnFlat}" HorizontalContentAlignment="Left"
                                    Foreground="#444" Margin="8,0,8,6" Padding="18,8" IsEnabled="False"/>
                            <Border Height="1" Background="#1a1a1a" Margin="12,4,12,8"/>
                            <RadioButton x:Name="navSettings" Content="Postavke"
                                         Style="{StaticResource NavBtn}" GroupName="nav"
                                         ToolTip="Putanje igre, intro, teme, sync interval"/>
                            <RadioButton x:Name="navLog" Content="Log" Visibility="Collapsed"
                                         Style="{StaticResource NavBtn}" GroupName="nav"
                                         ToolTip="Detaljni log launcher operacija (admin only)"/>
                        </StackPanel>

                        <!-- Footer -->
                        <StackPanel DockPanel.Dock="Bottom" Margin="8,0,8,10">
                            <Border Height="1" Background="#1a1a1a" Margin="4,0,4,8"/>

                            <!-- Update Notification -->
                            <Border x:Name="updateBanner" Background="#1a2a1a" CornerRadius="8"
                                    Padding="12,10" Margin="4,0,4,10" Visibility="Collapsed"
                                    BorderBrush="#30A46C" BorderThickness="1">
                                <StackPanel>
                                    <TextBlock x:Name="txtUpdateInfo" Text="Nova verzija dostupna!"
                                               FontSize="11" FontWeight="Bold" Foreground="#30A46C"
                                               FontFamily="Segoe UI" Margin="0,0,0,6"/>
                                    <Button x:Name="btnUpdateNow" Content="Azuriraj"
                                            Style="{StaticResource BtnUpdate}" HorizontalAlignment="Stretch"/>
                                </StackPanel>
                            </Border>

                            <!-- Quick Links premjesteni u titlebar -->

                            <Button x:Name="btnAdminToggle" Content="Igrac"
                                    Style="{StaticResource BtnFlat}" HorizontalContentAlignment="Left"
                                    Foreground="#555" Margin="0,0,0,6"/>
                            <TextBlock x:Name="txtVersion" Text="v1.0.0" FontSize="10"
                                       Foreground="#777" FontFamily="Segoe UI" Margin="10,0"/>
                            <TextBlock Text="by Anthony" FontSize="10"
                                       Foreground="#666" FontFamily="Segoe UI" Margin="10,2,0,0"/>
                        </StackPanel>
                    </DockPanel>
                </Border>

                <!-- PAGES -->
                <Grid Grid.Column="1" Background="#111">
                    <!-- Tractor Watermark Background -->
                    <Canvas IsHitTestVisible="False" Opacity="0.03">
                        <Path Canvas.Left="80" Canvas.Top="120" Fill="#F5C518" Data="M 120 200 L 160 120 L 200 120 L 240 80 L 320 80 L 360 120 L 400 120 L 400 200 L 380 200 A 40 40 0 1 1 300 200 L 220 200 A 40 40 0 1 1 140 200 Z M 310 200 A 30 30 0 1 0 370 200 A 30 30 0 1 0 310 200 Z M 150 200 A 30 30 0 1 0 210 200 A 30 30 0 1 0 150 200 Z M 250 100 L 250 140 L 350 140 L 350 100 Z"/>
                        <Path Canvas.Left="80" Canvas.Top="120" Fill="#F5C518" Data="M 100 160 L 120 160 L 120 120 L 160 120 L 160 100 L 100 100 Z"/>
                        <Path Canvas.Left="80" Canvas.Top="290" Fill="#F5C518" Data="M 60 20 L 440 20 L 440 30 L 60 30 Z M 80 30 L 80 50 L 100 50 L 100 30 Z M 200 30 L 200 50 L 220 50 L 220 30 Z M 320 30 L 320 50 L 340 50 L 340 30 Z M 400 30 L 400 50 L 420 50 L 420 30 Z"/>
                    </Canvas>

                    <!-- PAGE: DASHBOARD -->
                    <ScrollViewer x:Name="pageDash" VerticalScrollBarVisibility="Auto">
                        <StackPanel Margin="32,28,32,32">
                            <Grid Margin="0,0,0,22">
                                <StackPanel>
                                    <TextBlock Text="Dashboard" FontSize="26" FontWeight="Bold"
                                               Foreground="#f0f0f0" FontFamily="Segoe UI"/>
                                    <TextBlock Text="Vise servera, SHA sync modova, licenca i brzi launch"
                                               FontSize="12" Foreground="#666"
                                               FontFamily="Segoe UI" Margin="0,4,0,0"/>
                                </StackPanel>
                                <Button x:Name="btnRefreshStatus" Content="Osvjezi"
                                        Style="{StaticResource BtnGhost}" HorizontalAlignment="Right"
                                        VerticalAlignment="Top" FontSize="11"
                                        ToolTip="Osvjezi server status, mapu, igrace"/>
                            </Grid>

                            <!-- HERO: Server status + Udi gumb -->
                            <Border CornerRadius="14" Padding="0" Margin="0,0,0,16"
                                    BorderThickness="1">
                                <Border.Background>
                                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                        <GradientStop Color="#1a1408" Offset="0"/>
                                        <GradientStop Color="#161616" Offset="0.4"/>
                                        <GradientStop Color="#0f0f0f" Offset="1"/>
                                    </LinearGradientBrush>
                                </Border.Background>
                                <Border.BorderBrush>
                                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                        <GradientStop Color="#3a2e10" Offset="0"/>
                                        <GradientStop Color="#1f1f1f" Offset="1"/>
                                    </LinearGradientBrush>
                                </Border.BorderBrush>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="280"/>
                                    </Grid.ColumnDefinitions>

                                    <!-- LIJEVA STRANA: server info -->
                                    <StackPanel Grid.Column="0" Margin="26,22,16,22">
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
                                            <Border Width="14" Height="14" CornerRadius="7"
                                                    VerticalAlignment="Center" Margin="0,0,12,0">
                                                <Border.Background>
                                                    <SolidColorBrush x:Name="dashStatusBrush" Color="#E5484D"/>
                                                </Border.Background>
                                                <Border.Effect>
                                                    <DropShadowEffect x:Name="dashStatusGlow" Color="#E5484D" BlurRadius="12" ShadowDepth="0" Opacity="0.7"/>
                                                </Border.Effect>
                                                <Border.Triggers>
                                                    <EventTrigger RoutedEvent="Border.Loaded">
                                                        <BeginStoryboard>
                                                            <Storyboard RepeatBehavior="Forever">
                                                                <DoubleAnimation Storyboard.TargetName="dashStatusGlow"
                                                                                 Storyboard.TargetProperty="BlurRadius"
                                                                                 From="12" To="22" Duration="0:0:1.6"
                                                                                 AutoReverse="True">
                                                                    <DoubleAnimation.EasingFunction>
                                                                        <SineEase EasingMode="EaseInOut"/>
                                                                    </DoubleAnimation.EasingFunction>
                                                                </DoubleAnimation>
                                                                <DoubleAnimation Storyboard.TargetName="dashStatusGlow"
                                                                                 Storyboard.TargetProperty="Opacity"
                                                                                 From="0.55" To="0.95" Duration="0:0:1.6"
                                                                                 AutoReverse="True">
                                                                    <DoubleAnimation.EasingFunction>
                                                                        <SineEase EasingMode="EaseInOut"/>
                                                                    </DoubleAnimation.EasingFunction>
                                                                </DoubleAnimation>
                                                            </Storyboard>
                                                        </BeginStoryboard>
                                                    </EventTrigger>
                                                </Border.Triggers>
                                            </Border>
                                            <Ellipse x:Name="statusDotBig" Visibility="Collapsed"/>
                                            <TextBlock x:Name="txtServerName" Text="Ucitavam..."
                                                       FontSize="22" FontWeight="Bold" Foreground="White"
                                                       FontFamily="Segoe UI"/>
                                        </StackPanel>
                                        <Grid Margin="26,8,0,0">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="Auto"/>
                                                <ColumnDefinition Width="20"/>
                                                <ColumnDefinition Width="Auto"/>
                                                <ColumnDefinition Width="20"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <StackPanel Grid.Column="0">
                                                <TextBlock Text="MAPA" FontSize="9" Foreground="#666"
                                                           FontWeight="Bold" FontFamily="Segoe UI"/>
                                                <TextBlock x:Name="txtServerMap" Text="-" FontSize="13"
                                                           Foreground="#ddd" FontFamily="Segoe UI" Margin="0,2,0,0"/>
                                            </StackPanel>
                                            <StackPanel Grid.Column="2">
                                                <TextBlock Text="IGRACI" FontSize="9" Foreground="#666"
                                                           FontWeight="Bold" FontFamily="Segoe UI"/>
                                                <TextBlock x:Name="txtServerPlayers" Text="-" FontSize="13"
                                                           Foreground="#ddd" FontFamily="Segoe UI" Margin="0,2,0,0"/>
                                            </StackPanel>
                                            <StackPanel Grid.Column="4">
                                                <TextBlock Text="PING" FontSize="9" Foreground="#666"
                                                           FontWeight="Bold" FontFamily="Segoe UI"/>
                                                <TextBlock x:Name="txtServerPing" Text="-" FontSize="13"
                                                           Foreground="#30A46C" FontFamily="Segoe UI" Margin="0,2,0,0"
                                                           FontWeight="SemiBold"/>
                                            </StackPanel>
                                        </Grid>
                                        <Border Background="#0d0d0d" CornerRadius="6" Padding="10,7"
                                                Margin="26,12,0,0" BorderBrush="#1a1a1a" BorderThickness="1">
                                            <Grid>
                                                <TextBlock x:Name="txtPlayerList" Text="Nema igraca online"
                                                           FontSize="11" Foreground="#666"
                                                           FontFamily="Segoe UI" TextWrapping="Wrap"
                                                           Visibility="Visible"/>
                                                <ItemsControl x:Name="lstPlayerChips" Visibility="Collapsed">
                                                    <ItemsControl.ItemsPanel>
                                                        <ItemsPanelTemplate>
                                                            <WrapPanel/>
                                                        </ItemsPanelTemplate>
                                                    </ItemsControl.ItemsPanel>
                                                    <ItemsControl.ItemTemplate>
                                                        <DataTemplate>
                                                            <Border Background="#1a1408" CornerRadius="12"
                                                                    BorderBrush="#3a2e10" BorderThickness="1"
                                                                    Padding="10,5" Margin="0,3,6,3" Cursor="Hand">
                                                                <Border.ToolTip>
                                                                    <ToolTip Background="#0a0a0a" BorderBrush="#3a2e10"
                                                                             BorderThickness="1" Padding="14"
                                                                             Foreground="#eee" HasDropShadow="True">
                                                                        <StackPanel MinWidth="220">
                                                                            <Grid>
                                                                                <Grid.ColumnDefinitions>
                                                                                    <ColumnDefinition Width="Auto"/>
                                                                                    <ColumnDefinition Width="*"/>
                                                                                </Grid.ColumnDefinitions>
                                                                                <Border Grid.Column="0" Width="32" Height="32"
                                                                                        CornerRadius="16" Background="#F5C518"
                                                                                        Margin="0,0,12,0" VerticalAlignment="Top">
                                                                                    <TextBlock Text="{Binding Initial}"
                                                                                               Foreground="#111" FontWeight="Bold"
                                                                                               FontSize="14" HorizontalAlignment="Center"
                                                                                               VerticalAlignment="Center"
                                                                                               FontFamily="Segoe UI"/>
                                                                                </Border>
                                                                                <StackPanel Grid.Column="1">
                                                                                    <TextBlock Text="{Binding Name}"
                                                                                               FontSize="13" FontWeight="Bold"
                                                                                               Foreground="#F5C518"
                                                                                               FontFamily="Segoe UI"/>
                                                                                    <TextBlock Text="{Binding DiscordTag}"
                                                                                               FontSize="11" Foreground="#9d8df5"
                                                                                               FontFamily="Segoe UI"
                                                                                               Visibility="{Binding DiscordVisible}"/>
                                                                                </StackPanel>
                                                                            </Grid>
                                                                            <Border Height="1" Background="#2a2a2a" Margin="0,10,0,8"/>
                                                                            <Grid>
                                                                                <Grid.ColumnDefinitions>
                                                                                    <ColumnDefinition Width="Auto"/>
                                                                                    <ColumnDefinition Width="*"/>
                                                                                </Grid.ColumnDefinitions>
                                                                                <TextBlock Grid.Column="0" Text="Online:"
                                                                                           FontSize="10" Foreground="#888"
                                                                                           FontFamily="Segoe UI" Margin="0,0,8,0"/>
                                                                                <TextBlock Grid.Column="1" Text="{Binding UptimeStr}"
                                                                                           FontSize="10" Foreground="#ddd"
                                                                                           FontFamily="Segoe UI"/>
                                                                            </Grid>
                                                                            <Grid Margin="0,3,0,0">
                                                                                <Grid.ColumnDefinitions>
                                                                                    <ColumnDefinition Width="Auto"/>
                                                                                    <ColumnDefinition Width="*"/>
                                                                                </Grid.ColumnDefinitions>
                                                                                <TextBlock Grid.Column="0" Text="Uloga:"
                                                                                           FontSize="10" Foreground="#888"
                                                                                           FontFamily="Segoe UI" Margin="0,0,8,0"/>
                                                                                <TextBlock Grid.Column="1" Text="{Binding RoleStr}"
                                                                                           FontSize="10"
                                                                                           Foreground="{Binding RoleColor}"
                                                                                           FontFamily="Segoe UI" FontWeight="SemiBold"/>
                                                                            </Grid>
                                                                        </StackPanel>
                                                                    </ToolTip>
                                                                </Border.ToolTip>
                                                                <StackPanel Orientation="Horizontal">
                                                                    <Border Width="6" Height="6" CornerRadius="3"
                                                                            Background="#30A46C" Margin="0,0,7,0"
                                                                            VerticalAlignment="Center">
                                                                        <Border.Effect>
                                                                            <DropShadowEffect Color="#30A46C" BlurRadius="6" ShadowDepth="0" Opacity="1"/>
                                                                        </Border.Effect>
                                                                    </Border>
                                                                    <TextBlock Text="{Binding Name}" FontSize="11"
                                                                               Foreground="#F5C518" FontFamily="Segoe UI"
                                                                               VerticalAlignment="Center" FontWeight="SemiBold"/>
                                                                    <TextBlock Text=" ADMIN" FontSize="8" FontWeight="Bold"
                                                                               Foreground="#E5484D" FontFamily="Segoe UI"
                                                                               VerticalAlignment="Center" Margin="6,0,0,0"
                                                                               Visibility="{Binding AdminVisible}"/>
                                                                </StackPanel>
                                                            </Border>
                                                        </DataTemplate>
                                                    </ItemsControl.ItemTemplate>
                                                </ItemsControl>
                                            </Grid>
                                        </Border>
                                    </StackPanel>

                                    <!-- DESNA STRANA: udi gumb -->
                                    <Border Grid.Column="1" Background="#0a0a0a" CornerRadius="0,14,14,0"
                                            BorderBrush="#1a1a1a" BorderThickness="1,0,0,0" Padding="22">
                                        <StackPanel VerticalAlignment="Center">
                                            <TextBlock Text="BRZI LAUNCH" FontSize="9" Foreground="#666"
                                                       FontWeight="Bold" Margin="0,0,0,6" FontFamily="Segoe UI"/>
                                            <TextBlock Text="Provjera SHA-256, sync modova i pokretanje FS25" FontSize="11"
                                                       Foreground="#888" FontFamily="Segoe UI" Margin="0,0,0,8"
                                                       TextWrapping="Wrap"/>
                                            <TextBlock Text="MOD FOLDER" FontSize="9" Foreground="#666"
                                                       FontWeight="Bold" Margin="0,0,0,4" FontFamily="Segoe UI"/>
                                            <ComboBox x:Name="cmbMpFolderQuick" Margin="0,0,0,10"
                                                      Background="#1a1a1a" Foreground="#eee"
                                                      BorderBrush="#333" Padding="8,6" FontFamily="Segoe UI"
                                                      ToolTip="Odaberi multiplayer mod folder prije ulaska na server"/>
                                            <Button x:Name="btnJoinServer" Content="Udi na Server"
                                                    Style="{StaticResource BtnPrimary}" HorizontalAlignment="Stretch"
                                                    Padding="14,12" FontSize="14"
                                                    ToolTip="1) Provjeri verziju  2) Sync modove (pita za download ako fali)  3) Pokreni FS25"/>
                                            <TextBlock x:Name="txtJoinStatus" Text="" FontSize="11" Foreground="#F5C518"
                                                       FontFamily="Segoe UI" Margin="0,8,0,0" TextWrapping="Wrap"
                                                       HorizontalAlignment="Center" Visibility="Collapsed"/>
                                            <Button x:Name="btnSyncMods" Content="Samo provjeri modove"
                                                    Style="{StaticResource BtnFlat}" HorizontalAlignment="Stretch"
                                                    Margin="0,10,0,0" FontSize="11" Foreground="#888"
                                                    ToolTip="Brza usporedba bez pokretanja igre"/>
                                        </StackPanel>
                                    </Border>
                                </Grid>
                            </Border>

                            <!-- Stats Row -->
                            <Grid Margin="0,0,0,16">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="12"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="12"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="12"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <Border Grid.Column="0" Background="#161616" CornerRadius="10"
                                        Padding="18,16" BorderBrush="#222" BorderThickness="1">
                                    <StackPanel>
                                        <TextBlock Text="MOJI MODOVI" FontSize="9" Foreground="#666"
                                                   FontWeight="Bold" FontFamily="Segoe UI" Margin="0,0,0,4"/>
                                        <TextBlock x:Name="txtMyModCount" Text="-" FontSize="32"
                                                   FontWeight="Bold" Foreground="#F5C518"
                                                   FontFamily="Segoe UI"/>
                                    </StackPanel>
                                </Border>

                                <Border Grid.Column="2" Background="#161616" CornerRadius="10"
                                        Padding="18,16" BorderBrush="#222" BorderThickness="1">
                                    <StackPanel>
                                        <TextBlock Text="SERVER" FontSize="9" Foreground="#666"
                                                   FontWeight="Bold" FontFamily="Segoe UI" Margin="0,0,0,4"/>
                                        <TextBlock x:Name="txtServerModCount" Text="-" FontSize="32"
                                                   FontWeight="Bold" Foreground="#F5C518"
                                                   FontFamily="Segoe UI"/>
                                    </StackPanel>
                                </Border>

                                <Border Grid.Column="4" Background="#161616" CornerRadius="10"
                                        Padding="18,16" BorderBrush="#222" BorderThickness="1">
                                    <StackPanel>
                                        <TextBlock Text="FALI TI" FontSize="9" Foreground="#666"
                                                   FontWeight="Bold" FontFamily="Segoe UI" Margin="0,0,0,4"/>
                                        <TextBlock x:Name="txtMissingCount" Text="-" FontSize="32"
                                                   FontWeight="Bold" Foreground="#E5484D"
                                                   FontFamily="Segoe UI"/>
                                    </StackPanel>
                                </Border>

                                <Border Grid.Column="6" Background="#161616" CornerRadius="10"
                                        Padding="18,16" BorderBrush="#222" BorderThickness="1">
                                    <StackPanel>
                                        <TextBlock Text="VELICINA" FontSize="9" Foreground="#666"
                                                   FontWeight="Bold" FontFamily="Segoe UI" Margin="0,0,0,4"/>
                                        <TextBlock x:Name="txtModSizeTotal" Text="-" FontSize="32"
                                                   FontWeight="Bold" Foreground="#9d8df5"
                                                   FontFamily="Segoe UI"/>
                                    </StackPanel>
                                </Border>
                            </Grid>

                            <!-- Activity / sync info -->
                            <Border Background="#161616" CornerRadius="10" Padding="16,12"
                                    BorderBrush="#1e1e1e" BorderThickness="1">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="AKTIVNOST" FontSize="9"
                                               Foreground="#666" FontWeight="Bold"
                                               FontFamily="Segoe UI" VerticalAlignment="Center"
                                               Margin="0,0,16,0"/>
                                    <TextBlock x:Name="txtLastSync" Grid.Column="1" Text="Zadnji sync: nikad"
                                               FontSize="12" Foreground="#aaa" FontFamily="Segoe UI"
                                               VerticalAlignment="Center"/>
                                </Grid>
                            </Border>

                            <!-- Bottom row: Fali modovi + Activity feed -->
                            <Grid Margin="0,16,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="14"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <!-- Fali modovi panel -->
                                <Border Grid.Column="0" Background="#161616" CornerRadius="12"
                                        Padding="18" BorderBrush="#222" BorderThickness="1">
                                    <Border.Effect>
                                        <DropShadowEffect Color="Black" BlurRadius="14" ShadowDepth="0" Opacity="0.4"/>
                                    </Border.Effect>
                                    <StackPanel>
                                        <Grid Margin="0,0,0,10">
                                            <TextBlock Text="FALI MODOVI" FontSize="10" Foreground="#888"
                                                       FontWeight="Bold" FontFamily="Segoe UI"/>
                                            <TextBlock x:Name="txtMissingHint" Text="" FontSize="10"
                                                       Foreground="#666" FontFamily="Segoe UI"
                                                       HorizontalAlignment="Right"/>
                                        </Grid>
                                        <ItemsControl x:Name="lstMissingPreview" Height="150">
                                            <ItemsControl.ItemTemplate>
                                                <DataTemplate>
                                                    <Border Background="#0d0d0d" CornerRadius="6"
                                                            Padding="10,7" Margin="0,0,0,4"
                                                            BorderBrush="#2a1a08" BorderThickness="1"
                                                            ToolTip="{Binding ToolTipText}"
                                                            RenderTransformOrigin="0,0.5">
                                                        <Border.RenderTransform>
                                                            <TranslateTransform X="-20"/>
                                                        </Border.RenderTransform>
                                                        <Border.Triggers>
                                                            <EventTrigger RoutedEvent="Border.Loaded">
                                                                <BeginStoryboard>
                                                                    <Storyboard>
                                                                        <DoubleAnimation Storyboard.TargetProperty="(UIElement.Opacity)"
                                                                                         From="0" To="1" Duration="0:0:0.35"/>
                                                                        <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)"
                                                                                         From="-20" To="0" Duration="0:0:0.35">
                                                                            <DoubleAnimation.EasingFunction>
                                                                                <CubicEase EasingMode="EaseOut"/>
                                                                            </DoubleAnimation.EasingFunction>
                                                                        </DoubleAnimation>
                                                                    </Storyboard>
                                                                </BeginStoryboard>
                                                            </EventTrigger>
                                                        </Border.Triggers>
                                                        <Grid>
                                                            <Grid.ColumnDefinitions>
                                                                <ColumnDefinition Width="Auto"/>
                                                                <ColumnDefinition Width="*"/>
                                                                <ColumnDefinition Width="Auto"/>
                                                            </Grid.ColumnDefinitions>
                                                            <Border Grid.Column="0" Width="6" Height="6"
                                                                    CornerRadius="3" Background="#E5484D"
                                                                    Margin="0,0,10,0" VerticalAlignment="Center">
                                                                <Border.Effect>
                                                                    <DropShadowEffect Color="#E5484D" BlurRadius="8" ShadowDepth="0" Opacity="0.9"/>
                                                                </Border.Effect>
                                                                <Border.Triggers>
                                                                    <EventTrigger RoutedEvent="Border.Loaded">
                                                                        <BeginStoryboard>
                                                                            <Storyboard RepeatBehavior="Forever">
                                                                                <DoubleAnimation Storyboard.TargetProperty="Opacity"
                                                                                                 From="1" To="0.4" Duration="0:0:1.2"
                                                                                                 AutoReverse="True"/>
                                                                            </Storyboard>
                                                                        </BeginStoryboard>
                                                                    </EventTrigger>
                                                                </Border.Triggers>
                                                            </Border>
                                                            <TextBlock Grid.Column="1" Text="{Binding Name}"
                                                                       FontSize="11" Foreground="#ddd"
                                                                       FontFamily="Segoe UI" VerticalAlignment="Center"
                                                                       TextTrimming="CharacterEllipsis"/>
                                                            <TextBlock Grid.Column="2" Text="{Binding Status}"
                                                                       FontSize="10" Foreground="#E5484D"
                                                                       FontWeight="Bold" FontFamily="Segoe UI"
                                                                       VerticalAlignment="Center"/>
                                                        </Grid>
                                                    </Border>
                                                </DataTemplate>
                                            </ItemsControl.ItemTemplate>
                                        </ItemsControl>
                                        <Button x:Name="btnGoToMods" Content="Otvori sve modove"
                                                Style="{StaticResource BtnGhost}" HorizontalAlignment="Stretch"
                                                Margin="0,8,0,0" FontSize="11"/>
                                    </StackPanel>
                                </Border>

                                <!-- Activity feed -->
                                <Border Grid.Column="2" Background="#161616" CornerRadius="12"
                                        Padding="18" BorderBrush="#222" BorderThickness="1">
                                    <Border.Effect>
                                        <DropShadowEffect Color="Black" BlurRadius="14" ShadowDepth="0" Opacity="0.4"/>
                                    </Border.Effect>
                                    <StackPanel>
                                        <Grid Margin="0,0,0,10">
                                            <TextBlock Text="AKTIVNOST" FontSize="10" Foreground="#888"
                                                       FontWeight="Bold" FontFamily="Segoe UI"/>
                                            <Border Background="#1a1408" CornerRadius="3" Padding="6,2"
                                                    HorizontalAlignment="Right">
                                                <StackPanel Orientation="Horizontal">
                                                    <Border Width="6" Height="6" CornerRadius="3"
                                                            Background="#F5C518" Margin="0,0,5,0"
                                                            VerticalAlignment="Center">
                                                        <Border.Effect>
                                                            <DropShadowEffect Color="#F5C518" BlurRadius="6" ShadowDepth="0" Opacity="1"/>
                                                        </Border.Effect>
                                                        <Border.Triggers>
                                                            <EventTrigger RoutedEvent="Border.Loaded">
                                                                <BeginStoryboard>
                                                                    <Storyboard RepeatBehavior="Forever">
                                                                        <DoubleAnimation Storyboard.TargetProperty="Opacity"
                                                                                         From="1" To="0.3" Duration="0:0:1"
                                                                                         AutoReverse="True"/>
                                                                    </Storyboard>
                                                                </BeginStoryboard>
                                                            </EventTrigger>
                                                        </Border.Triggers>
                                                    </Border>
                                                    <TextBlock Text="LIVE" FontSize="8" FontWeight="Bold"
                                                               Foreground="#F5C518" FontFamily="Segoe UI"
                                                               VerticalAlignment="Center"/>
                                                </StackPanel>
                                            </Border>
                                        </Grid>
                                        <ItemsControl x:Name="lstActivityFeed" Height="186">
                                            <ItemsControl.ItemTemplate>
                                                <DataTemplate>
                                                    <Grid Margin="0,0,0,6" Opacity="0"
                                                          RenderTransformOrigin="0,0.5">
                                                        <Grid.RenderTransform>
                                                            <TranslateTransform Y="-8"/>
                                                        </Grid.RenderTransform>
                                                        <Grid.Triggers>
                                                            <EventTrigger RoutedEvent="FrameworkElement.Loaded">
                                                                <BeginStoryboard>
                                                                    <Storyboard>
                                                                        <DoubleAnimation Storyboard.TargetProperty="(UIElement.Opacity)"
                                                                                         From="0" To="1" Duration="0:0:0.4"/>
                                                                        <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)"
                                                                                         From="-8" To="0" Duration="0:0:0.4">
                                                                            <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                                                                        </DoubleAnimation>
                                                                    </Storyboard>
                                                                </BeginStoryboard>
                                                            </EventTrigger>
                                                        </Grid.Triggers>
                                                        <Grid.ColumnDefinitions>
                                                            <ColumnDefinition Width="50"/>
                                                            <ColumnDefinition Width="*"/>
                                                        </Grid.ColumnDefinitions>
                                                        <TextBlock Grid.Column="0" Text="{Binding Time}"
                                                                   FontSize="10" Foreground="#666"
                                                                   FontFamily="Consolas" VerticalAlignment="Top"/>
                                                        <TextBlock Grid.Column="1" Text="{Binding Message}"
                                                                   FontSize="11" Foreground="#bbb"
                                                                   FontFamily="Segoe UI" TextWrapping="Wrap"/>
                                                    </Grid>
                                                </DataTemplate>
                                            </ItemsControl.ItemTemplate>
                                        </ItemsControl>
                                    </StackPanel>
                                </Border>
                            </Grid>
                        </StackPanel>
                    </ScrollViewer>

                    <!-- PAGE: MODOVI -->
                    <Grid x:Name="pageMods" Visibility="Collapsed" Margin="32,28,32,28">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <Grid Grid.Row="0" Margin="0,0,0,18">
                            <StackPanel>
                                <TextBlock Text="Upravitelj modova" FontSize="26" FontWeight="Bold"
                                           Foreground="#f0f0f0" FontFamily="Segoe UI"/>
                                <TextBlock x:Name="txtModSubtitle" Text="Grid, pretraga i sync sa serverom"
                                           FontSize="12" Foreground="#666"
                                           FontFamily="Segoe UI" Margin="0,4,0,0"/>
                            </StackPanel>
                        </Grid>

                        <!-- Stat strip -->
                        <Grid Grid.Row="1" Margin="0,0,0,16">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="10"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="10"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="10"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Border Grid.Column="0" Background="#161616" CornerRadius="10"
                                    Padding="14,10" BorderBrush="#222" BorderThickness="1">
                                <StackPanel>
                                    <TextBlock Text="LOKALNO" FontSize="9" Foreground="#666"
                                               FontWeight="Bold" FontFamily="Segoe UI"/>
                                    <TextBlock x:Name="txtModsLocal" Text="-" FontSize="22"
                                               FontWeight="Bold" Foreground="#F5C518" FontFamily="Segoe UI"
                                               Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="2" Background="#161616" CornerRadius="10"
                                    Padding="14,10" BorderBrush="#222" BorderThickness="1">
                                <StackPanel>
                                    <TextBlock Text="SERVER" FontSize="9" Foreground="#666"
                                               FontWeight="Bold" FontFamily="Segoe UI"/>
                                    <TextBlock x:Name="txtModsServer" Text="-" FontSize="22"
                                               FontWeight="Bold" Foreground="#F5C518" FontFamily="Segoe UI"
                                               Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="4" Background="#161616" CornerRadius="10"
                                    Padding="14,10" BorderBrush="#222" BorderThickness="1">
                                <StackPanel>
                                    <TextBlock Text="FALI / ZASTARJELO" FontSize="9" Foreground="#666"
                                               FontWeight="Bold" FontFamily="Segoe UI"/>
                                    <TextBlock x:Name="txtModsMissing" Text="-" FontSize="22"
                                               FontWeight="Bold" Foreground="#E5484D" FontFamily="Segoe UI"
                                               Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                            <Border Grid.Column="6" Background="#161616" CornerRadius="10"
                                    Padding="14,10" BorderBrush="#222" BorderThickness="1">
                                <StackPanel>
                                    <TextBlock Text="VIDLJIVO" FontSize="9" Foreground="#666"
                                               FontWeight="Bold" FontFamily="Segoe UI"/>
                                    <TextBlock x:Name="txtModsVisible" Text="-" FontSize="22"
                                               FontWeight="Bold" Foreground="#9d8df5" FontFamily="Segoe UI"
                                               Margin="0,2,0,0"/>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Toolbar (akcije + search + filteri u jednom blocku) -->
                        <Border Grid.Row="2" Background="#141414" CornerRadius="10"
                                Padding="14,12" Margin="0,0,0,12"
                                BorderBrush="#222" BorderThickness="1">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Row="0" Grid.Column="0" Orientation="Horizontal">
                                    <Button x:Name="btnRefreshMods" Content="Osvjezi"
                                            Style="{StaticResource BtnGhost}" Margin="0,0,8,0"
                                            ToolTip="Provjeri server modove i usporedi sa lokalnim"/>
                                    <Button x:Name="btnRescanMods" Content="Ponovno skeniraj"
                                            Style="{StaticResource BtnGhost}" Margin="0,0,8,0"
                                            ToolTip="Prisilno osvjezi manifest sa servera (bot ili mods.html)"/>
                                    <Button x:Name="btnDownloadMissing" Content="Skini Sve Sto Fali"
                                            Style="{StaticResource BtnPrimary}" Margin="0,0,8,0"
                                            ToolTip="Skini sve mod-ove sa statusom FALI ili ZASTARIO"/>
                                    <Border Width="1" Background="#2a2a2a" Margin="4,2,12,2"/>
                                    <Button x:Name="btnDeleteMod" Content="Obrisi"
                                            Style="{StaticResource BtnDanger}" Margin="0,0,8,0"
                                            ToolTip="Obrisi oznaceni lokalni mod (Recycle Bin)"/>
                                    <Button x:Name="btnOpenModsFolder" Content="Otvori Folder"
                                            Style="{StaticResource BtnGhost}"
                                            ToolTip="Otvori mods folder u Windows Exploreru"/>
                                </StackPanel>
                                <Border Grid.Row="0" Grid.Column="1" Background="#0d0d0d" CornerRadius="6"
                                        BorderBrush="#222" BorderThickness="1" Width="260" Height="34"
                                        VerticalAlignment="Center">
                                    <Grid>
                                        <TextBlock Text="Pretrazi modove..." FontSize="12"
                                                   Foreground="#555" FontFamily="Segoe UI"
                                                   VerticalAlignment="Center" Margin="12,0,0,0"
                                                   x:Name="txtModSearchPlaceholder" IsHitTestVisible="False"/>
                                        <TextBox x:Name="txtModSearch" Background="Transparent"
                                                 BorderThickness="0" Foreground="#eee"
                                                 FontSize="12" FontFamily="Segoe UI"
                                                 VerticalContentAlignment="Center" Padding="12,0"
                                                 CaretBrush="{StaticResource Gold}"/>
                                    </Grid>
                                </Border>

                                <StackPanel Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" Margin="0,12,0,0">
                                    <StackPanel Orientation="Horizontal">
                                        <RadioButton x:Name="filterAll" Content="Svi" GroupName="modFilter"
                                                     Style="{StaticResource BtnFilter}" IsChecked="True" Margin="0,0,6,0"/>
                                        <RadioButton x:Name="filterServer" Content="Server" GroupName="modFilter"
                                                     Style="{StaticResource BtnFilter}" Margin="0,0,6,0"/>
                                        <RadioButton x:Name="filterMissing" Content="Fali" GroupName="modFilter"
                                                     Style="{StaticResource BtnFilter}" Margin="0,0,6,0"/>
                                        <RadioButton x:Name="filterExtra" Content="Extra" GroupName="modFilter"
                                                     Style="{StaticResource BtnFilter}" Margin="0,0,6,0"/>
                                        <RadioButton x:Name="filterLocal" Content="Lokalno" GroupName="modFilter"
                                                     Style="{StaticResource BtnFilter}"/>
                                    </StackPanel>
                                    <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                                        <TextBlock Text="PRIKAZ:" FontSize="10" Foreground="#666" FontWeight="Bold"
                                                   VerticalAlignment="Center" Margin="0,0,10,0" FontFamily="Segoe UI"/>
                                        <ComboBox x:Name="cmbModShow" Width="240" MinWidth="200"
                                                  Background="#1a1a1a" Foreground="#eee" BorderBrush="#333"
                                                  Padding="10,8" FontFamily="Segoe UI" FontSize="12"
                                                  DisplayMemberPath="Label"/>
                                    </StackPanel>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <Border Grid.Row="3" Background="#101010" CornerRadius="10"
                                BorderBrush="#222" BorderThickness="1" Padding="8">
                            <ScrollViewer VerticalScrollBarVisibility="Auto"
                                          HorizontalScrollBarVisibility="Disabled">
                                <ListBox x:Name="lstMods" Background="Transparent" Foreground="#ddd"
                                         BorderThickness="0" FontFamily="Segoe UI"
                                         ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                                         ScrollViewer.VerticalScrollBarVisibility="Disabled"
                                         ItemContainerStyle="{StaticResource ModCardListItem}">
                                    <ListBox.ItemsPanel>
                                        <ItemsPanelTemplate>
                                            <WrapPanel Orientation="Horizontal"/>
                                        </ItemsPanelTemplate>
                                    </ListBox.ItemsPanel>
                                    <ListBox.ItemTemplate>
                                        <DataTemplate>
                                            <Border Width="168" MinHeight="200" CornerRadius="10"
                                                    Background="#161616" BorderBrush="#2a2a2a" BorderThickness="1"
                                                    Padding="0" Cursor="Hand"
                                                    ToolTip="{Binding ToolTipText}">
                                                <Border.Style>
                                                    <Style TargetType="Border">
                                                        <Style.Triggers>
                                                            <DataTrigger Binding="{Binding RelativeSource={RelativeSource AncestorType=ListBoxItem}, Path=IsSelected}" Value="True">
                                                                <Setter Property="BorderBrush" Value="{StaticResource Gold}"/>
                                                                <Setter Property="Background" Value="#1a1408"/>
                                                            </DataTrigger>
                                                            <Trigger Property="IsMouseOver" Value="True">
                                                                <Setter Property="BorderBrush" Value="#3a2e10"/>
                                                            </Trigger>
                                                        </Style.Triggers>
                                                    </Style>
                                                </Border.Style>
                                                <StackPanel>
                                                    <Border Height="88" CornerRadius="10,10,0,0" Background="#0d0d0d" ClipToBounds="True">
                                                        <Grid>
                                                            <Image Stretch="UniformToFill"
                                                                   HorizontalAlignment="Center" VerticalAlignment="Center">
                                                                <Image.Style>
                                                                    <Style TargetType="Image">
                                                                        <Setter Property="Source" Value="{Binding ThumbSource}"/>
                                                                        <Setter Property="Visibility" Value="Collapsed"/>
                                                                        <Style.Triggers>
                                                                            <DataTrigger Binding="{Binding HasThumb}" Value="True">
                                                                                <Setter Property="Visibility" Value="Visible"/>
                                                                            </DataTrigger>
                                                                        </Style.Triggers>
                                                                    </Style>
                                                                </Image.Style>
                                                            </Image>
                                                            <Ellipse Width="52" Height="52" HorizontalAlignment="Center"
                                                                     VerticalAlignment="Center">
                                                                <Ellipse.Style>
                                                                    <Style TargetType="Ellipse">
                                                                        <Setter Property="Fill">
                                                                            <Setter.Value>
                                                                                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                                                                    <GradientStop Color="#2a2208" Offset="0"/>
                                                                                    <GradientStop Color="#1a1408" Offset="1"/>
                                                                                </LinearGradientBrush>
                                                                            </Setter.Value>
                                                                        </Setter>
                                                                        <Style.Triggers>
                                                                            <DataTrigger Binding="{Binding HasThumb}" Value="True">
                                                                                <Setter Property="Visibility" Value="Collapsed"/>
                                                                            </DataTrigger>
                                                                        </Style.Triggers>
                                                                    </Style>
                                                                </Ellipse.Style>
                                                            </Ellipse>
                                                            <TextBlock Text="{Binding Initial}" FontSize="26" FontWeight="Bold"
                                                                       Foreground="{StaticResource Gold}" HorizontalAlignment="Center"
                                                                       VerticalAlignment="Center" FontFamily="Segoe UI">
                                                                <TextBlock.Style>
                                                                    <Style TargetType="TextBlock">
                                                                        <Style.Triggers>
                                                                            <DataTrigger Binding="{Binding HasThumb}" Value="True">
                                                                                <Setter Property="Visibility" Value="Collapsed"/>
                                                                            </DataTrigger>
                                                                        </Style.Triggers>
                                                                    </Style>
                                                                </TextBlock.Style>
                                                            </TextBlock>
                                                            <TextBlock Text="&#x26A0;" FontSize="16" FontWeight="Bold"
                                                                       HorizontalAlignment="Right" VerticalAlignment="Top"
                                                                       Margin="0,8,10,0" Foreground="#E5484D">
                                                                <TextBlock.Style>
                                                                    <Style TargetType="TextBlock">
                                                                        <Setter Property="Visibility" Value="Collapsed"/>
                                                                        <Style.Triggers>
                                                                            <DataTrigger Binding="{Binding Status}" Value="FALI">
                                                                                <Setter Property="Visibility" Value="Visible"/>
                                                                            </DataTrigger>
                                                                            <DataTrigger Binding="{Binding Status}" Value="ZASTARIO">
                                                                                <Setter Property="Visibility" Value="Visible"/>
                                                                                <Setter Property="Foreground" Value="#F5C518"/>
                                                                            </DataTrigger>
                                                                        </Style.Triggers>
                                                                    </Style>
                                                                </TextBlock.Style>
                                                            </TextBlock>
                                                            <Button x:Name="btnModFavorite" Content="{Binding FavoriteStar}"
                                                                    Width="30" Height="30" Padding="0"
                                                                    HorizontalAlignment="Left" VerticalAlignment="Top"
                                                                    Margin="8,8,0,0" Background="#99000000"
                                                                    BorderThickness="0" Cursor="Hand"
                                                                    FontSize="17" Foreground="#F5C518"
                                                                    ToolTip="Dodaj ili ukloni iz favorita"/>
                                                        </Grid>
                                                    </Border>
                                                    <StackPanel Margin="12,10,12,12">
                                                        <TextBlock Text="{Binding Name}" FontSize="12" FontWeight="SemiBold"
                                                                   Foreground="#eee" TextTrimming="CharacterEllipsis"
                                                                   MaxWidth="144" FontFamily="Segoe UI"/>
                                                        <TextBlock Text="{Binding Version}" FontSize="10" Foreground="#888"
                                                                   Margin="0,4,0,0" FontFamily="Segoe UI"/>
                                                        <Border CornerRadius="4" Padding="6,2" Margin="0,8,0,0"
                                                                HorizontalAlignment="Left" Background="#222">
                                                            <TextBlock Text="{Binding Category}" FontSize="9"
                                                                       Foreground="#aaa" FontFamily="Segoe UI"/>
                                                        </Border>
                                                        <TextBlock Text="{Binding Size}" FontSize="9" Foreground="#555"
                                                                   Margin="0,6,0,0" FontFamily="Segoe UI"/>
                                                    </StackPanel>
                                                </StackPanel>
                                            </Border>
                                        </DataTemplate>
                                    </ListBox.ItemTemplate>
                                    <ListBox.ContextMenu>
                                        <ContextMenu Background="#161616" Foreground="#eee" BorderBrush="#333">
                                            <MenuItem x:Name="ctxDeleteMod" Header="Obrisi mod" Foreground="#E5484D"/>
                                            <MenuItem x:Name="ctxOpenInExplorer" Header="Pokazi u Exploreru"/>
                                            <MenuItem x:Name="ctxCopyName" Header="Kopiraj ime"/>
                                        </ContextMenu>
                                    </ListBox.ContextMenu>
                                </ListBox>
                            </ScrollViewer>
                        </Border>

                        <Border Grid.Row="4" Background="#141414" CornerRadius="8"
                                Padding="14,10" Margin="0,10,0,0"
                                BorderBrush="#222" BorderThickness="1">
                            <TextBlock x:Name="txtModStatus" Text="Klikni 'Osvjezi' za pregled modova"
                                       FontSize="12" Foreground="#888" FontFamily="Segoe UI"/>
                        </Border>
                    </Grid>

                    <!-- PAGE: IGRA (savegame + mod profili) -->
                    <ScrollViewer x:Name="pageIgra" Visibility="Collapsed"
                                  VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel Margin="32,28,32,32" MaxWidth="900">

                            <StackPanel Margin="0,0,0,18">
                                <TextBlock Text="Savegame i profili" FontSize="26" FontWeight="Bold"
                                           Foreground="#f0f0f0" FontFamily="Segoe UI"/>
                                <TextBlock Text="Pregled FS25 save slotova i mod profila po serveru (bez izmjene save datoteka)"
                                           FontSize="12" Foreground="#666" FontFamily="Segoe UI" Margin="0,4,0,0"
                                           TextWrapping="Wrap"/>
                            </StackPanel>

                            <Border Background="#161616" CornerRadius="10" Padding="20"
                                    Margin="0,0,0,14" BorderBrush="#222" BorderThickness="1">
                                <StackPanel>
                                    <Grid Margin="0,0,0,10">
                                        <TextBlock Text="Mod profili" FontSize="15" FontWeight="SemiBold"
                                                   Foreground="#F5C518" FontFamily="Segoe UI"/>
                                        <Button x:Name="btnRefreshModProfiles" Content="Osvjezi"
                                                Style="{StaticResource BtnGhost}" HorizontalAlignment="Right"
                                                VerticalAlignment="Center" Padding="16,8"/>
                                    </Grid>
                                    <TextBlock Text="JSON u AppData - po serveru (sync mod foldera pri launchu kasnije)"
                                               FontSize="11" Foreground="#666" FontFamily="Segoe UI"
                                               TextWrapping="Wrap" Margin="0,0,0,10"/>
                                    <ComboBox x:Name="cmbModProfiles"
                                              Background="#1a1a1a" Foreground="#eee"
                                              BorderBrush="#333" Padding="10,8" FontFamily="Segoe UI"/>
                                    <TextBlock x:Name="txtModProfilePath" Text="" FontSize="10"
                                               Foreground="#555" FontFamily="Segoe UI" Margin="0,8,0,0"
                                               TextWrapping="Wrap"/>
                                </StackPanel>
                            </Border>

                            <Border Background="#161616" CornerRadius="10" Padding="20"
                                    Margin="0,0,0,14" BorderBrush="#222" BorderThickness="1">
                                <StackPanel>
                                    <Grid Margin="0,0,0,8">
                                        <TextBlock Text="Savegame slotovi (FS25)" FontSize="15"
                                                   FontWeight="SemiBold" Foreground="#F5C518" FontFamily="Segoe UI"/>
                                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                                            <Button x:Name="btnSaveWizard" Content="Save wizard"
                                                    Style="{StaticResource BtnPrimary}" Margin="0,0,8,0"
                                                    Padding="16,8" ToolTip="Vodic: save, mods folder, postavke (skeleton)"/>
                                            <Button x:Name="btnRefreshSavegames" Content="Osvjezi savegame"
                                                    Style="{StaticResource BtnGhost}" Padding="16,8"/>
                                        </StackPanel>
                                    </Grid>
                                    <TextBlock x:Name="txtIgraSavePath" Text="-"
                                               FontSize="10" Foreground="#888" FontFamily="Segoe UI"
                                               TextWrapping="Wrap" Margin="0,0,0,10"/>
                                    <Border Background="#111" CornerRadius="8" BorderBrush="#1a1a1a"
                                            BorderThickness="1" MaxHeight="320">
                                        <ListView x:Name="lstSavegames" Background="Transparent"
                                                  BorderThickness="0" Foreground="#ddd" FontFamily="Segoe UI"
                                                  ScrollViewer.HorizontalScrollBarVisibility="Auto">
                                            <ListView.View>
                                                <GridView>
                                                    <GridViewColumn Header="Slot" Width="44"
                                                                    DisplayMemberBinding="{Binding Slot}"/>
                                                    <GridViewColumn Header="Ime" Width="130"
                                                                    DisplayMemberBinding="{Binding Name}"/>
                                                    <GridViewColumn Header="Mapa" Width="110"
                                                                    DisplayMemberBinding="{Binding MapTitle}"/>
                                                    <GridViewColumn Header="Novac" Width="80"
                                                                    DisplayMemberBinding="{Binding Money}"/>
                                                    <GridViewColumn Header="Sati" Width="64"
                                                                    DisplayMemberBinding="{Binding PlayTime}"/>
                                                    <GridViewColumn Header="MB" Width="44"
                                                                    DisplayMemberBinding="{Binding SizeMb}"/>
                                                    <GridViewColumn Header="Izmjena" Width="110"
                                                                    DisplayMemberBinding="{Binding LastWrite}"/>
                                                </GridView>
                                            </ListView.View>
                                        </ListView>
                                    </Border>
                                </StackPanel>
                            </Border>

                            <Grid Margin="0,4,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock x:Name="txtIgraSaveHint" Grid.Column="0" VerticalAlignment="Center"
                                           FontSize="11" Foreground="#666" FontFamily="Segoe UI" TextWrapping="Wrap"
                                           Margin="0,0,12,0"/>
                                <Button x:Name="btnOpenSaveSlot" Grid.Column="1" Content="Otvori slot u Exploreru"
                                        Style="{StaticResource BtnPrimary}" Padding="20,10"
                                        ToolTip="Otvara odabrani savegame folder (bez izmjene datoteka)"/>
                            </Grid>
                        </StackPanel>
                    </ScrollViewer>

                    <!-- PAGE: MULTIPLAYER FOLDERS -->
                    <ScrollViewer x:Name="pageMpFolders" Visibility="Collapsed"
                                  VerticalScrollBarVisibility="Auto">
                        <StackPanel Margin="32,28,32,32" MaxWidth="960">
                            <Grid Margin="0,0,0,18">
                                <StackPanel>
                                    <TextBlock Text="Multiplayer folderi" FontSize="26" FontWeight="Bold"
                                               Foreground="#f0f0f0" FontFamily="Segoe UI"/>
                                    <TextBlock Text="Dedicated mod folderi po serveru - Phase 1 (JSON, favoriti, join path)"
                                               FontSize="12" Foreground="#666" FontFamily="Segoe UI" Margin="0,4,0,0"/>
                                </StackPanel>
                                <Button x:Name="btnMpRefresh" Content="Osvjezi"
                                        Style="{StaticResource BtnGhost}" HorizontalAlignment="Right"
                                        VerticalAlignment="Top" Padding="16,8"/>
                            </Grid>

                            <Border Background="#161616" CornerRadius="10" Padding="20"
                                    Margin="0,0,0,14" BorderBrush="#3a2e10" BorderThickness="1">
                                <StackPanel>
                                    <TextBlock Text="Brzi odabir foldera" FontSize="15" FontWeight="SemiBold"
                                               Foreground="#F5C518" FontFamily="Segoe UI" Margin="0,0,0,10"/>
                                    <ComboBox x:Name="cmbMpFolderSelect"
                                              Background="#1a1a1a" Foreground="#eee"
                                              BorderBrush="#333" Padding="10,8" FontFamily="Segoe UI"/>
                                    <TextBlock x:Name="txtMpFolderPath" Text="" FontSize="10"
                                               Foreground="#888" FontFamily="Segoe UI" Margin="0,8,0,0"
                                               TextWrapping="Wrap"/>
                                    <TextBlock x:Name="txtMpFolderJsonPath" Text="" FontSize="9"
                                               Foreground="#555" FontFamily="Segoe UI" Margin="0,6,0,0"
                                               TextWrapping="Wrap"/>
                                </StackPanel>
                            </Border>

                            <WrapPanel Margin="0,0,0,14">
                                <Button x:Name="btnMpCreateFolder" Content="Kreiraj folder"
                                        Style="{StaticResource BtnPrimary}" Margin="0,0,8,8" Padding="14,10"/>
                                <Button x:Name="btnMpAddFolder" Content="Dodaj folder"
                                        Style="{StaticResource BtnGhost}" Margin="0,0,8,8" Padding="14,10"/>
                                <Button x:Name="btnMpRemoveFolder" Content="Ukloni iz liste"
                                        Style="{StaticResource BtnGhost}" Margin="0,0,8,8" Padding="14,10"/>
                                <Button x:Name="btnMpResetMain" Content="Reset na glavnu biblioteku"
                                        Style="{StaticResource BtnFlat}" Foreground="#888"
                                        Margin="0,0,8,8" Padding="14,10"/>
                            </WrapPanel>

                            <Border Background="#161616" CornerRadius="10" Padding="16"
                                    Margin="0,0,0,14" BorderBrush="#222" BorderThickness="1">
                                <StackPanel>
                                    <TextBlock Text="Folderi (JSON)" FontSize="13" FontWeight="SemiBold"
                                               Foreground="#ccc" FontFamily="Segoe UI" Margin="0,0,0,8"/>
                                    <ListView x:Name="lstMpFolders" Background="Transparent" BorderThickness="0"
                                              Foreground="#ddd" FontFamily="Segoe UI" MaxHeight="160">
                                        <ListView.View>
                                            <GridView>
                                                <GridViewColumn Header="" Width="32" DisplayMemberBinding="{Binding FavoriteStar}"/>
                                                <GridViewColumn Header="Naziv" Width="140" DisplayMemberBinding="{Binding Label}"/>
                                                <GridViewColumn Header="Putanja" Width="360" DisplayMemberBinding="{Binding Path}"/>
                                            </GridView>
                                        </ListView.View>
                                    </ListView>
                                </StackPanel>
                            </Border>

                            <Border Background="#111" CornerRadius="10" Padding="20"
                                    BorderBrush="#222" BorderThickness="1" MinHeight="200">
                                <StackPanel>
                                    <Grid Margin="0,0,0,10">
                                        <TextBlock Text="U ovom folderu" FontSize="15" FontWeight="SemiBold"
                                                   Foreground="#F5C518" FontFamily="Segoe UI"/>
                                        <TextBlock x:Name="txtMpInFolderCount" Text="0 modova"
                                                   HorizontalAlignment="Right" FontSize="11"
                                                   Foreground="#888" FontFamily="Segoe UI"/>
                                    </Grid>
                                    <TextBlock Text="Grid mod kartica s IN FOLDER badgeom - Phase 2. Trenutno: broj .zip datoteka u odabranom folderu."
                                               FontSize="11" Foreground="#666" TextWrapping="Wrap" FontFamily="Segoe UI"/>
                                </StackPanel>
                            </Border>

                            <Grid Margin="0,16,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Grid.Column="0" VerticalAlignment="Center" FontSize="11"
                                           Foreground="#666" FontFamily="Segoe UI" TextWrapping="Wrap"
                                           Text="Primijeni odabir prije synca. Aktiviraj &amp; Launch pokrece isti flow kao Udi na server."/>
                                <Button x:Name="btnMpApply" Grid.Column="1" Content="Primijeni promjene"
                                        Style="{StaticResource BtnGhost}" Margin="0,0,10,0" Padding="18,10"/>
                                <Button x:Name="btnMpActivateLaunch" Grid.Column="2" Content="Aktiviraj i pokreni FS25"
                                        Style="{StaticResource BtnPrimary}" Padding="18,10"/>
                            </Grid>
                        </StackPanel>
                    </ScrollViewer>

                    <!-- PAGE: POSTAVKE -->
                    <ScrollViewer x:Name="pageSettings" Visibility="Collapsed"
                                  VerticalScrollBarVisibility="Auto">
                        <StackPanel Margin="28,24">
                            <TextBlock Text="Postavke" FontSize="22" FontWeight="Bold"
                                       Foreground="#f0f0f0" FontFamily="Segoe UI" Margin="0,0,0,20"/>

                            <!-- Licenca (SR-only vs generic hub launcheri) -->
                            <Border Background="#161616" CornerRadius="10" Padding="24"
                                    Margin="0,0,0,16" BorderBrush="#3a2e10" BorderThickness="1">
                                <StackPanel>
                                    <TextBlock Text="Licenca i racunalo" FontSize="15" FontWeight="SemiBold"
                                               Foreground="#F5C518" Margin="0,0,0,12" FontFamily="Segoe UI"/>
                                    <TextBlock x:Name="txtLicenseStatus" Text="Ucitavam..."
                                               FontSize="13" Foreground="#ddd" FontFamily="Segoe UI"
                                               TextWrapping="Wrap" Margin="0,0,0,6"/>
                                    <TextBlock x:Name="txtLicenseExpiry" Text=""
                                               FontSize="11" Foreground="#888" FontFamily="Segoe UI"
                                               Margin="0,0,0,10"/>
                                    <TextBlock x:Name="txtHwidShort" Text="HWID: -"
                                               FontSize="10" Foreground="#555" FontFamily="Consolas"
                                               Margin="0,0,0,12"/>
                                    <StackPanel Orientation="Horizontal">
                                        <Button x:Name="btnCopyHwid" Content="Kopiraj HWID"
                                                Style="{StaticResource BtnGhost}" Margin="0,0,8,0"
                                                ToolTip="Kopiraj HWID u clipboard (za podrsku / aktivaciju)"/>
                                        <Button x:Name="btnChangeLicense" Content="Promijeni licencu"
                                                Style="{StaticResource BtnFlat}" Foreground="#F5C518"
                                                ToolTip="Ponovo unesi ili aktiviraj licencni kljuc"/>
                                    </StackPanel>
                                </StackPanel>
                            </Border>

                            <!-- Player / Platform Settings (FarmSim Hub style) -->
                            <Border Background="#161616" CornerRadius="10" Padding="24"
                                    Margin="0,0,0,16" BorderBrush="#222" BorderThickness="1">
                                <StackPanel>
                                    <TextBlock Text="Igra i platforma" FontSize="15" FontWeight="SemiBold"
                                               Foreground="#F5C518" Margin="0,0,0,8" FontFamily="Segoe UI"/>
                                    <TextBlock Text="Odaberi launcher preko kojeg je FS25 instaliran"
                                               FontSize="11" Foreground="#666" Margin="0,0,0,12" FontFamily="Segoe UI"/>

                                    <WrapPanel x:Name="platformPanel" Margin="0,0,0,16">
                                        <RadioButton x:Name="platformSteam" Content="Steam" GroupName="gamePlatform"
                                                     Style="{StaticResource BtnFilter}" Margin="0,0,8,8"
                                                     Tag="steam" IsChecked="True"/>
                                        <RadioButton x:Name="platformGiants" Content="Giants Installer" GroupName="gamePlatform"
                                                     Style="{StaticResource BtnFilter}" Margin="0,0,8,8" Tag="giants"/>
                                        <RadioButton x:Name="platformXbox" Content="Xbox / Game Pass" GroupName="gamePlatform"
                                                     Style="{StaticResource BtnFilter}" Margin="0,0,8,8" Tag="xbox"/>
                                    </WrapPanel>

                                    <TextBlock Text="FS25.exe (FarmingSimulator2025.exe)" FontSize="11"
                                               Foreground="#888" Margin="0,0,0,6" FontFamily="Segoe UI"/>
                                    <Grid Margin="0,0,0,12">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBox x:Name="txtGameExe" Grid.Column="0"
                                                 Style="{StaticResource ModernTextBox}"/>
                                        <Button x:Name="btnBrowseExe" Grid.Column="1" Content="..."
                                                Style="{StaticResource BtnGhost}" Width="44" Margin="8,0,0,0"
                                                ToolTip="Odaberi exe"/>
                                        <Button x:Name="btnAutoDetectGame" Grid.Column="2" Content="Auto"
                                                Style="{StaticResource BtnGhost}" Margin="8,0,0,0" Padding="12,8"
                                                ToolTip="Automatski pronadi igru za odabranu platformu"/>
                                    </Grid>

                                    <TextBlock Text="Mods folder" FontSize="11"
                                               Foreground="#888" Margin="0,0,0,6" FontFamily="Segoe UI"/>
                                    <Grid Margin="0,0,0,12">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBox x:Name="txtModsPath" Grid.Column="0"
                                                 Style="{StaticResource ModernTextBox}"/>
                                        <Button x:Name="btnBrowseMods" Grid.Column="1" Content="..."
                                                Style="{StaticResource BtnGhost}" Width="44" Margin="8,0,0,0"/>
                                    </Grid>

                                    <TextBlock Text="Savegames folder (My Games\FarmingSimulator2025)" FontSize="11"
                                               Foreground="#888" Margin="0,0,0,6" FontFamily="Segoe UI"/>
                                    <Grid Margin="0,0,0,12">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBox x:Name="txtSavegamesPath" Grid.Column="0"
                                                 Style="{StaticResource ModernTextBox}"/>
                                        <Button x:Name="btnBrowseSavegames" Grid.Column="1" Content="..."
                                                Style="{StaticResource BtnGhost}" Width="44" Margin="8,0,0,0"/>
                                    </Grid>

                                    <TextBlock Text="DLC / data folder (opcionalno)" FontSize="11"
                                               Foreground="#888" Margin="0,0,0,6" FontFamily="Segoe UI"/>
                                    <Grid Margin="0,0,0,16">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBox x:Name="txtDlcPath" Grid.Column="0"
                                                 Style="{StaticResource ModernTextBox}"/>
                                        <Button x:Name="btnBrowseDlc" Grid.Column="1" Content="..."
                                                Style="{StaticResource BtnGhost}" Width="44" Margin="8,0,0,0"/>
                                    </Grid>

                                    <TextBlock Text="Launch argumenti (Steam i Giants exe)" FontSize="11"
                                               Foreground="#888" Margin="0,0,0,10" FontFamily="Segoe UI"/>
                                    <StackPanel Orientation="Horizontal" Margin="0,0,0,16">
                                        <CheckBox x:Name="chkLaunchSkipIntro" Content="-skipStartVideos"
                                                  Foreground="#ccc" FontFamily="Segoe UI" Margin="0,0,20,0"
                                                  IsChecked="True"
                                                  ToolTip="Preskoci intro video (preporuceno za multiplayer)"/>
                                        <CheckBox x:Name="chkLaunchCheats" Content="-cheats"
                                                  Foreground="#ccc" FontFamily="Segoe UI"
                                                  ToolTip="Developer cheats u igri"/>
                                    </StackPanel>

                                    <Button x:Name="btnSavePlayerSettings" Content="Spremi Postavke"
                                            Style="{StaticResource BtnPrimary}" HorizontalAlignment="Left"
                                            Padding="28,12"/>
                                </StackPanel>
                            </Border>

                            <!-- Game Options -->
                            <Border Background="#161616" CornerRadius="10" Padding="24"
                                    Margin="0,0,0,16" BorderBrush="#222" BorderThickness="1">
                                <StackPanel>
                                    <TextBlock Text="Opcije Igre" FontSize="15" FontWeight="SemiBold"
                                               Foreground="#F5C518" Margin="0,0,0,16" FontFamily="Segoe UI"/>

                                    <Grid Margin="0,0,0,14">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Grid.Column="0">
                                            <TextBlock Text="Intro Scena" FontSize="13"
                                                       Foreground="#ddd" FontFamily="Segoe UI"/>
                                            <TextBlock Text="Prikazi intro video prilikom pokretanja igre"
                                                       FontSize="11" Foreground="#666" FontFamily="Segoe UI"
                                                       Margin="0,2,0,0"/>
                                        </StackPanel>
                                        <CheckBox x:Name="chkIntroScene" Grid.Column="1"
                                                  Style="{StaticResource ToggleSwitch}"
                                                  VerticalAlignment="Center"
                                                  ToolTip="Off = igra se pokrece sa -skipStartVideos argumentom (prskace Giants intro)"/>
                                    </Grid>

                                    <Border Height="1" Background="#222" Margin="0,0,0,14"/>

                                    <Grid Margin="0,0,0,14">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Grid.Column="0">
                                            <TextBlock Text="Developer Console" FontSize="13"
                                                       Foreground="#ddd" FontFamily="Segoe UI"/>
                                            <TextBlock Text="Omoguci developer konzolu (~ tipka u igri)"
                                                       FontSize="11" Foreground="#666" FontFamily="Segoe UI"
                                                       Margin="0,2,0,0"/>
                                        </StackPanel>
                                        <CheckBox x:Name="chkDevConsole" Grid.Column="1"
                                                  Style="{StaticResource ToggleSwitch}"
                                                  VerticalAlignment="Center"/>
                                    </Grid>

                                    <Button x:Name="btnSaveGameOptions" Content="Spremi Opcije"
                                            Style="{StaticResource BtnPrimary}" HorizontalAlignment="Left"
                                            Padding="28,12"/>
                                </StackPanel>
                            </Border>

                            <!-- Izgled / Tema -->
                            <Border Background="#161616" CornerRadius="10" Padding="24"
                                    Margin="0,0,0,16" BorderBrush="#222" BorderThickness="1">
                                <StackPanel>
                                    <TextBlock Text="Izgled" FontSize="15" FontWeight="SemiBold"
                                               Foreground="#F5C518" Margin="0,0,0,16" FontFamily="Segoe UI"/>
                                    <TextBlock Text="Tema (akcent boja)" FontSize="11"
                                               Foreground="#888" FontFamily="Segoe UI" Margin="0,0,0,10"/>
                                    <WrapPanel x:Name="themePanel">
                                        <RadioButton x:Name="themeGold" Content="Zlatna" GroupName="theme"
                                                     Style="{StaticResource BtnFilter}" Margin="0,0,8,8"
                                                     IsChecked="True" Tag="#F5C518"/>
                                        <RadioButton x:Name="themeGreen" Content="Zelena" GroupName="theme"
                                                     Style="{StaticResource BtnFilter}" Margin="0,0,8,8"
                                                     Tag="#30A46C"/>
                                        <RadioButton x:Name="themeBlue" Content="Plava" GroupName="theme"
                                                     Style="{StaticResource BtnFilter}" Margin="0,0,8,8"
                                                     Tag="#5b8cff"/>
                                        <RadioButton x:Name="themePurple" Content="Ljubicasta" GroupName="theme"
                                                     Style="{StaticResource BtnFilter}" Margin="0,0,8,8"
                                                     Tag="#9d8df5"/>
                                        <RadioButton x:Name="themeRed" Content="Crvena" GroupName="theme"
                                                     Style="{StaticResource BtnFilter}" Margin="0,0,8,8"
                                                     Tag="#E5484D"/>
                                    </WrapPanel>

                                    <Border Height="1" Background="#222" Margin="0,12,0,12"/>

                                    <Grid Margin="0,0,0,12">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Grid.Column="0">
                                            <TextBlock Text="Animirani background" FontSize="13"
                                                       Foreground="#ddd" FontFamily="Segoe UI"/>
                                            <TextBlock Text="Plutajuce sjenke u boji teme iza sadrzaja"
                                                       FontSize="11" Foreground="#666" FontFamily="Segoe UI"
                                                       Margin="0,2,0,0"/>
                                        </StackPanel>
                                        <CheckBox x:Name="chkAnimBg" Grid.Column="1"
                                                  Style="{StaticResource ToggleSwitch}"
                                                  VerticalAlignment="Center" IsChecked="True"/>
                                    </Grid>

                                    <Grid Margin="0,0,0,12">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Grid.Column="0">
                                            <TextBlock Text="Glow efekti" FontSize="13"
                                                       Foreground="#ddd" FontFamily="Segoe UI"/>
                                            <TextBlock Text="Sjaj na gumbima, status pointeru i naslovima"
                                                       FontSize="11" Foreground="#666" FontFamily="Segoe UI"
                                                       Margin="0,2,0,0"/>
                                        </StackPanel>
                                        <CheckBox x:Name="chkGlow" Grid.Column="1"
                                                  Style="{StaticResource ToggleSwitch}"
                                                  VerticalAlignment="Center" IsChecked="True"/>
                                    </Grid>
                                </StackPanel>
                            </Border>

                            <!-- Ponasanje launchera -->
                            <Border Background="#161616" CornerRadius="10" Padding="24"
                                    Margin="0,0,0,16" BorderBrush="#222" BorderThickness="1">
                                <StackPanel>
                                    <TextBlock Text="Ponasanje" FontSize="15" FontWeight="SemiBold"
                                               Foreground="#F5C518" Margin="0,0,0,16" FontFamily="Segoe UI"/>

                                    <Grid Margin="0,0,0,14">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Grid.Column="0">
                                            <TextBlock Text="Auto-zatvori nakon launcha" FontSize="13"
                                                       Foreground="#ddd" FontFamily="Segoe UI"/>
                                            <TextBlock Text="Zatvori launcher kad se igra pokrene"
                                                       FontSize="11" Foreground="#666" FontFamily="Segoe UI"
                                                       Margin="0,2,0,0"/>
                                        </StackPanel>
                                        <CheckBox x:Name="chkAutoClose" Grid.Column="1"
                                                  Style="{StaticResource ToggleSwitch}"
                                                  VerticalAlignment="Center" IsChecked="True"/>
                                    </Grid>

                                    <Grid Margin="0,0,0,14">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Grid.Column="0">
                                            <TextBlock Text="Auto-osvjezi server" FontSize="13"
                                                       Foreground="#ddd" FontFamily="Segoe UI"/>
                                            <TextBlock Text="Provjera statusa servera u pozadini"
                                                       FontSize="11" Foreground="#666" FontFamily="Segoe UI"
                                                       Margin="0,2,0,0"/>
                                        </StackPanel>
                                        <CheckBox x:Name="chkAutoRefresh" Grid.Column="1"
                                                  Style="{StaticResource ToggleSwitch}"
                                                  VerticalAlignment="Center" IsChecked="True"/>
                                    </Grid>

                                    <Grid Margin="0,0,0,14">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Grid.Column="0">
                                            <TextBlock Text="Toast notifikacije" FontSize="13"
                                                       Foreground="#ddd" FontFamily="Segoe UI"/>
                                            <TextBlock Text="Skocni prozorcici gore-desno"
                                                       FontSize="11" Foreground="#666" FontFamily="Segoe UI"
                                                       Margin="0,2,0,0"/>
                                        </StackPanel>
                                        <CheckBox x:Name="chkToasts" Grid.Column="1"
                                                  Style="{StaticResource ToggleSwitch}"
                                                  VerticalAlignment="Center" IsChecked="True"/>
                                    </Grid>

                                    <Grid Margin="0,0,0,14">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Grid.Column="0">
                                            <TextBlock Text="Provjera mod velicine" FontSize="13"
                                                       Foreground="#ddd" FontFamily="Segoe UI"/>
                                            <TextBlock Text="Fallback kad nema SHA manifesta; s bot API-jem koristi se SHA-256"
                                                       FontSize="11" Foreground="#666" FontFamily="Segoe UI"
                                                       Margin="0,2,0,0"/>
                                        </StackPanel>
                                        <CheckBox x:Name="chkSizeCheck" Grid.Column="1"
                                                  Style="{StaticResource ToggleSwitch}"
                                                  VerticalAlignment="Center" IsChecked="True"/>
                                    </Grid>

                                    <Grid Margin="0,0,0,14">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Grid.Column="0">
                                            <TextBlock Text="Maximiziraj prozor pri pokretanju" FontSize="13"
                                                       Foreground="#ddd" FontFamily="Segoe UI"/>
                                            <TextBlock Text="Launcher otvoren preko cijelog radnog podrucja (F11 = cijeli zaslon)"
                                                       FontSize="11" Foreground="#666" FontFamily="Segoe UI"
                                                       Margin="0,2,0,0"/>
                                        </StackPanel>
                                        <CheckBox x:Name="chkWindowMaximize" Grid.Column="1"
                                                  Style="{StaticResource ToggleSwitch}"
                                                  VerticalAlignment="Center"/>
                                    </Grid>

                                    <Grid Margin="0,0,0,14">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Grid.Column="0">
                                            <TextBlock Text="Vodic za pocetak" FontSize="13"
                                                       Foreground="#ddd" FontFamily="Segoe UI"/>
                                            <TextBlock Text="Ne prikazuj overlay pri svakom pokretanju"
                                                       FontSize="11" Foreground="#666" FontFamily="Segoe UI"
                                                       Margin="0,2,0,0"/>
                                        </StackPanel>
                                        <CheckBox x:Name="chkHideWalkthrough" Grid.Column="1"
                                                  Style="{StaticResource ToggleSwitch}"
                                                  VerticalAlignment="Center"/>
                                    </Grid>
                                    <Button x:Name="btnShowWalkthrough" Content="Pokazi vodic ponovo"
                                            Style="{StaticResource BtnGhost}" HorizontalAlignment="Left"
                                            Margin="0,0,0,14" Padding="16,8"/>

                                    <Button x:Name="btnSaveBehavior" Content="Spremi Postavke"
                                            Style="{StaticResource BtnPrimary}" HorizontalAlignment="Left"
                                            Padding="28,12" Margin="0,4,0,0"/>
                                </StackPanel>
                            </Border>

                            <!-- Admin Settings (hidden by default) -->
                            <StackPanel x:Name="adminPanel" Visibility="Collapsed">
                                <!-- Server Management -->
                                <Border Background="#161616" CornerRadius="10" Padding="24"
                                        Margin="0,0,0,16" BorderBrush="#F5C518" BorderThickness="1">
                                    <StackPanel>
                                        <TextBlock Text="Server Postavke (Admin)" FontSize="15"
                                                   FontWeight="SemiBold" Foreground="#F5C518"
                                                   Margin="0,0,0,16" FontFamily="Segoe UI"/>

                                        <TextBlock Text="Ime servera" FontSize="11"
                                                   Foreground="#888" Margin="0,0,0,6" FontFamily="Segoe UI"/>
                                        <TextBox x:Name="txtSrvName" Style="{StaticResource ModernTextBox}"
                                                 Margin="0,0,0,12"/>

                                        <Grid Margin="0,0,0,12">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="10"/>
                                                <ColumnDefinition Width="120"/>
                                                <ColumnDefinition Width="10"/>
                                                <ColumnDefinition Width="120"/>
                                            </Grid.ColumnDefinitions>
                                            <StackPanel Grid.Column="0">
                                                <TextBlock Text="IP adresa" FontSize="11"
                                                           Foreground="#888" Margin="0,0,0,6" FontFamily="Segoe UI"/>
                                                <TextBox x:Name="txtSrvIp"
                                                         Style="{StaticResource ModernTextBox}"/>
                                            </StackPanel>
                                            <StackPanel Grid.Column="2">
                                                <TextBlock Text="Web port" FontSize="11"
                                                           Foreground="#888" Margin="0,0,0,6" FontFamily="Segoe UI"/>
                                                <TextBox x:Name="txtSrvWebPort"
                                                         Style="{StaticResource ModernTextBox}"/>
                                            </StackPanel>
                                            <StackPanel Grid.Column="4">
                                                <TextBlock Text="Game port" FontSize="11"
                                                           Foreground="#888" Margin="0,0,0,6" FontFamily="Segoe UI"/>
                                                <TextBox x:Name="txtSrvGamePort"
                                                         Style="{StaticResource ModernTextBox}"/>
                                            </StackPanel>
                                        </Grid>

                                        <TextBlock Text="Stats Code" FontSize="11"
                                                   Foreground="#888" Margin="0,0,0,2" FontFamily="Segoe UI"/>
                                        <TextBlock Text="Kod koji server koristi za prikaz online statusa (igraci, mapa, status). Nalazi se u dedicatedServer.xml na serveru pod 'game &gt; admin_password' ili 'stats_code' poljem." FontSize="10"
                                                   Foreground="#555" Margin="0,0,0,6" FontFamily="Segoe UI" TextWrapping="Wrap"/>
                                        <TextBox x:Name="txtSrvStatsCode" Style="{StaticResource ModernTextBox}"
                                                 Margin="0,0,0,12"/>

                                        <TextBlock Text="Server Password (za igrace)" FontSize="11"
                                                   Foreground="#888" Margin="0,0,0,6" FontFamily="Segoe UI"/>
                                        <TextBox x:Name="txtSrvPassword" Style="{StaticResource ModernTextBox}"
                                                 Margin="0,0,0,16"/>

                                        <WrapPanel>
                                            <Button x:Name="btnSaveServer" Content="Spremi Server"
                                                    Style="{StaticResource BtnPrimary}"
                                                    Padding="18,10" Margin="0,0,8,0"/>
                                            <Button x:Name="btnAddServer" Content="+ Novi Server"
                                                    Style="{StaticResource BtnGhost}" Margin="0,0,8,0"/>
                                            <Button x:Name="btnDeleteServer" Content="Obrisi Server"
                                                    Style="{StaticResource BtnDanger}"/>
                                        </WrapPanel>
                                    </StackPanel>
                                </Border>

                                <!-- GitHub Repo -->
                                <Border Background="#161616" CornerRadius="10" Padding="24"
                                        Margin="0,0,0,16" BorderBrush="#222" BorderThickness="1">
                                    <StackPanel>
                                        <TextBlock Text="GitHub Auto-Update" FontSize="15" FontWeight="SemiBold"
                                                   Foreground="#F5C518" Margin="0,0,0,16" FontFamily="Segoe UI"/>
                                        <TextBlock Text="GitHub Repo (npr: korisnik/SlavonskaRavnica)" FontSize="11"
                                                   Foreground="#888" Margin="0,0,0,6" FontFamily="Segoe UI"/>
                                        <TextBox x:Name="txtGitHubRepo" Style="{StaticResource ModernTextBox}"
                                                 Margin="0,0,0,8"/>
                                        <TextBlock Text="Kad napravis GitHub Release sa .zip datotekom, igraci ce vidjeti 'Nova verzija!' gumb." FontSize="11"
                                                   Foreground="#555" TextWrapping="Wrap" Margin="0,0,0,12" FontFamily="Segoe UI"/>
                                        <Button x:Name="btnSaveGitHub" Content="Spremi GitHub"
                                                Style="{StaticResource BtnPrimary}" HorizontalAlignment="Left"
                                                Padding="20,10"/>
                                    </StackPanel>
                                </Border>

                                <!-- Admin Password -->
                                <Border Background="#161616" CornerRadius="10" Padding="24"
                                        Margin="0,0,0,16" BorderBrush="#222" BorderThickness="1">
                                    <StackPanel>
                                        <TextBlock Text="Admin Lozinka" FontSize="15" FontWeight="SemiBold"
                                                   Foreground="#F5C518" Margin="0,0,0,16" FontFamily="Segoe UI"/>
                                        <TextBlock Text="Nova lozinka (min. 4 znaka)" FontSize="11"
                                                   Foreground="#888" Margin="0,0,0,6" FontFamily="Segoe UI"/>
                                        <PasswordBox x:Name="txtNewAdminPass"
                                                     Style="{StaticResource ModernPasswordBox}"
                                                     Margin="0,0,0,12"/>
                                        <Button x:Name="btnChangeAdminPass" Content="Promijeni Lozinku"
                                                Style="{StaticResource BtnPrimary}"
                                                HorizontalAlignment="Left" Padding="20,10"/>
                                    </StackPanel>
                                </Border>

                                <!-- Backup / Restore -->
                                <Border Background="#161616" CornerRadius="10" Padding="24"
                                        Margin="0,0,0,16" BorderBrush="#222" BorderThickness="1">
                                    <StackPanel>
                                        <TextBlock Text="Backup / Restore" FontSize="15" FontWeight="SemiBold"
                                                   Foreground="#F5C518" Margin="0,0,0,8" FontFamily="Segoe UI"/>
                                        <TextBlock Text="Izvoz/uvoz launcher konfiguracije (putanje, custom serveri, postavke)."
                                                   FontSize="11" Foreground="#888" TextWrapping="Wrap"
                                                   Margin="0,0,0,12" FontFamily="Segoe UI"/>
                                        <WrapPanel>
                                            <Button x:Name="btnExportConfig" Content="Izvezi Config"
                                                    Style="{StaticResource BtnGhost}" Margin="0,0,8,0"
                                                    ToolTip="Spremi config kao .json datoteku za prijenos na drugi PC"/>
                                            <Button x:Name="btnImportConfig" Content="Uvezi Config"
                                                    Style="{StaticResource BtnGhost}"
                                                    ToolTip="Ucitaj prethodno izvezenu config datoteku"/>
                                        </WrapPanel>
                                    </StackPanel>
                                </Border>
                            </StackPanel>
                        </StackPanel>
                    </ScrollViewer>

                    <!-- PAGE: LOG -->
                    <Grid x:Name="pageLog" Visibility="Collapsed" Margin="24,20">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Grid Grid.Row="0" Margin="0,0,0,12">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock Text="Log" FontSize="22" FontWeight="Bold"
                                           Foreground="#f0f0f0" FontFamily="Segoe UI"/>
                                <Border Background="#1a1408" CornerRadius="4" Padding="8,3"
                                        VerticalAlignment="Center" Margin="14,0,0,0">
                                    <TextBlock Text="ADMIN ONLY" FontSize="9" FontWeight="Bold"
                                               Foreground="#F5C518" FontFamily="Segoe UI"/>
                                </Border>
                            </StackPanel>
                            <TextBlock x:Name="txtLogCount" Text="0 redova" FontSize="11"
                                       Foreground="#666" FontFamily="Segoe UI"
                                       HorizontalAlignment="Right" VerticalAlignment="Center"/>
                        </Grid>
                        <Border Grid.Row="1" Background="#161616" CornerRadius="8"
                                BorderBrush="#222" BorderThickness="1" Padding="10,8" Margin="0,0,0,8">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBox x:Name="txtLogSearch" Grid.Column="0"
                                         Style="{StaticResource ModernTextBox}"
                                         Tag="Pretrazi log..." Margin="0,0,8,0"/>
                                <CheckBox x:Name="chkLogAutoScroll" Grid.Column="1" Content="Auto-scroll"
                                          IsChecked="True" Foreground="#bbb" FontSize="11"
                                          VerticalAlignment="Center" Margin="0,0,12,0"/>
                                <Button x:Name="btnLogCopy" Grid.Column="2" Content="Kopiraj"
                                        Style="{StaticResource BtnGhost}" Padding="10,4" FontSize="11"/>
                            </Grid>
                        </Border>
                        <Border Grid.Row="2" Background="#0a0a0a" CornerRadius="8"
                                BorderBrush="#1e1e1e" BorderThickness="1" Padding="4">
                            <TextBox x:Name="txtLog" Background="Transparent" Foreground="#30A46C"
                                     FontFamily="JetBrains Mono, Cascadia Code, Consolas" FontSize="12"
                                     IsReadOnly="True" TextWrapping="Wrap"
                                     VerticalScrollBarVisibility="Auto" BorderThickness="0" Padding="12"/>
                        </Border>
                        <Button x:Name="btnClearLog" Grid.Row="3" Content="Ocisti log"
                                Style="{StaticResource BtnGhost}" HorizontalAlignment="Right"
                                Margin="0,8,0,0"/>
                    </Grid>

                    <!-- WALKTHROUGH OVERLAY -->
                    <Grid x:Name="walkthroughOverlay" Visibility="Collapsed" Panel.ZIndex="800"
                          Background="#CC000000">
                        <Border HorizontalAlignment="Center" VerticalAlignment="Center"
                                MaxWidth="520" MinWidth="400" Background="#121212" CornerRadius="14"
                                BorderBrush="#F5C518" BorderThickness="1" Padding="28,26">
                            <StackPanel>
                                <TextBlock Text="PRVI KORACI" FontSize="9" FontWeight="Bold"
                                           Foreground="#666" FontFamily="Segoe UI" Margin="0,0,0,6"/>
                                <TextBlock x:Name="wtTitle" Text="Dobrodosli" FontSize="20" FontWeight="Bold"
                                           Foreground="#F5C518" FontFamily="Segoe UI" TextWrapping="Wrap"/>
                                <TextBlock x:Name="wtBody" Text="" FontSize="13" Foreground="#ccc"
                                           FontFamily="Segoe UI" TextWrapping="Wrap" Margin="0,12,0,16"
                                           LineHeight="20"/>
                                <ProgressBar x:Name="wtProgress" Height="4" Maximum="6" Value="1"
                                               Background="#222" Foreground="#F5C518" BorderThickness="0"/>
                                <TextBlock x:Name="wtStepLabel" Text="Korak 1 / 6" FontSize="10"
                                           Foreground="#555" FontFamily="Segoe UI" Margin="0,6,0,0"/>
                                <Grid Margin="0,20,0,0">
                                    <CheckBox x:Name="chkWtSkipLaunch" Content="Ne prikazuj pri pokretanju"
                                              Foreground="#888" FontSize="11" FontFamily="Segoe UI"
                                              VerticalAlignment="Center"/>
                                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                                        <Button x:Name="btnWtSkip" Content="Preskoci"
                                                Style="{StaticResource BtnFlat}" Margin="0,0,8,0"
                                                Foreground="#888" Padding="12,8"/>
                                        <Button x:Name="btnWtPrev" Content="Natrag"
                                                Style="{StaticResource BtnGhost}" Margin="0,0,8,0"
                                                Padding="14,8" Visibility="Collapsed"/>
                                        <Button x:Name="btnWtNext" Content="Dalje"
                                                Style="{StaticResource BtnPrimary}" Padding="18,8"/>
                                    </StackPanel>
                                </Grid>
                            </StackPanel>
                        </Border>
                    </Grid>
                </Grid>
            </Grid>

            <!-- BOTTOM BAR -->
            <Border Grid.Row="1" VerticalAlignment="Bottom" Background="#0d0d0d"
                    Padding="16,8" Margin="218,0,0,0">
                <TextBlock x:Name="txtProgress" Text="" FontSize="11"
                           Foreground="#F5C518" FontFamily="Segoe UI" HorizontalAlignment="Right"/>
            </Border>
        </Grid>
    </Border>
</Window>
"@

# ============================================================
# CREATE WINDOW (splash ostaje otvoren do licence + preloada)
# ============================================================
$splashWin = Show-SplashScreen
$splashWin.Show()
Set-SplashStep "Ucitavam konfiguraciju..." 10
try { Initialize-LauncherConfig } catch {}
try { Sync-SharedConfig } catch {}
try {
    if ($script:Config.modsPath -and (Test-Path $script:Config.modsPath)) {
        $script:PreloadedLocalModCount = @(Get-ChildItem $script:Config.modsPath -Filter "*.zip" -ErrorAction SilentlyContinue).Count
    }
} catch {}

Set-SplashStep "Ucitavam sucelje..." 28
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
Invoke-SplashPump

# Postavi taskbar ikonu
try {
    # Prefer high-res PNG over low-res ICO for sharper taskbar/window icon
    $iconCandidates = @(
        (Join-Path $PSScriptRoot "sr_logo.png"),
        (Join-Path $PSScriptRoot "sr_logo.ico")
    )
    foreach ($p in $iconCandidates) {
        if ((Test-Path $p) -and (Get-Item $p).Length -gt 100) {
            $ico = New-Object System.Windows.Media.Imaging.BitmapImage
            $ico.BeginInit()
            $ico.UriSource = New-Object System.Uri($p)
            $ico.CacheOption = "OnLoad"
            $ico.DecodePixelWidth = 64
            $ico.EndInit()
            $window.Icon = $ico
            break
        }
    }
} catch {}

$titleBar            = $window.FindName("titleBar")
$btnFullscreen       = $window.FindName("btnFullscreen")
$btnMinimize         = $window.FindName("btnMinimize")
$btnClose            = $window.FindName("btnClose")
$imgLogo             = $window.FindName("imgLogo")
$statusDot           = $window.FindName("statusDot")
$txtStatus           = $window.FindName("txtStatus")
$btnUpdateNotify     = $window.FindName("btnUpdateNotify")
$updateBanner        = $window.FindName("updateBanner")
$txtUpdateInfo       = $window.FindName("txtUpdateInfo")
$btnUpdateNow        = $window.FindName("btnUpdateNow")
$serverButtonsPanel  = $window.FindName("serverButtonsPanel")
$navDash             = $window.FindName("navDash")
$navMods             = $window.FindName("navMods")
$navIgra             = $window.FindName("navIgra")
$navMpFolders        = $window.FindName("navMpFolders")
$navSettings         = $window.FindName("navSettings")
$navLog              = $window.FindName("navLog")
$btnNavFavorites     = $window.FindName("btnNavFavorites")
$txtNavFavBadge      = $window.FindName("txtNavFavBadge")
$txtNavModsBadge     = $window.FindName("txtNavModsBadge")
$txtNavMapsBadge     = $window.FindName("txtNavMapsBadge")
$txtNavDlcBadge      = $window.FindName("txtNavDlcBadge")
$txtNavScriptsBadge  = $window.FindName("txtNavScriptsBadge")
$btnNavMaps          = $window.FindName("btnNavMaps")
$btnNavDlc           = $window.FindName("btnNavDlc")
$btnNavScripts       = $window.FindName("btnNavScripts")
$btnNavNewCollection = $window.FindName("btnNavNewCollection")
$btnAdminToggle      = $window.FindName("btnAdminToggle")
$txtVersion          = $window.FindName("txtVersion")
$pageDash            = $window.FindName("pageDash")
$pageMods            = $window.FindName("pageMods")
$pageIgra            = $window.FindName("pageIgra")
$pageSettings        = $window.FindName("pageSettings")
$pageLog             = $window.FindName("pageLog")
$statusDotBig        = $window.FindName("statusDotBig")
$txtServerName       = $window.FindName("txtServerName")
$txtServerMap        = $window.FindName("txtServerMap")
$txtServerPlayers    = $window.FindName("txtServerPlayers")
$txtPlayerList       = $window.FindName("txtPlayerList")
$lstPlayerChips      = $window.FindName("lstPlayerChips")
$btnRefreshStatus    = $window.FindName("btnRefreshStatus")
$btnJoinServer       = $window.FindName("btnJoinServer")
$txtJoinStatus       = $window.FindName("txtJoinStatus")
$btnSyncMods         = $window.FindName("btnSyncMods")
$txtMyModCount       = $window.FindName("txtMyModCount")
$txtServerModCount   = $window.FindName("txtServerModCount")
$txtMissingCount     = $window.FindName("txtMissingCount")
$txtModSizeTotal     = $window.FindName("txtModSizeTotal")
$txtServerPing       = $window.FindName("txtServerPing")
$dashStatusBrush     = $window.FindName("dashStatusBrush")
$dashStatusGlow      = $window.FindName("dashStatusGlow")
$txtModSubtitle      = $window.FindName("txtModSubtitle")
$txtModsLocal        = $window.FindName("txtModsLocal")
$txtModsServer       = $window.FindName("txtModsServer")
$txtModsMissing      = $window.FindName("txtModsMissing")
$txtModsVisible      = $window.FindName("txtModsVisible")
$lstMissingPreview   = $window.FindName("lstMissingPreview")
$txtMissingHint      = $window.FindName("txtMissingHint")
$btnGoToMods         = $window.FindName("btnGoToMods")
$lstActivityFeed     = $window.FindName("lstActivityFeed")
# Theme + behavior controls
$themeGold           = $window.FindName("themeGold")
$themeGreen          = $window.FindName("themeGreen")
$themeBlue           = $window.FindName("themeBlue")
$themePurple         = $window.FindName("themePurple")
$themeRed            = $window.FindName("themeRed")
$chkAnimBg           = $window.FindName("chkAnimBg")
$chkGlow             = $window.FindName("chkGlow")
$chkAutoClose        = $window.FindName("chkAutoClose")
$chkAutoRefresh      = $window.FindName("chkAutoRefresh")
$chkToasts           = $window.FindName("chkToasts")
$chkSizeCheck        = $window.FindName("chkSizeCheck")
$btnSaveBehavior     = $window.FindName("btnSaveBehavior")
$bgCanvas            = $window.FindName("bgCanvas")
$txtLogCount         = $window.FindName("txtLogCount")
$txtLogSearch        = $window.FindName("txtLogSearch")
$chkLogAutoScroll    = $window.FindName("chkLogAutoScroll")
$btnLogCopy          = $window.FindName("btnLogCopy")
$txtLastSync         = $window.FindName("txtLastSync")
$btnRefreshMods      = $window.FindName("btnRefreshMods")
$btnDownloadMissing  = $window.FindName("btnDownloadMissing")
$lstMods             = $window.FindName("lstMods")
$txtModStatus        = $window.FindName("txtModStatus")
$txtGameExe          = $window.FindName("txtGameExe")
$txtModsPath         = $window.FindName("txtModsPath")
$txtSavegamesPath    = $window.FindName("txtSavegamesPath")
$txtDlcPath          = $window.FindName("txtDlcPath")
$platformSteam       = $window.FindName("platformSteam")
$platformGiants      = $window.FindName("platformGiants")
$platformXbox        = $window.FindName("platformXbox")
$btnBrowseExe        = $window.FindName("btnBrowseExe")
$btnAutoDetectGame   = $window.FindName("btnAutoDetectGame")
$btnBrowseMods       = $window.FindName("btnBrowseMods")
$btnBrowseSavegames  = $window.FindName("btnBrowseSavegames")
$btnBrowseDlc        = $window.FindName("btnBrowseDlc")
$chkLaunchSkipIntro  = $window.FindName("chkLaunchSkipIntro")
$chkLaunchCheats     = $window.FindName("chkLaunchCheats")
$chkWindowMaximize   = $window.FindName("chkWindowMaximize")
$btnSavePlayerSettings = $window.FindName("btnSavePlayerSettings")
$btnLinkWeb          = $window.FindName("btnLinkWeb")
$btnLinkDiscord      = $window.FindName("btnLinkDiscord")
$adminPanel          = $window.FindName("adminPanel")
$txtSrvName          = $window.FindName("txtSrvName")
$txtSrvIp            = $window.FindName("txtSrvIp")
$txtSrvWebPort       = $window.FindName("txtSrvWebPort")
$txtSrvGamePort      = $window.FindName("txtSrvGamePort")
$txtSrvStatsCode     = $window.FindName("txtSrvStatsCode")
$txtSrvPassword      = $window.FindName("txtSrvPassword")
$btnSaveServer       = $window.FindName("btnSaveServer")
$btnAddServer        = $window.FindName("btnAddServer")
$btnDeleteServer     = $window.FindName("btnDeleteServer")
$txtGitHubRepo       = $window.FindName("txtGitHubRepo")
$btnSaveGitHub       = $window.FindName("btnSaveGitHub")
$txtNewAdminPass     = $window.FindName("txtNewAdminPass")
$btnChangeAdminPass  = $window.FindName("btnChangeAdminPass")
$txtLog              = $window.FindName("txtLog")
$btnClearLog         = $window.FindName("btnClearLog")
$txtProgress         = $window.FindName("txtProgress")
$chkIntroScene       = $window.FindName("chkIntroScene")
$chkDevConsole       = $window.FindName("chkDevConsole")
$btnSaveGameOptions  = $window.FindName("btnSaveGameOptions")
$cmbModProfiles      = $window.FindName("cmbModProfiles")
$btnRefreshModProfiles = $window.FindName("btnRefreshModProfiles")
$txtModProfilePath   = $window.FindName("txtModProfilePath")
$lstSavegames        = $window.FindName("lstSavegames")
$txtIgraSavePath     = $window.FindName("txtIgraSavePath")
$txtIgraSaveHint     = $window.FindName("txtIgraSaveHint")
$btnRefreshSavegames = $window.FindName("btnRefreshSavegames")
$btnOpenSaveSlot     = $window.FindName("btnOpenSaveSlot")
$btnSaveWizard       = $window.FindName("btnSaveWizard")
$filterAll           = $window.FindName("filterAll")
$filterServer        = $window.FindName("filterServer")
$filterMissing       = $window.FindName("filterMissing")
$filterExtra         = $window.FindName("filterExtra")
$filterLocal         = $window.FindName("filterLocal")
$cmbModShow          = $window.FindName("cmbModShow")
$btnRescanMods       = $window.FindName("btnRescanMods")
$btnNavLibraryMods   = $window.FindName("btnNavLibraryMods")
$walkthroughOverlay  = $window.FindName("walkthroughOverlay")
$wtTitle             = $window.FindName("wtTitle")
$wtBody              = $window.FindName("wtBody")
$wtProgress          = $window.FindName("wtProgress")
$wtStepLabel         = $window.FindName("wtStepLabel")
$chkWtSkipLaunch     = $window.FindName("chkWtSkipLaunch")
$btnWtSkip           = $window.FindName("btnWtSkip")
$btnWtPrev           = $window.FindName("btnWtPrev")
$btnWtNext           = $window.FindName("btnWtNext")
$chkHideWalkthrough  = $window.FindName("chkHideWalkthrough")
$btnShowWalkthrough  = $window.FindName("btnShowWalkthrough")

# v1.2 dodatne kontrole
$btnAddCustomServer  = $window.FindName("btnAddCustomServer")
$btnDeleteMod        = $window.FindName("btnDeleteMod")
$btnOpenModsFolder   = $window.FindName("btnOpenModsFolder")
$txtModSearch        = $window.FindName("txtModSearch")
$txtModSearchPlaceholder = $window.FindName("txtModSearchPlaceholder")
$ctxDeleteMod        = $window.FindName("ctxDeleteMod")
$ctxOpenInExplorer   = $window.FindName("ctxOpenInExplorer")
$ctxCopyName         = $window.FindName("ctxCopyName")
$btnExportConfig     = $window.FindName("btnExportConfig")
$btnImportConfig     = $window.FindName("btnImportConfig")
$toastHost           = $window.FindName("toastHost")
$licenseBadge        = $window.FindName("licenseBadge")
$txtLicenseBadge     = $window.FindName("txtLicenseBadge")
$txtLicenseStatus    = $window.FindName("txtLicenseStatus")
$txtLicenseExpiry    = $window.FindName("txtLicenseExpiry")
$txtHwidShort        = $window.FindName("txtHwidShort")
$btnCopyHwid         = $window.FindName("btnCopyHwid")
$btnChangeLicense    = $window.FindName("btnChangeLicense")

# ============================================================
# LOGO
# ============================================================
try {
    $logoLoaded = $false
    foreach ($lf in @("sr_logo.png", "sr_logo.ico")) {
        $logoPath = Join-Path $PSScriptRoot $lf
        if ((Test-Path $logoPath) -and (Get-Item $logoPath).Length -gt 100) {
            try {
                $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
                $bitmap.BeginInit()
                $bitmap.UriSource = New-Object System.Uri($logoPath)
                $bitmap.CacheOption = "OnLoad"
                $bitmap.EndInit()
                $imgLogo.Source = $bitmap
                $logoLoaded = $true
                break
            } catch { }
        }
    }
    if (-not $logoLoaded) { $imgLogo.Visibility = "Collapsed" }
} catch { $imgLogo.Visibility = "Collapsed" }

# ============================================================
# WINDOW CHROME
# ============================================================
$titleBar.Add_MouseLeftButtonDown({ $window.DragMove() })

# ====================================================================
# Tooltip refocus fix - kada se launcher vrati u focus, NE pokazi
# tooltip odmah jer je to rezultat Alt+Tab/click izvan, a ne hover.
# ====================================================================
$window.Add_Deactivated({
    try { [System.Windows.Controls.ToolTipService]::SetIsEnabled($window, $false) } catch {}
})
$window.Add_Activated({
    try {
        [System.Windows.Controls.ToolTipService]::SetIsEnabled($window, $false)
        $reEnable = New-Object System.Windows.Threading.DispatcherTimer
        $reEnable.Interval = [TimeSpan]::FromMilliseconds(700)
        $reEnable.Add_Tick({
            param($s, $e)
            $s.Stop()
            try { [System.Windows.Controls.ToolTipService]::SetIsEnabled($window, $true) } catch {}
        })
        $reEnable.Start()
    } catch {}
})
$btnMinimize.Add_Click({ $window.WindowState = 'Minimized' })
if ($btnFullscreen) { $btnFullscreen.Add_Click({ Toggle-WindowFullscreen }) }
$window.Add_PreviewKeyDown({
    param($sender, $e)
    if ($e.Key -eq 'F11') {
        Toggle-WindowFullscreen
        $e.Handled = $true
    }
})
$btnClose.Add_Click({ $window.Close() })

# ============================================================
# NAVIGATION
# ============================================================
function Set-Page {
    param([string]$page)
    $pageDash.Visibility = 'Collapsed'
    $pageMods.Visibility = 'Collapsed'
    $pageIgra.Visibility = 'Collapsed'
    $pageMpFolders.Visibility = 'Collapsed'
    $pageSettings.Visibility = 'Collapsed'
    $pageLog.Visibility = 'Collapsed'
    $target = $null
    switch ($page) {
        'dash'     { $pageDash.Visibility = 'Visible'; $target = $pageDash }
        'mods'     { $pageMods.Visibility = 'Visible'; $target = $pageMods }
        'igra'     { $pageIgra.Visibility = 'Visible'; $target = $pageIgra }
        'mpfolders'{ $pageMpFolders.Visibility = 'Visible'; $target = $pageMpFolders }
        'settings' { $pageSettings.Visibility = 'Visible'; $target = $pageSettings }
        'log'      { $pageLog.Visibility = 'Visible'; $target = $pageLog }
    }
    if ($target) {
        try {
            $target.Opacity = 0
            $tt = New-Object System.Windows.Media.TranslateTransform
            $tt.Y = 12
            $target.RenderTransform = $tt
            $sb = New-Object System.Windows.Media.Animation.Storyboard
            $a1 = New-Object System.Windows.Media.Animation.DoubleAnimation
            $a1.From = 0; $a1.To = 1
            $a1.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(220))
            [System.Windows.Media.Animation.Storyboard]::SetTarget($a1, $target)
            [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($a1, [System.Windows.PropertyPath]::new("Opacity"))
            $sb.Children.Add($a1)
            $a2 = New-Object System.Windows.Media.Animation.DoubleAnimation
            $a2.From = 12; $a2.To = 0
            $a2.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(260))
            $a2.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase -Property @{ EasingMode='EaseOut' }
            [System.Windows.Media.Animation.Storyboard]::SetTarget($a2, $tt)
            [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($a2, [System.Windows.PropertyPath]::new("Y"))
            $sb.Children.Add($a2)
            $sb.Begin()
        } catch {}
    }
}
$navDash.Add_Checked({ Set-Page 'dash'; Refresh-ServerStatus -Silent })
$navMods.Add_Checked({
    Set-Page 'mods'
    if (-not $script:ModListCached) {
        if ($script:PreloadedModList) {
            Refresh-ModList -PreloadedServerMods $script:PreloadedModList
            $script:PreloadedModList = $null
        } else {
            Refresh-ModList
        }
    } else {
        Apply-ModFilter (Get-CurrentFilter)
    }
})
$navIgra.Add_Checked({
    Set-Page 'igra'
    if ($txtModProfilePath) { $txtModProfilePath.Text = $script:ModProfilesPath }
    Refresh-IgraPage
})
$navMpFolders.Add_Checked({
    Set-Page 'mpfolders'
    Refresh-MpFoldersPage
})
$navSettings.Add_Checked({
    Set-Page 'settings'
    $gs = Read-GameSettings
    $chkIntroScene.IsChecked = $gs.introScene
    $chkDevConsole.IsChecked = $gs.devConsole
    Sync-GameLaunchUiFromConfig
    Update-LicenseUi
})
$navLog.Add_Checked({ Set-Page 'log' })

if ($btnRefreshSavegames) {
    $btnRefreshSavegames.Add_Click({ Refresh-IgraPage; try { Show-Toast "Savegame lista osvjezena" "success" } catch {} })
}
if ($btnRefreshModProfiles) {
    $btnRefreshModProfiles.Add_Click({
        Ensure-ServerModProfile | Out-Null
        Refresh-IgraPage
        try { Show-Toast "Mod profili osvjezeni" "success" } catch {}
    })
}
if ($btnOpenSaveSlot) {
    $btnOpenSaveSlot.Add_Click({
        $sel = $lstSavegames.SelectedItem
        if (-not $sel -or -not $sel.Folder) {
            Show-SRDialog "Odaberi savegame slot u listi." "Igra" "Warning"
            return
        }
        if (Test-Path $sel.Folder) { Start-Process explorer.exe $sel.Folder }
    })
}
if ($cmbModProfiles) {
    $cmbModProfiles.Add_SelectionChanged({
        $item = $cmbModProfiles.SelectedItem
        if (-not $item) { return }
        $store = Get-ModProfilesStore
        $store.activeProfileId = $item.Id
        Save-ModProfilesStore $store
        Write-Log "Aktivni mod profil: $($item.Label) ($($item.Id))"
    })
}

if ($btnNavFavorites) {
    $btnNavFavorites.Add_Click({
        $navMods.IsChecked = $true
        if ($cmbModShow) {
            $items = @($cmbModShow.ItemsSource)
            $fav = $items | Where-Object { $_.Key -eq 'Favourites' } | Select-Object -First 1
            if ($fav) { $cmbModShow.SelectedItem = $fav }
        }
        Apply-ModFilter 'Favourites'
    })
}
if ($btnNavLibraryMods) {
    $btnNavLibraryMods.Add_Click({
        $navMods.IsChecked = $true
    })
}

function Apply-SelectedMpFolder {
    param($Item)
    if (-not $Item -or -not $Item.Id) { return }
    $store = Get-MultiplayerFoldersStore
    $rec = Get-MpFolderRecord -FolderId $Item.Id -Store $store
    if ($rec) { $rec.useMainLibrary = $false }
    Set-ActiveMpFolderForServer $Item.Id
    Save-MultiplayerFoldersStore $store
    Refresh-MpFoldersPage
}

if ($cmbMpFolderQuick) {
    $cmbMpFolderQuick.Add_SelectionChanged({
        if ($script:MpFolderComboUpdating) { return }
        $item = $cmbMpFolderQuick.SelectedItem
        if ($item) { Apply-SelectedMpFolder $item }
    })
}
if ($cmbMpFolderSelect) {
    $cmbMpFolderSelect.Add_SelectionChanged({
        if ($script:MpFolderComboUpdating) { return }
        $item = $cmbMpFolderSelect.SelectedItem
        if ($item) {
            $script:MpFolderComboUpdating = $true
            try {
                if ($cmbMpFolderQuick) { $cmbMpFolderQuick.SelectedItem = $item }
            } finally { $script:MpFolderComboUpdating = $false }
        }
    })
}
if ($btnMpApply) {
    $btnMpApply.Add_Click({
        $item = if ($cmbMpFolderSelect) { $cmbMpFolderSelect.SelectedItem } else { $null }
        if (-not $item) {
            Show-SRDialog "Odaberi folder u listi." "Multiplayer folderi" "Warning"
            return
        }
        Apply-SelectedMpFolder $item
        try { Show-Toast "Mod folder primijenjen: $($item.Label)" "success" } catch {}
    })
}
if ($btnMpActivateLaunch) {
    $btnMpActivateLaunch.Add_Click({
        $item = if ($cmbMpFolderSelect) { $cmbMpFolderSelect.SelectedItem } else { $null }
        if ($item) { Apply-SelectedMpFolder $item }
        Join-Server
    })
}
if ($btnMpRefresh) {
    $btnMpRefresh.Add_Click({ Refresh-MpFoldersPage; try { Show-Toast "Folderi osvjezeni" "success" } catch {} })
}
if ($btnMpResetMain) {
    $btnMpResetMain.Add_Click({
        Reset-MpFolderToMainLibrary
        Refresh-MpFoldersPage
        try { Show-Toast "Koristi se glavna biblioteka modova" "success" } catch {}
    })
}
if ($btnMpCreateFolder) {
    $btnMpCreateFolder.Add_Click({
        Ensure-ServerMpFolder | Out-Null
        $id = Get-ServerMpFolderId
        $store = Get-MultiplayerFoldersStore
        $rec = Get-MpFolderRecord -FolderId $id -Store $store
        if (-not $rec) { return }
        $path = [string]$rec.path
        if (-not $path) {
            $parent = if ($script:Config.modsPath) { Split-Path $script:Config.modsPath -Parent } else { $env:USERPROFILE }
            $srv = Get-ActiveServer
            $slug = ($srv.name -replace '[^a-zA-Z0-9]', '')
            if (-not $slug) { $slug = "Server$($script:Config.activeServer)" }
            $path = Join-Path $parent "SR-Mods-$slug"
        }
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Write-Log "Kreiran folder: $path"
        }
        $rec.path = $path
        $rec.useMainLibrary = $false
        $rec.updatedAt = (Get-Date).ToString("o")
        Save-MultiplayerFoldersStore $store
        Set-ActiveMpFolderForServer $id
        Refresh-MpFoldersPage
        try { Show-Toast "Folder spreman" "success" } catch {}
    })
}
if ($btnMpAddFolder) {
    $btnMpAddFolder.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $eff = Get-EffectiveModsPath
        if ($eff -and (Test-Path $eff)) { $d.SelectedPath = $eff }
        elseif ($script:Config.modsPath) { $d.SelectedPath = $script:Config.modsPath }
        if ($d.ShowDialog() -ne 'OK') { return }
        $path = $d.SelectedPath
        $store = Ensure-ServerMpFolder
        $id = Get-ServerMpFolderId
        $rec = Get-MpFolderRecord -FolderId $id -Store $store
        if ($rec) {
            $rec.path = $path
            $rec.useMainLibrary = $false
            $rec.label = Split-Path $path -Leaf
            $rec.updatedAt = (Get-Date).ToString("o")
        }
        Save-MultiplayerFoldersStore $store
        Set-ActiveMpFolderForServer $id
        Refresh-MpFoldersPage
        try { Show-Toast "Folder dodan" "success" } catch {}
    })
}
if ($btnMpRemoveFolder) {
    $btnMpRemoveFolder.Add_Click({
        $sel = $lstMpFolders.SelectedItem
        if (-not $sel) {
            Show-SRDialog "Odaberi folder u listi." "Multiplayer folderi" "Warning"
            return
        }
        $r = Show-SRConfirm "Ukloniti '$($sel.Label)' iz liste?`n(Datoteke na disku ostaju.)" "Potvrda"
        if ($r -ne 'Yes') { return }
        $store = Get-MultiplayerFoldersStore
        $folders = @{}
        if ($store.folders) {
            $store.folders.PSObject.Properties | ForEach-Object {
                if ($_.Name -ne $sel.Id) { $folders[$_.Name] = $_.Value }
            }
        }
        $store.folders = $folders
        Save-MultiplayerFoldersStore $store
        Ensure-ServerMpFolder | Out-Null
        Refresh-MpFoldersPage
    })
}
if ($lstMpFolders) {
    $lstMpFolders.Add_MouseDoubleClick({
        $sel = $lstMpFolders.SelectedItem
        if (-not $sel) { return }
        Set-MpFolderFavorite -FolderId $sel.Id -Favorite (-not $sel.IsFavorite)
        Refresh-MpFoldersPage
    })
}

# ============================================================
# WALKTHROUGH (Getting Started)
# ============================================================
$script:WalkthroughSteps = @(
    @{
        Title = 'Dobrodosli u SR Manager'
        Body  = "Launcher za Farming Simulator 25 community Slavonska Ravnica.`n`nOvaj vodic ce te provesti kroz osnovne korake: server, modovi, save i ulaz u igru."
    }
    @{
        Title = 'Odaberi server'
        Body  = "Na lijevoj strani odaberi SR server (gumb s imenom servera).`n`nStatus ONLINE i ping vidis na nadzornoj ploci."
    }
    @{
        Title = 'Skini modove'
        Body  = "Otvori Upravitelj modova, klikni Osvjezi ili Ponovno skeniraj, zatim Skini Sve Sto Fali.`n`nModovi se usporeduju SHA-256 hashom (bot API) kad je dostupan."
    }
    @{
        Title = 'Kreiraj save u FS25'
        Body  = "Pokreni FS25 i napravi novi savegame (karijera).`n`nU tabu Savegame vidis slotove nakon sto spremis igru - klikni Osvjezi savegame."
    }
    @{
        Title = 'Pridruzi se serveru'
        Body  = "Na Nadzornoj ploci klikni Udi na server / Pokreni igru.`n`nLauncher sinkronizira modove prije starta (ako su postavke ukljucene)."
    }
    @{
        Title = 'Spremno za igru'
        Body  = "Licenca, auto-update i postavke su u tabu Postavke.`n`nUgodnu igru na Slavonskoj Ravnici!"
    }
)
$script:WalkthroughIndex = 0

function Update-WalkthroughStep {
    $idx = $script:WalkthroughIndex
    $steps = $script:WalkthroughSteps
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $steps.Count) { $idx = $steps.Count - 1 }
    $script:WalkthroughIndex = $idx
    $step = $steps[$idx]
    $wtTitle.Text = $step.Title
    $wtBody.Text = $step.Body
    $wtProgress.Maximum = $steps.Count
    $wtProgress.Value = $idx + 1
    $wtStepLabel.Text = "Korak $($idx + 1) / $($steps.Count)"
    $btnWtPrev.Visibility = if ($idx -gt 0) { 'Visible' } else { 'Collapsed' }
    $btnWtNext.Content = if ($idx -ge ($steps.Count - 1)) { 'Zavrsi' } else { 'Dalje' }
    $ws = Get-WalkthroughSettings
    if ($chkWtSkipLaunch) { $chkWtSkipLaunch.IsChecked = [bool]$ws.skipOnLaunch }
}

function Show-WalkthroughOverlay {
    $script:WalkthroughIndex = 0
    Update-WalkthroughStep
    $walkthroughOverlay.Visibility = 'Visible'
}

function Hide-WalkthroughOverlay {
    param([switch]$Completed)
    $walkthroughOverlay.Visibility = 'Collapsed'
    $ws = Get-WalkthroughSettings
    if ($chkWtSkipLaunch -and $chkWtSkipLaunch.IsChecked) { $ws.skipOnLaunch = $true }
    if ($Completed) { $ws.completed = $true; $ws.lastStep = $script:WalkthroughSteps.Count - 1 }
    $ws.lastStep = $script:WalkthroughIndex
    Save-WalkthroughSettings $ws
    if ($chkHideWalkthrough) { $chkHideWalkthrough.IsChecked = [bool]$ws.skipOnLaunch }
}

if ($btnWtNext) {
    $btnWtNext.Add_Click({
        if ($script:WalkthroughIndex -ge ($script:WalkthroughSteps.Count - 1)) {
            Hide-WalkthroughOverlay -Completed
            try { Show-Toast "Vodic zavrsen - ugodnu igru!" "success" } catch {}
        } else {
            $script:WalkthroughIndex++
            Update-WalkthroughStep
        }
    })
}
if ($btnWtPrev) {
    $btnWtPrev.Add_Click({
        if ($script:WalkthroughIndex -gt 0) {
            $script:WalkthroughIndex--
            Update-WalkthroughStep
        }
    })
}
if ($btnWtSkip) {
    $btnWtSkip.Add_Click({ Hide-WalkthroughOverlay })
}
if ($chkWtSkipLaunch) {
    $chkWtSkipLaunch.Add_Checked({
        $ws = Get-WalkthroughSettings
        $ws.skipOnLaunch = $true
        Save-WalkthroughSettings $ws
        if ($chkHideWalkthrough) { $chkHideWalkthrough.IsChecked = $true }
    })
    $chkWtSkipLaunch.Add_Unchecked({
        $ws = Get-WalkthroughSettings
        $ws.skipOnLaunch = $false
        Save-WalkthroughSettings $ws
        if ($chkHideWalkthrough) { $chkHideWalkthrough.IsChecked = $false }
    })
}
if ($btnShowWalkthrough) {
    $btnShowWalkthrough.Add_Click({ Show-WalkthroughOverlay })
}
if ($chkHideWalkthrough) {
    $chkHideWalkthrough.Add_Checked({
        $ws = Get-WalkthroughSettings
        $ws.skipOnLaunch = $true
        Save-WalkthroughSettings $ws
    })
    $chkHideWalkthrough.Add_Unchecked({
        $ws = Get-WalkthroughSettings
        $ws.skipOnLaunch = $false
        Save-WalkthroughSettings $ws
    })
}

# ============================================================
# SAVE WIZARD (Hub-style skeleton)
# ============================================================
function Show-SaveWizard {
    $dlg = New-Object System.Windows.Window
    $dlg.Title = 'Save wizard'
    $dlg.Width = 560
    $dlg.SizeToContent = 'Height'
    $dlg.WindowStartupLocation = 'CenterOwner'
    $dlg.Owner = $window
    $dlg.WindowStyle = 'None'
    $dlg.AllowsTransparency = $true
    $dlg.Background = [System.Windows.Media.Brushes]::Transparent
    $dlg.ShowInTaskbar = $false
    $dlg.ResizeMode = 'NoResize'

    $outer = New-Object System.Windows.Controls.Border
    $outer.CornerRadius = '12'
    $outer.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#121212')
    $outer.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F5C518')
    $outer.BorderThickness = '1'
    $outer.Padding = '24,22'
    $sp = New-Object System.Windows.Controls.StackPanel

    $ttl = New-Object System.Windows.Controls.TextBlock
    $ttl.Text = 'SAVE WIZARD'
    $ttl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F5C518')
    $ttl.FontSize = 18
    $ttl.FontWeight = 'Bold'
    $ttl.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
    $sp.Children.Add($ttl) | Out-Null

    $stepLbl = New-Object System.Windows.Controls.TextBlock
    $stepLbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#888')
    $stepLbl.FontSize = 11
    $stepLbl.Margin = '0,6,0,14'
    $stepLbl.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
    $sp.Children.Add($stepLbl) | Out-Null

    $body = New-Object System.Windows.Controls.TextBlock
    $body.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#ccc')
    $body.FontSize = 12
    $body.TextWrapping = 'Wrap'
    $body.Margin = '0,0,0,10'
    $body.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
    $sp.Children.Add($body) | Out-Null

    $contentHost = New-Object System.Windows.Controls.StackPanel
    $contentHost.Margin = '0,0,0,12'
    $sp.Children.Add($contentHost) | Out-Null

    $lstSaves = New-Object System.Windows.Controls.ListBox
    $lstSaves.MaxHeight = 200
    $lstSaves.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0d0d0d')
    $lstSaves.Foreground = [System.Windows.Media.Brushes]::White
    $lstSaves.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#333')
    $lstSaves.DisplayMemberPath = 'DisplayLine'
    $lstSaves.Visibility = 'Collapsed'

    $txtMods = New-Object System.Windows.Controls.TextBox
    $txtMods.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#1a1a1a')
    $txtMods.Foreground = [System.Windows.Media.Brushes]::White
    $txtMods.Padding = '10,8'
    $txtMods.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#333')
    $txtMods.Visibility = 'Collapsed'

    $chkBackup = New-Object System.Windows.Controls.CheckBox
    $chkBackup.Content = 'Napravi backup prije promjena (preporuceno)'
    $chkBackup.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#aaa')
    $chkBackup.IsChecked = $true
    $chkBackup.Visibility = 'Collapsed'
    $chkBackup.Margin = '0,0,0,8'
    $chkBackup.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')

    $contentHost.Children.Add($lstSaves) | Out-Null
    $contentHost.Children.Add($txtMods) | Out-Null
    $contentHost.Children.Add($chkBackup) | Out-Null

    $bp = New-Object System.Windows.Controls.StackPanel
    $bp.Orientation = 'Horizontal'
    $bp.HorizontalAlignment = 'Right'

    $btnCancel = New-Object System.Windows.Controls.Button
    $btnCancel.Content = 'Odustani'
    $btnCancel.Padding = '14,8'
    $btnCancel.Margin = '0,0,8,0'
    $btnCancel.Cursor = 'Hand'
    $btnCancel.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#222')
    $btnCancel.Foreground = [System.Windows.Media.Brushes]::White
    $btnCancel.BorderThickness = '0'

    $btnBack = New-Object System.Windows.Controls.Button
    $btnBack.Content = 'Natrag'
    $btnBack.Padding = '14,8'
    $btnBack.Margin = '0,0,8,0'
    $btnBack.Cursor = 'Hand'
    $btnBack.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#222')
    $btnBack.Foreground = [System.Windows.Media.Brushes]::White
    $btnBack.BorderThickness = '0'
    $btnBack.Visibility = 'Collapsed'

    $btnNext = New-Object System.Windows.Controls.Button
    $btnNext.Content = 'Dalje'
    $btnNext.Padding = '18,8'
    $btnNext.Cursor = 'Hand'
    $btnNext.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F5C518')
    $btnNext.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#111')
    $btnNext.FontWeight = 'Bold'
    $btnNext.BorderThickness = '0'

    $bp.Children.Add($btnCancel) | Out-Null
    $bp.Children.Add($btnBack) | Out-Null
    $bp.Children.Add($btnNext) | Out-Null
    $sp.Children.Add($bp) | Out-Null
    $outer.Child = $sp
    $dlg.Content = $outer

    $state = @{
        Step         = 1
        SelectedSave = $null
        ModsPath     = if ($script:Config.modsPath) { [string]$script:Config.modsPath } else { '' }
    }

    $render = {
        $s = $state.Step
        $stepLbl.Text = "Korak $s / 6"
        $lstSaves.Visibility = 'Collapsed'
        $txtMods.Visibility = 'Collapsed'
        $chkBackup.Visibility = 'Collapsed'
        $btnBack.Visibility = if ($s -gt 1) { 'Visible' } else { 'Collapsed' }
        $btnNext.Content = if ($s -ge 6) { 'Zavrsi' } else { 'Dalje' }
        switch ($s) {
            1 {
                $body.Text = 'Odaberi FS25 savegame slot:'
                $lstSaves.Visibility = 'Visible'
                $items = @()
                foreach ($sg in @(Get-FS25SavegameList)) {
                    $label = if ($sg.Name) { $sg.Name } else { "Slot $($sg.Slot)" }
                    $items += [PSCustomObject]@{
                        DisplayLine = "Slot $($sg.Slot): $label | $($sg.MapTitle) | $($sg.SizeMb) MB"
                        SaveInfo    = $sg
                    }
                }
                $lstSaves.ItemsSource = $items
                if ($state.SelectedSave) {
                    $match = $items | Where-Object { $_.SaveInfo.Slot -eq $state.SelectedSave.Slot } | Select-Object -First 1
                    if ($match) { $lstSaves.SelectedItem = $match }
                }
            }
            2 {
                $body.Text = 'Mods folder za ovaj profil (gameSettings.xml sync u kasnijim koracima):'
                $txtMods.Visibility = 'Visible'
                $txtMods.Text = $state.ModsPath
            }
            3 {
                $body.Text = 'Postavke savea (careerSavegame.xml) - skeleton. Backup prije uredivanja.'
                $chkBackup.Visibility = 'Visible'
            }
            4 {
                $body.Text = 'Mod loadout (profil modova) - skeleton. Povezivanje s mod-profiles.json kasnije.'
            }
            5 {
                $body.Text = 'Potvrda - skeleton. Backup + primjena u sljedecoj verziji.'
                $chkBackup.Visibility = 'Visible'
            }
            6 {
                $body.Text = 'Zavrsni pregled:'
                $sel = if ($state.SelectedSave) { "Slot $($state.SelectedSave.Slot) - $($state.SelectedSave.Name)" } else { '(nije odabran)' }
                $body.Text += "`nSave: $sel`nMods: $($state.ModsPath)`nBackup: $(if ($chkBackup.IsChecked) { 'da' } else { 'ne' })"
                $chkBackup.Visibility = 'Visible'
            }
        }
    }.GetNewClosure()

    $btnCancel.Add_Click({ $dlg.Close() })
    $btnBack.Add_Click({
        if ($state.Step -gt 1) { $state.Step--; & $render }
    })
    $btnNext.Add_Click({
        if ($state.Step -eq 1) {
            if (-not $lstSaves.SelectedItem) {
                Show-SRDialog 'Odaberi savegame slot u listi.' 'Save wizard' 'Warning'
                return
            }
            $state.SelectedSave = $lstSaves.SelectedItem.SaveInfo
        }
        if ($state.Step -eq 2) {
            $state.ModsPath = $txtMods.Text.Trim()
            if ($state.ModsPath -and -not (Test-Path $state.ModsPath)) {
                $r = Show-SRConfirm "Folder ne postoji:`n$($state.ModsPath)`n`nNastaviti?" 'Save wizard' 'Da' 'Ne'
                if ($r -ne 'Yes') { return }
            }
        }
        if ($state.Step -ge 6) {
            if ($chkBackup.IsChecked -and $state.SelectedSave -and $state.SelectedSave.Folder -and (Test-Path $state.SelectedSave.Folder)) {
                try {
                    $bakRoot = Join-Path $env:APPDATA 'SR-Launcher\save-backups'
                    if (-not (Test-Path $bakRoot)) { New-Item -ItemType Directory -Path $bakRoot -Force | Out-Null }
                    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                    $dest = Join-Path $bakRoot "savegame$($state.SelectedSave.Slot)_$stamp"
                    Copy-Item $state.SelectedSave.Folder $dest -Recurse -Force
                    Write-Log "Save wizard backup: $dest"
                    try { Show-Toast "Backup spremljen" 'success' } catch {}
                } catch {
                    Show-SRDialog "Backup nije uspio:`n$($_.Exception.Message)" 'Save wizard' 'Warning'
                    return
                }
            }
            if ($state.ModsPath) {
                $script:Config.modsPath = $state.ModsPath
                if ($txtModsPath) { $txtModsPath.Text = $state.ModsPath }
                Save-Config
            }
            $dlg.Close()
            try { Show-Toast 'Save wizard zavrsen (skeleton koraci 3-5 uskoro)' 'success' 4500 } catch {}
            return
        }
        $state.Step++
        & $render
    })

    & $render
    $dlg.ShowDialog() | Out-Null
}

if ($btnSaveWizard) {
    $btnSaveWizard.Add_Click({ Show-SaveWizard })
}

# ============================================================
# LOGGING
# ============================================================
function Write-Log {
    param([string]$msg)
    $timestamp = Get-Date -Format "HH:mm:ss"
    if (-not $script:LogBuffer) { $script:LogBuffer = New-Object System.Collections.ArrayList }
    [void]$script:LogBuffer.Add("[$timestamp] $msg")
    while ($script:LogBuffer.Count -gt 2000) { $script:LogBuffer.RemoveAt(0) }
    $filter = ""
    if ($txtLogSearch -and $txtLogSearch.Text -and $txtLogSearch.Text -notmatch '^Pretrazi') {
        $filter = $txtLogSearch.Text
    }
    if ($filter) {
        $lines = @($script:LogBuffer | Where-Object { $_ -match [regex]::Escape($filter) })
    } else {
        $lines = @($script:LogBuffer)
    }
    $txtLog.Text = ($lines -join "`r`n")
    if ($txtLogCount) { $txtLogCount.Text = "$($script:LogBuffer.Count) redova" }
    if ($chkLogAutoScroll -and $chkLogAutoScroll.IsChecked) { $txtLog.ScrollToEnd() }
    # Activity feed (zadnjih 8)
    if (-not $script:ActivityFeed) { $script:ActivityFeed = New-Object System.Collections.ArrayList }
    [void]$script:ActivityFeed.Insert(0, [PSCustomObject]@{ Time=$timestamp; Message=$msg })
    while ($script:ActivityFeed.Count -gt 8) { $script:ActivityFeed.RemoveAt($script:ActivityFeed.Count - 1) }
    if ($lstActivityFeed) {
        try { $lstActivityFeed.ItemsSource = $null; $lstActivityFeed.ItemsSource = $script:ActivityFeed } catch {}
    }
}

# ============================================================
# SERVER SELECTOR
# ============================================================
function Update-ServerButtons {
    $serverButtonsPanel.Children.Clear()
    if (-not $script:ServerPings) { $script:ServerPings = @{} }
    for ($i = 0; $i -lt $script:Config.servers.Count; $i++) {
        $srv = $script:Config.servers[$i]
        $isActive = ($i -eq [int]$script:Config.activeServer)
        $isCustom = [bool]($srv.PSObject.Properties.Name -contains 'isCustom' -and $srv.isCustom)

        $bd = New-Object System.Windows.Controls.Border
        $bd.CornerRadius = "6"
        $bd.Padding = "10,7"
        $bd.Margin = "0,2"
        $bd.Cursor = "Hand"
        $bd.Tag = $i

        # Glavni grid: server name | ping
        $grid = New-Object System.Windows.Controls.Grid
        $col1 = New-Object System.Windows.Controls.ColumnDefinition; $col1.Width = "*"
        $col2 = New-Object System.Windows.Controls.ColumnDefinition; $col2.Width = "Auto"
        $grid.ColumnDefinitions.Add($col1); $grid.ColumnDefinitions.Add($col2)

        # Lijevo: ime + (custom badge)
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = "Horizontal"
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $srv.name
        $tb.FontSize = 11
        $tb.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
        $tb.IsHitTestVisible = $false
        $tb.VerticalAlignment = "Center"
        $tb.TextTrimming = "CharacterEllipsis"
        $sp.Children.Add($tb) | Out-Null
        if ($isCustom) {
            $badge = New-Object System.Windows.Controls.Border
            $badge.CornerRadius = "3"
            $badge.Padding = "4,1"
            $badge.Margin = "6,0,0,0"
            $badge.VerticalAlignment = "Center"
            $badge.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#2a2a2a")
            $bt = New-Object System.Windows.Controls.TextBlock
            $bt.Text = "MOJ"
            $bt.FontSize = 8
            $bt.FontWeight = "Bold"
            $bt.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#999")
            $bt.IsHitTestVisible = $false
            $badge.Child = $bt
            $sp.Children.Add($badge) | Out-Null
        }
        [System.Windows.Controls.Grid]::SetColumn($sp, 0)
        $grid.Children.Add($sp) | Out-Null

        # Desno: ping
        $pingTb = New-Object System.Windows.Controls.TextBlock
        $pingKey = "$($srv.ip):$($srv.webPort)"
        $pingMs = $script:ServerPings[$pingKey]
        if ($pingMs -is [int] -and $pingMs -ge 0) {
            $pingTb.Text = "$pingMs ms"
            if ($pingMs -lt 60)        { $pingTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#30A46C") }
            elseif ($pingMs -lt 150)   { $pingTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F5C518") }
            else                        { $pingTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#E5484D") }
        } elseif ($pingMs -eq -1) {
            $pingTb.Text = "X"
            $pingTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#E5484D")
        } else {
            $pingTb.Text = "..."
            $pingTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#555")
        }
        $pingTb.FontSize = 9
        $pingTb.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
        $pingTb.VerticalAlignment = "Center"
        $pingTb.IsHitTestVisible = $false
        [System.Windows.Controls.Grid]::SetColumn($pingTb, 1)
        $grid.Children.Add($pingTb) | Out-Null

        if ($isActive) {
            $bd.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F5C518")
            $tb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#111")
            $tb.FontWeight = "SemiBold"
        } else {
            $bd.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#1a1a1a")
            $tb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#ccc")
            $tb.FontWeight = "Normal"
        }

        $bd.Child = $grid
        $bd.ToolTip = "$($srv.name)`n$($srv.ip):$($srv.gamePort)`nKlik = aktiviraj  |  Desni klik = opcije"
        $bd.Add_MouseLeftButtonDown({
            param($sender, $e)
            $idx = [int]$sender.Tag
            $script:Config.activeServer = $idx
            Save-Config
            Update-ServerButtons
            Refresh-ServerStatus
            if ($script:IsAdmin) { Load-ServerToForm }
            Write-Log "Server: $($script:Config.servers[$idx].name)"
            try {
                Ensure-ServerMpFolder | Out-Null
                Sync-MpFolderQuickPick
                Refresh-MpFoldersPage
            } catch {}
        })
        # Desni klik: brisi custom server
        $bd.Add_MouseRightButtonUp({
            param($sender, $e)
            $idx = [int]$sender.Tag
            $srv = $script:Config.servers[$idx]
            $isC = [bool]($srv.PSObject.Properties.Name -contains 'isCustom' -and $srv.isCustom)
            if (-not $isC) {
                Show-Toast "Sluzbeni serveri se ne mogu brisati" "warn"
                return
            }
            $r = Show-SRConfirm "Obrisati custom server '$($srv.name)'?" "SR Launcher" "Da" "Ne"
            if ($r -eq 'Yes') {
                $script:Config.servers = @($script:Config.servers | Where-Object { $_ -ne $srv })
                if ([int]$script:Config.activeServer -ge $script:Config.servers.Count) {
                    $script:Config.activeServer = 0
                }
                Save-Config
                Update-ServerButtons
                Refresh-ServerStatus
                Show-Toast "Server obrisan" "success"
            }
        })

        $serverButtonsPanel.Children.Add($bd) | Out-Null
    }
}

function Update-ServerPings {
    if (-not $script:ServerPings) { $script:ServerPings = @{} }
    foreach ($srv in $script:Config.servers) {
        $key = "$($srv.ip):$($srv.webPort)"
        try {
            $ping = New-Object System.Net.NetworkInformation.Ping
            $reply = $ping.Send($srv.ip, 1500)
            if ($reply.Status -eq 'Success') {
                $script:ServerPings[$key] = [int]$reply.RoundtripTime
            } else {
                $script:ServerPings[$key] = -1
            }
        } catch { $script:ServerPings[$key] = -1 }
    }
    Update-ServerButtons
}

# ============================================================
# GAME SETTINGS (gameSettings.xml)
# ============================================================
function Get-GameSettingsPath {
    # Provjeri vise mogucih lokacija za gameSettings.xml
    $candidates = @(
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) "My Games\FarmingSimulator2025\gameSettings.xml"),
        (Join-Path $env:USERPROFILE "Documents\My Games\FarmingSimulator2025\gameSettings.xml"),
        (Join-Path $env:USERPROFILE "OneDrive\Documents\My Games\FarmingSimulator2025\gameSettings.xml")
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    # Ako nijedna ne postoji, pokusaj pronaci FS25 folder
    $searchRoots = @(
        [Environment]::GetFolderPath('MyDocuments'),
        (Join-Path $env:USERPROFILE "Documents"),
        (Join-Path $env:USERPROFILE "OneDrive\Documents")
    )
    foreach ($root in $searchRoots) {
        $fs25Dir = Join-Path $root "My Games\FarmingSimulator2025"
        if (Test-Path $fs25Dir) {
            return Join-Path $fs25Dir "gameSettings.xml"
        }
    }
    # Fallback na standardni put
    return $candidates[0]
}

function Read-GameSettings {
    $gsPath = Get-GameSettingsPath
    $result = @{ introScene = $true; devConsole = $false }
    if (Test-Path $gsPath) {
        try {
            $content = Get-Content $gsPath -Raw -Encoding UTF8
            # FS25 koristi razne formate: <tag>value</tag> ili <tag value="..."/>
            if ($content -match '<isIntroActive>([^<]*)</isIntroActive>') {
                $result.introScene = ($Matches[1].Trim() -eq "true")
            } elseif ($content -match '<isIntroActive\s+value="([^"]*)"') {
                $result.introScene = ($Matches[1] -eq "true")
            }
            if ($content -match '<developmentControls>([^<]*)</developmentControls>') {
                $result.devConsole = ($Matches[1].Trim() -eq "true")
            } elseif ($content -match '<developmentControls\s+value="([^"]*)"') {
                $result.devConsole = ($Matches[1] -eq "true")
            }
        } catch {}
    }
    return $result
}

function Write-GameSetting {
    param([string]$settingTag, [string]$value)
    $gsPath = Get-GameSettingsPath
    if (-not (Test-Path $gsPath)) {
        Write-Log "UPOZORENJE: gameSettings.xml ne postoji: $gsPath"
        return $false
    }
    try {
        $content = Get-Content $gsPath -Raw -Encoding UTF8
        # FS25 format: <tag>value</tag>
        $patternText = '<' + $settingTag + '>([^<]*)</' + $settingTag + '>'
        # Fallback: <tag value="..."/>
        $patternAttr = '<' + $settingTag + '\s+value="[^"]*"'
        if ($content -match $patternText) {
            $content = $content -replace $patternText, "<$settingTag>$value</$settingTag>"
            Set-Content $gsPath $content -Encoding UTF8
            return $true
        } elseif ($content -match $patternAttr) {
            $content = $content -replace $patternAttr, "<$settingTag value=""$value"""
            Set-Content $gsPath $content -Encoding UTF8
            return $true
        } else {
            # Tag ne postoji - dodaj ga prije </gameSettings>
            if ($content -match '</gameSettings>') {
                $content = $content -replace '</gameSettings>', "    <$settingTag>$value</$settingTag>`n</gameSettings>"
                Set-Content $gsPath $content -Encoding UTF8
                Write-Log "Dodan tag '$settingTag' u gameSettings.xml"
                return $true
            }
            Write-Log "GRESKA: Ne mogu dodati '$settingTag' u gameSettings.xml"
            return $false
        }
    } catch {
        Write-Log "GRESKA: $($_.Exception.Message)"
        return $false
    }
}

function Update-ModsDirectoryOverride {
    param([string]$modsPath)
    $gsPath = Get-GameSettingsPath
    if (-not (Test-Path $gsPath)) { return $false }
    try {
        $content = Get-Content $gsPath -Raw -Encoding UTF8
        # FS25 format: <modsDirectoryOverride active="true" directory="path"/>
        if ($content -match '<modsDirectoryOverride\s+active="[^"]*"\s+directory="[^"]*"') {
            $content = $content -replace '<modsDirectoryOverride\s+active="[^"]*"\s+directory="[^"]*"', "<modsDirectoryOverride active=`"true`" directory=`"$modsPath`""
        } elseif ($content -match '<modsDirectoryOverride[^/]*/>') {
            $content = $content -replace '<modsDirectoryOverride[^/]*/>', "<modsDirectoryOverride active=`"true`" directory=`"$modsPath`"/>"
        } elseif ($content -match '</gameSettings>') {
            $content = $content -replace '</gameSettings>', "    <modsDirectoryOverride active=`"true`" directory=`"$modsPath`"/>`n</gameSettings>"
        } else {
            Write-Log "GRESKA: Nije moguce postaviti modsDirectoryOverride"
            return $false
        }
        Set-Content $gsPath $content -Encoding UTF8
        Write-Log "modsDirectoryOverride postavljen na: $modsPath"
        return $true
    } catch {
        Write-Log "GRESKA modsOverride: $($_.Exception.Message)"
        return $false
    }
}

# ============================================================
# MOD FILTER
# ============================================================
$script:AllModItems = @()

function Get-CurrentFilter {
    if ($filterServer.IsChecked)  { return "Server" }
    if ($filterMissing.IsChecked) { return "Missing" }
    if ($filterExtra.IsChecked)   { return "Extra" }
    if ($filterLocal.IsChecked)   { return "Local" }
    return "All"
}

function Get-CurrentModCategoryFilter {
    if (-not $cmbModShow -or -not $cmbModShow.SelectedItem) { return 'All' }
    return [string]$cmbModShow.SelectedItem.Key
}

function Apply-ModFilter {
    param([string]$filter = "All", [string]$CategoryFilter = 'All')
    if ($filter -eq 'All' -and $CategoryFilter -eq 'All') {
        $filter = Get-CurrentFilter
        $CategoryFilter = Get-CurrentModCategoryFilter
    }
    Sync-ModFavoriteFlags
    $searchText = if ($txtModSearch -and $txtModSearch.Text) { $txtModSearch.Text.Trim().ToLower() } else { "" }
    $filtered = New-Object System.Collections.ArrayList
    foreach ($item in $script:AllModItems) {
        $show = switch ($filter) {
            "Server"  { $item.Server -like "Da*" }
            "Missing" { $item.Status -eq "FALI" -or $item.Status -eq "ZASTARIO" }
            "Extra"   { $item.Status -eq "Extra" }
            "Local"   { $item.Local -eq "Da" }
            default   { $true }
        }
        if ($show -and $CategoryFilter -eq 'Favourites') {
            $show = [bool]$item.IsFavorite
        }
        elseif ($show -and $CategoryFilter -ne 'All') {
            $mt = if ($item.ModType) { $item.ModType } else { 'Other' }
            $show = ($mt -eq $CategoryFilter)
        }
        if ($show -and $searchText) {
            $show = $item.Name.ToLower().Contains($searchText) -or $item.Category.ToLower().Contains($searchText)
        }
        if ($show) { [void]$filtered.Add($item) }
    }
    $sorted = @($filtered | Sort-Object ModTypeSort, Name)
    $lstMods.ItemsSource = $sorted
    if ($txtModsVisible) { $txtModsVisible.Text = "$($sorted.Count)" }
    if ($txtModSubtitle) {
        $sub = "Prikazano $($sorted.Count) modova"
        if ($CategoryFilter -ne 'All') { $sub += " | $(Get-ModCategoryHrLabel $CategoryFilter)" }
        if ($searchText) { $sub += " | pretraga: '$searchText'" }
        $txtModSubtitle.Text = $sub
    }
    Start-ModThumbnailLoads -Items $sorted
}

# ============================================================
# SERVER STATUS
# ============================================================
function Refresh-ServerStatus {
    param([switch]$Silent, $PreloadedStatus)
    $status = if ($PreloadedStatus) { $PreloadedStatus } else { Get-ServerStatus }
    $green = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#30A46C")
    $red   = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#E5484D")

    if ($status.online) {
        $statusDot.Fill = $green
        if ($statusDotBig) { try { $statusDotBig.Fill = $green } catch {} }
        if ($dashStatusBrush) { $dashStatusBrush.Color = [System.Windows.Media.ColorConverter]::ConvertFromString("#30A46C") }
        if ($dashStatusGlow)  { $dashStatusGlow.Color  = [System.Windows.Media.ColorConverter]::ConvertFromString("#30A46C") }
        $txtStatus.Text = "ONLINE"
        $txtStatus.Foreground = $green
        $txtServerName.Text = $status.name
        $txtServerMap.Text = $status.map
        $txtServerPlayers.Text = "$($status.playersOnline) / $($status.playersMax)"
        if ($status.players.Count -gt 0) {
            $txtPlayerList.Text = "Online: $($status.players -join ', ')"
            # Build chip view models
            if ($lstPlayerChips) {
                $vm = New-Object System.Collections.ArrayList
                foreach ($po in @($status.playerObjs)) {
                    $disc = $po.Discord
                    $discTag = if ($disc -and $disc.name) { "Discord: $($disc.name)" } else { "" }
                    $discVis = if ($discTag) { "Visible" } else { "Collapsed" }
                    $admVis  = if ($po.IsAdmin) { "Visible" } else { "Collapsed" }
                    $role    = if ($po.IsAdmin) { "Administrator" } else { "Igrac" }
                    $roleC   = if ($po.IsAdmin) { "#E5484D" } else { "#30A46C" }
                    $init    = if ($po.Name) { ([string]$po.Name).Substring(0,1).ToUpper() } else { "?" }
                    [void]$vm.Add([PSCustomObject]@{
                        Name = $po.Name; Initial = $init
                        UptimeStr = $po.UptimeStr
                        AdminVisible = $admVis
                        DiscordTag = $discTag; DiscordVisible = $discVis
                        RoleStr = $role; RoleColor = $roleC
                    })
                }
                $lstPlayerChips.ItemsSource = $vm
                $lstPlayerChips.Visibility = "Visible"
                $txtPlayerList.Visibility = "Collapsed"
            }
        } else {
            $txtPlayerList.Text = "Nitko nije online"
            if ($lstPlayerChips) {
                $lstPlayerChips.ItemsSource = $null
                $lstPlayerChips.Visibility = "Collapsed"
                $txtPlayerList.Visibility = "Visible"
            }
        }
        if (-not $Silent) { Write-Log "Server ONLINE: $($status.name) ($($status.playersOnline)/$($status.playersMax))" }
    } else {
        $statusDot.Fill = $red
        if ($statusDotBig) { try { $statusDotBig.Fill = $red } catch {} }
        if ($dashStatusBrush) { $dashStatusBrush.Color = [System.Windows.Media.ColorConverter]::ConvertFromString("#E5484D") }
        if ($dashStatusGlow)  { $dashStatusGlow.Color  = [System.Windows.Media.ColorConverter]::ConvertFromString("#E5484D") }
        $txtStatus.Text = "OFFLINE"
        $txtStatus.Foreground = $red
        $server = Get-ActiveServer
        $txtServerName.Text = $server.name
        $txtServerMap.Text = "Offline"
        $txtServerPlayers.Text = "-"
        $txtPlayerList.Text = ""
        if ($lstPlayerChips) {
            $lstPlayerChips.ItemsSource = $null
            $lstPlayerChips.Visibility = "Collapsed"
            $txtPlayerList.Visibility = "Visible"
        }
    }
    # Ping update na dashboard
    if ($txtServerPing) {
        try {
            $sv = Get-ActiveServer
            $key = "$($sv.ip):$($sv.webPort)"
            $p = $null
            if ($script:ServerPings -and $script:ServerPings.ContainsKey($key)) { $p = $script:ServerPings[$key] }
            if ($p -ne $null -and $p -ge 0) {
                $txtServerPing.Text = "$p ms"
                $col = if ($p -lt 60) { "#30A46C" } elseif ($p -lt 150) { "#F5C518" } else { "#E5484D" }
                $txtServerPing.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($col)
            } else {
                $txtServerPing.Text = "-"
                $txtServerPing.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#666")
            }
        } catch {}
    }
}

# ============================================================
# MOD LIST & SYNC
# ============================================================
function Resolve-LocalModMeta {
    param(
        $LocalFile,
        [string]$FallbackVersion = '-'
    )
    $meta = [PSCustomObject]@{
        ModType       = 'Other'
        Version       = $FallbackVersion
        LocalZipPath  = ''
    }
    if (-not $LocalFile) { return $meta }
    try {
        $meta.LocalZipPath = $LocalFile.FullName
        $zipMeta = Get-ModMetaFromZip -ZipPath $meta.LocalZipPath
        if ($zipMeta.ModType) { $meta.ModType = $zipMeta.ModType }
        if ($zipMeta.Version -and $meta.Version -eq '-') { $meta.Version = $zipMeta.Version }
    } catch {}
    return $meta
}

function Refresh-ModList {
    param($PreloadedServerMods)
    $txtModStatus.Text = "Ucitavam..."
    # Ne mijesati Items i ItemsSource - iskljuci ItemsSource pa ce Apply-ModFilter postaviti opet
    if ($lstMods.ItemsSource) { $lstMods.ItemsSource = $null }
    $script:AllModItems = @()
    if (-not $PreloadedServerMods) { $script:ModListCached = $false }

    $modsPath = Get-EffectiveModsPath
    $localMods = @()
    if ($modsPath -and (Test-Path $modsPath)) {
        $localMods = @(Get-ChildItem $modsPath -Filter "*.zip" -ErrorAction SilentlyContinue)
    }
    $myCount = $localMods.Count
    $txtMyModCount.Text = "$myCount"

    $serverMods = if ($PreloadedServerMods) { $PreloadedServerMods } else {
        Write-Log "Dohvacam modove sa servera (mods.html)..."
        Get-ServerModList
    }
    if ($null -eq $serverMods) {
        $txtServerModCount.Text = "?"
        $txtMissingCount.Text = "?"
        $txtModStatus.Text = "Ne mogu dohvatiti listu sa servera"
        Write-Log "GRESKA: Ne mogu dohvatiti mods.html. Provjeri da je Public Mod Download aktiviran."
        foreach ($mod in $localMods) {
            $size = "{0:N1} MB" -f ($mod.Length / 1MB)
            $lm = Resolve-LocalModMeta -LocalFile $mod
            $script:AllModItems += (New-ModSyncItem -Status 'Lokalno' -DisplayName $mod.BaseName -ZipName $mod.Name `
                -Local 'Da' -Server '?' -Size $size -StatusDetail 'Server lista nedostupna' `
                -ModType $lm.ModType -LocalZipPath $lm.LocalZipPath -Version $lm.Version)
        }
        Apply-ModFilter (Get-CurrentFilter)
        return
    }

    if ($serverMods.Count -eq 0) {
        $txtServerModCount.Text = "0"
        $txtMissingCount.Text = "0"
        $txtModStatus.Text = "Nema modova na serveru ili Public Mod Download nije aktivan."
        Write-Log "Server nema aktivnih modova."
        return
    }

    $localModIndex = Build-LocalModIndex $localMods
    $useSizeCheck = $true
    try { if ($null -ne $script:Config.sizeCheck) { $useSizeCheck = [bool]$script:Config.sizeCheck } } catch {}
    $missing = 0
    $outdated = 0

    foreach ($sm in $serverMods) {
        $verLabel = '-'
        try {
            if ($sm.PSObject.Properties['version'] -and $sm.version) { $verLabel = [string]$sm.version }
            elseif ($sm.PSObject.Properties['Version'] -and $sm.Version) { $verLabel = [string]$sm.Version }
        } catch {}
        $zipName = if ($sm.Name -match '\.zip$') { $sm.Name } else { "$($sm.Name).zip" }
        $localMod = Find-LocalModEntry -LocalIndex $localModIndex -ServerName $sm.Name
        $isLocal = $null -ne $localMod
        $size = if ($localMod) { "{0:N1} MB" -f ($localMod.Length / 1MB) } else { "-" }
        $displayName = ($zipName -replace '\.zip$','')
        $localMeta = Resolve-LocalModMeta -LocalFile $localMod -FallbackVersion $verLabel
        if ($localMeta.Version -and $localMeta.Version -ne '-') { $verLabel = $localMeta.Version }
        if ($isLocal) {
            $isOutdated = $false
            $serverSizeText = ''
            $statusDetail = ''
            $localSha = ''
            $smSha = ''
            # Preferred path: SHA-256 compare (bot manifest provides hash).
            try { $smSha = if ($sm.Sha256) { ([string]$sm.Sha256).ToLower() } else { '' } } catch {}
            if ($smSha) {
                $localSha = Get-LocalModHash -File $localMod
                if (-not $localSha) {
                    $isOutdated = $true
                    $statusDetail = 'Lokalni ZIP postoji ali SHA nije moguce izracunati'
                    Write-Log "ZASTARIO (SHA nedostupan): $displayName ($($localMod.Name))"
                } elseif ($localSha -ne $smSha) {
                    $isOutdated = $true
                    $statusDetail = 'SHA-256 hash se ne podudara sa serverom'
                    if ($sm.Size -and $sm.Size -gt 0) { $serverSizeText = "{0:N1} MB" -f ($sm.Size / 1MB) }
                    Write-Log "ZASTARIO (SHA): $displayName lokal=$localSha server=$smSha"
                }
            } elseif ($useSizeCheck -and $sm.Url) {
                # Legacy fallback: HTTP HEAD Content-Length (samo kad nema SHA manifesta).
                $serverSize = 0
                try {
                    $head = Invoke-WebRequest -Uri $sm.Url -Method Head -UseBasicParsing -TimeoutSec 5
                    $cl = $head.Headers['Content-Length']
                    if ($cl) { $serverSize = [long]$cl }
                } catch {}
                if ($serverSize -gt 0 -and [Math]::Abs($localMod.Length - $serverSize) -gt 1024) {
                    $isOutdated = $true
                    $statusDetail = 'Velicina datoteke ne odgovara serveru'
                    $serverSizeText = "{0:N1} MB" -f ($serverSize / 1MB)
                    Write-Log "ZASTARIO (velicina): $displayName lokal=$($localMod.Length) server=$serverSize"
                }
            }
            if ($isOutdated) {
                $outdated++
                $missing++
                $serverLabel = if ($serverSizeText) { "Da ($serverSizeText)" } else { "Da (azurirano)" }
                $script:AllModItems += (New-ModSyncItem -Status 'ZASTARIO' -DisplayName $displayName -ZipName $zipName `
                    -Local 'Da' -Server $serverLabel -Size $size -StatusDetail $statusDetail `
                    -LocalSha $localSha -ServerSha $smSha -Version $verLabel `
                    -ModType $localMeta.ModType -LocalZipPath $localMeta.LocalZipPath)
            } else {
                $script:AllModItems += (New-ModSyncItem -Status 'OK' -DisplayName $displayName -ZipName $zipName `
                    -Local 'Da' -Server 'Da' -Size $size -StatusDetail 'Sinkronizirano (SHA/velicina OK)' -Version $verLabel `
                    -ModType $localMeta.ModType -LocalZipPath $localMeta.LocalZipPath)
            }
        } else {
            $missing++
            $script:AllModItems += (New-ModSyncItem -Status 'FALI' -DisplayName $displayName -ZipName $zipName `
                -Local 'Ne' -Server 'Da' -Size '-' -StatusDetail 'Lokalni ZIP nedostaje u mods folderu' -Version $verLabel `
                -ModType 'Other')
        }
    }

    $serverModKeys = $serverMods | ForEach-Object { Get-NormalizedModZipName $_.Name }
    $serverCanonKeys = $serverMods | ForEach-Object { Get-CanonicalModKey $_.Name }
    foreach ($lm in $localMods) {
        $lmKey = Get-NormalizedModZipName $lm.Name
        $lmCanon = Get-CanonicalModKey $lm.Name
        if (($serverModKeys -notcontains $lmKey) -and ($lmCanon -and $serverCanonKeys -notcontains $lmCanon)) {
            $size = "{0:N1} MB" -f ($lm.Length / 1MB)
            $extraMeta = Resolve-LocalModMeta -LocalFile $lm
            $script:AllModItems += (New-ModSyncItem -Status 'Extra' -DisplayName $lm.BaseName -ZipName $lm.Name `
                -Local 'Da' -Server 'Ne' -Size $size -StatusDetail 'Nije na server listi' `
                -ModType $extraMeta.ModType -LocalZipPath $extraMeta.LocalZipPath -Version $extraMeta.Version)
        }
    }

    $txtServerModCount.Text = "$($serverMods.Count)"
    $txtMissingCount.Text = "$missing"
    if ($txtModsLocal)   { $txtModsLocal.Text   = "$myCount" }
    if ($txtModsServer)  { $txtModsServer.Text  = "$($serverMods.Count)" }
    if ($txtModsMissing) { $txtModsMissing.Text = "$missing" }
    # Total velicina lokalnih modova
    if ($txtModSizeTotal) {
        try {
            $totalBytes = ($localMods | Measure-Object -Property Length -Sum).Sum
            if ($totalBytes -ge 1GB) { $txtModSizeTotal.Text = "{0:N1} GB" -f ($totalBytes / 1GB) }
            else { $txtModSizeTotal.Text = "{0:N0} MB" -f ($totalBytes / 1MB) }
        } catch { $txtModSizeTotal.Text = "-" }
    }
    $script:Config.lastSync = Get-Date -Format "dd.MM.yyyy HH:mm"
    $txtLastSync.Text = "Zadnji sync: $($script:Config.lastSync)"
    Save-Config
    $srcLabel = if ($script:ModListSource -eq 'bot-sha256') { 'SHA-256 manifest' } else { 'mods.html' }
    $txtModStatus.Text = "Lokalno: $myCount | Server: $($serverMods.Count) | Fali/Zastarjelo: $missing | Izvor: $srcLabel"
    if ($txtModSubtitle) {
        $txtModSubtitle.Text = if ($script:ModListSource -eq 'bot-sha256') {
            'Server-authoritative lista + SHA-256 usporedba (bot API)'
        } else {
            'Legacy mods.html - bez hash provjere (aktiviraj bot manifest)'
        }
    }
    Write-Log "Pregled zavrsen. Lokalno=$myCount  Server=$($serverMods.Count)  Fali=$missing  (od toga zastarjelih: $outdated)  Izvor=$srcLabel"
    # Dashboard preview "Fali modovi"
    if ($lstMissingPreview) {
        try {
            $miss = $script:AllModItems | Where-Object { $_.Status -eq 'FALI' -or $_.Status -eq 'ZASTARIO' } | Select-Object -First 6
            $lstMissingPreview.ItemsSource = $null
            $lstMissingPreview.ItemsSource = @($miss)
            if ($txtMissingHint) {
                if ($missing -gt 6) { $txtMissingHint.Text = "+$($missing - 6) jos" }
                elseif ($missing -eq 0) { $txtMissingHint.Text = "Sve OK" }
                else { $txtMissingHint.Text = "" }
            }
        } catch {}
    }
    $script:ModListCached = $true
    Update-ModShowCombo
    Apply-ModFilter (Get-CurrentFilter)
}

function Download-MissingMods {
    $modsPath = Get-EffectiveModsPath
    if (-not $modsPath) {
        Write-Log "GRESKA: Putanja modova nije postavljena."
        return
    }
    if (-not (Test-Path $modsPath)) {
        New-Item -ItemType Directory -Path $modsPath -Force | Out-Null
    }

    $missingItems = @(Get-MissingSyncModItems)
    if ($missingItems.Count -eq 0) {
        Refresh-ModList
        $missingItems = @(Get-MissingSyncModItems)
    }
    if ($missingItems.Count -eq 0) {
        Write-Log "Sve modove vec imas!"
        Show-SRDialog "Sve modove vec imas!" "SR Launcher" "Success"
        return
    }

    $serverMods = Get-ServerModList
    if (-not $serverMods) {
        Write-Log "GRESKA: Ne mogu dohvatiti download linkove."
        return
    }

    Write-Log "Skidam $($missingItems.Count) modova..."
    $txtProgress.Text = "Skidam modove..."
    $downloaded = 0

    foreach ($item in $missingItems) {
        $lookup = if ($item.ZipName) { $item.ZipName } else { $item.Name }
        $modEntry = Resolve-ServerModEntry -ServerMods $serverMods -DisplayOrZipName $lookup

        if (-not $modEntry) {
            Write-Log "  Preskacam: $($item.Name) (nema URL / nije na server listi)"
            continue
        }

        $dest = Join-Path $modsPath $modEntry.Name
        try {
            Write-Log "  Skidam: $($modEntry.Name)..."
            $txtProgress.Text = "$($modEntry.Name) ($($downloaded+1)/$($missingItems.Count))"
            $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)

            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile($modEntry.Url, $dest)
            $wc.Dispose()

            if (Test-Path $dest) {
                $size = "{0:N1} MB" -f ((Get-Item $dest).Length / 1MB)
                Write-Log "  Skinuto: $($modEntry.Name) ($size)"
                $downloaded++
            }
        } catch {
            Write-Log "  GRESKA: $($modEntry.Name) - $($_.Exception.Message)"
        }
    }

    $txtProgress.Text = ""
    Write-Log "Zavrseno! $downloaded/$($missingItems.Count) skinuto."
    Show-SRDialog "Skinuto $downloaded od $($missingItems.Count) modova!" "SR Launcher" "Success"
    Refresh-ModList
}

# ============================================================
# ADMIN MODE
# ============================================================
function Load-ServerToForm {
    $server = Get-ActiveServer
    $txtSrvName.Text = $server.name
    $txtSrvIp.Text = $server.ip
    $txtSrvWebPort.Text = [string]$server.webPort
    $txtSrvGamePort.Text = [string]$server.gamePort
    $txtSrvStatsCode.Text = if ($server.statsCode) { $server.statsCode } else { "" }
    $txtSrvPassword.Text = if ($server.password) { $server.password } else { "" }
    $txtGitHubRepo.Text = if ($script:Config.githubRepo) { $script:Config.githubRepo } else { "" }
}

function Enable-AdminMode {
    $script:IsAdmin = $true
    $btnAdminToggle.Content = "Admin"
    $btnAdminToggle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F5C518")
    $adminPanel.Visibility = "Visible"
    if ($navLog) { $navLog.Visibility = "Visible" }
    Load-ServerToForm
    Write-Log "Admin mod aktiviran."
}

function Disable-AdminMode {
    $script:IsAdmin = $false
    $btnAdminToggle.Content = "Igrac"
    $btnAdminToggle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#555")
    $adminPanel.Visibility = "Collapsed"
    if ($navLog) {
        $navLog.Visibility = "Collapsed"
        # Ako je log trenutno aktivan, prebaci na dashboard
        if ($navLog.IsChecked -eq $true) { $navDash.IsChecked = $true }
    }
    Write-Log "Admin mod deaktiviran."
}

# ============================================================
# GAME LAUNCH
# ============================================================
function Join-Server {
    $btnJoinServer.IsEnabled = $false
    $txtJoinStatus.Text = "Pripremam..."
    $txtJoinStatus.Visibility = 'Visible'

    $exePath = $script:Config.gamePath
    if (-not $exePath -or -not (Test-Path $exePath)) {
        Write-Log "GRESKA: FS25 exe nije pronadjen!"
        Show-SRDialog "FS25 exe nije pronadjen.`nIdi u Postavke i postavi putanju." "SR Launcher" "Warning"
        $navSettings.IsChecked = $true
        $txtJoinStatus.Visibility = 'Collapsed'
        $btnJoinServer.IsEnabled = $true
        return
    }

    $server = Get-ActiveServer
    $gsPath = Get-GameSettingsPath
    if ($server.password -and (Test-Path $gsPath)) {
        try {
            $content = Get-Content $gsPath -Raw -Encoding UTF8
            if ($content -match 'serverPassword="[^"]*"') {
                $content = $content -replace 'serverPassword="[^"]*"', "serverPassword=`"$($server.password)`""
                Set-Content $gsPath $content -Encoding UTF8
                Write-Log "Server password upisan u gameSettings.xml"
            }
        } catch { Write-Log "GRESKA password: $($_.Exception.Message)" }
    }

    # Automatski sync mods folder u gameSettings.xml (multiplayer folder ako je odabran)
    $modsPath = Get-EffectiveModsPath
    if ($modsPath) {
        if (-not (Test-Path $modsPath)) {
            New-Item -ItemType Directory -Path $modsPath -Force | Out-Null
            Write-Log "Kreiran multiplayer mod folder: $modsPath"
        }
        Update-ModsDirectoryOverride $modsPath | Out-Null
        $af = Get-ActiveMultiplayerFolder
        $afLbl = if ($af -and $af.Label) { $af.Label } else { 'glavna biblioteka' }
        Write-Log "modsDirectoryOverride: $modsPath ($afLbl)"
    }

    # Provjera verzije igre vs. server
    $txtJoinStatus.Text = "Provjeravam verziju igre..."
    try {
        $serverStatus = Get-ServerStatus
        if ($serverStatus.online -and $serverStatus.gameVersion) {
            $localVer = Get-FS25GameVersion -ExePath $exePath
            if ($localVer -and $serverStatus.gameVersion -and $localVer -ne $serverStatus.gameVersion) {
                $r = Show-SRConfirm "Verzija igre se ne podudara!`n`nServer: $($serverStatus.gameVersion)`nTvoja:  $localVer`n`nServer ce te najvjerojatnije kickati.`nPokrenuti svejedno?" "SR Launcher" "Pokreni" "Odustani"
                if ($r -ne 'Yes') {
                    $txtJoinStatus.Visibility = 'Collapsed'
                    $btnJoinServer.IsEnabled = $true
                    return
                }
            }
        }
    } catch { Write-Log "WARN version check: $($_.Exception.Message)" }

    Write-Log "Provjeravam modove..."
    $txtJoinStatus.Text = "Provjeravam modove..."
    Refresh-ModList
    $missingItems = @(Get-MissingSyncModItems)
    $missingCount = $missingItems.Count

    if ($missingCount -gt 0) {
        $preview = ($missingItems | Select-Object -First 8 | ForEach-Object {
            $d = if ($_.StatusDetail) { " - $($_.StatusDetail)" } else { '' }
            "  [$($_.Status)] $($_.Name)$d"
        }) -join "`n"
        if ($missingCount -gt 8) { $preview += "`n  ... i jos $($missingCount - 8)" }
        $r = Show-SRConfirm "Fali ti / zastarjelo $missingCount modova:`n`n$preview`n`nDa  = skini sve i pokreni igru`nNe  = ne pokrecem igru" "SR Launcher" "Da, skini i pokreni" "Ne pokreci"
        if ($r -ne 'Yes') {
            Write-Log "Igrac odustao - igra se ne pokrece (fali $missingCount modova)."
            $txtJoinStatus.Text = "Igra nije pokrenuta - fali modova."
            try { Show-Toast "Pokretanje otkazano - fali $missingCount modova" "warn" } catch {}
            $btnJoinServer.IsEnabled = $true
            return
        }
        $txtJoinStatus.Text = "Skidam modove..."
        Download-MissingMods
        # Re-check nakon downloada
        Refresh-ModList
        $stillMissing = (Get-MissingSyncModItems).Count
        if ($stillMissing -gt 0) {
            $r2 = Show-SRConfirm "Nakon downloada jos uvijek fali $stillMissing modova.`nServer ce te najvjerojatnije kickati.`n`nPokrenuti svejedno?" "SR Launcher" "Pokreni" "Odustani"
            if ($r2 -ne 'Yes') {
                $txtJoinStatus.Visibility = 'Collapsed'
                $btnJoinServer.IsEnabled = $true
                return
            }
        }
    }

    Write-Log "Pokrecem FS25 za server: $($server.name)..."
    $txtJoinStatus.Text = "Pokrecem igru..."
    try {
        Start-FS25Game -ExePath $exePath
    } catch {
        Write-Log "GRESKA pokretanje igre: $($_.Exception.Message)"
        Show-SRDialog "Ne mogu pokrenuti igru:`n$($_.Exception.Message)" "SR Launcher" "Error"
        $txtJoinStatus.Visibility = 'Collapsed'
        $btnJoinServer.IsEnabled = $true
        return
    }
    # License: heartbeat + spawn detached session-end watcher
    try {
        $licKey = $script:CurrentLicenseKey
        if (-not $licKey) {
            $cache = Get-LicenseCache
            if ($cache) { $licKey = $cache.key }
        }
        if ($licKey) {
            Send-LicenseHeartbeat -Key $licKey
            Start-LicenseSessionWatcher -Key $licKey
        }
    } catch { Write-Log "License heartbeat error: $($_.Exception.Message)" }
    $txtJoinStatus.Text = "Igra pokrenuta! Zatvaranje launchera..."
    Write-Log "Igra pokrenuta. Launcher se zatvara za 5 sekundi..."

    # Zatvori launcher 5 sekundi nakon pokretanja igre
    $script:closeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:closeTimer.Interval = [TimeSpan]::FromSeconds(5)
    $script:closeTimer.Add_Tick({
        $script:closeTimer.Stop()
        # Provjeri jestli se FS25 proces stvarno pokrenuo
        $fs = Get-Process -Name "FarmingSimulator2025*" -ErrorAction SilentlyContinue
        if ($fs) {
            Write-Log "FS25 detektiran, zatvaranje launchera."
            $window.Close()
        } else {
            # Igra se mozda jos ucitava, cekaj jos 10 sec
            Write-Log "FS25 se jos ucitava, cekam..."
            $script:closeTimer2 = New-Object System.Windows.Threading.DispatcherTimer
            $script:closeTimer2.Interval = [TimeSpan]::FromSeconds(10)
            $script:closeTimer2.Add_Tick({
                $script:closeTimer2.Stop()
                $window.Close()
            })
            $script:closeTimer2.Start()
        }
    })
    $script:closeTimer.Start()
}

# ============================================================
# EVENT HANDLERS
# ============================================================
$btnJoinServer.Add_Click({ Join-Server })
$btnSyncMods.Add_Click({ Refresh-ModList })
if ($btnGoToMods) { $btnGoToMods.Add_Click({ $navMods.IsChecked = $true }) }
$btnRefreshMods.Add_Click({ Refresh-ModList })
if ($btnRescanMods) {
    $btnRescanMods.Add_Click({
        $script:ModListCached = $false
        Refresh-ModList
        try { Show-Toast "Modovi ponovno skenirani" "info" } catch {}
    })
}
$btnDownloadMissing.Add_Click({ Download-MissingMods })
$btnRefreshStatus.Add_Click({ Refresh-ServerStatus })

$btnLinkWeb.Add_Click({
    $url = if ($script:SharedWebUrl) { $script:SharedWebUrl } else { "https://slavonska-ravnica.com" }
    Start-Process $url
})
$btnLinkDiscord.Add_Click({
    $url = if ($script:SharedDiscordUrl) { $script:SharedDiscordUrl } else { "https://discord.gg/slavonskaravnica" }
    Start-Process $url
})

$btnBrowseExe.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = "FS25 Executable|FarmingSimulator2025.exe|All|*.*"
    $d.Title = "Odaberi FarmingSimulator2025.exe"
    if ($d.ShowDialog() -eq 'OK') { $txtGameExe.Text = $d.FileName }
})

$btnBrowseMods.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = "Odaberi FS25 mods folder"
    if ($txtModsPath.Text) { $d.SelectedPath = $txtModsPath.Text }
    if ($d.ShowDialog() -eq 'OK') { $txtModsPath.Text = $d.SelectedPath }
})

$btnSavePlayerSettings.Add_Click({
    $script:Config.gamePath = $txtGameExe.Text
    $newModsPath = $txtModsPath.Text
    $script:Config.modsPath = $newModsPath
    Save-Config

    # Automatski azuriraj modsDirectoryOverride u gameSettings.xml
    if ($newModsPath) {
        if (-not (Test-Path $newModsPath)) {
            New-Item -ItemType Directory -Path $newModsPath -Force | Out-Null
            Write-Log "Kreiran mods folder: $newModsPath"
        }
        $modsOk = Update-ModsDirectoryOverride $newModsPath
        if ($modsOk) {
            Write-Log "Postavke spremljene! Mods folder azuriran u gameSettings.xml"
            Show-SRDialog "Postavke spremljene!`nMods folder azuriran u igri." "SR Launcher" "Success"
        } else {
            Write-Log "Postavke spremljene, ali gameSettings.xml nije azuriran."
            Show-SRDialog "Postavke spremljene!`nAli gameSettings.xml nije azuriran - provjeri putanju rucno." "SR Launcher" "Warning"
        }
    } else {
        Write-Log "Postavke spremljene!"
        Show-SRDialog "Postavke spremljene!" "SR Launcher" "Success"
    }
})

# Admin toggle
$btnAdminToggle.Add_Click({
    if ($script:IsAdmin) {
        Disable-AdminMode
    } else {
        if (-not $script:Config.adminHash) {
            $pass = Show-PasswordDialog "Postavi Admin Lozinku" "Unesi novu admin lozinku (min. 4 znaka):"
            if ($pass -and $pass.Length -ge 4) {
                $script:Config.adminHash = Get-SHA256 $pass
                Save-Config
                Enable-AdminMode
                Write-Log "Admin lozinka postavljena!"
            } elseif ($pass) {
                Show-SRDialog "Lozinka mora imati barem 4 znaka!" "Greska" "Error"
            }
        } else {
            $pass = Show-PasswordDialog "Admin Prijava" "Unesi admin lozinku:"
            if ($pass) {
                if ((Get-SHA256 $pass) -eq $script:Config.adminHash) {
                    Enable-AdminMode
                } else {
                    Show-SRDialog "Pogresna lozinka!" "Greska" "Error"
                }
            }
        }
    }
})

# Admin server management
$btnSaveServer.Add_Click({
    $idx = [int]$script:Config.activeServer
    $script:Config.servers[$idx].name = $txtSrvName.Text
    $script:Config.servers[$idx].ip = $txtSrvIp.Text
    try { $script:Config.servers[$idx].webPort = [int]$txtSrvWebPort.Text } catch {}
    try { $script:Config.servers[$idx].gamePort = [int]$txtSrvGamePort.Text } catch {}
    $script:Config.servers[$idx].statsCode = $txtSrvStatsCode.Text
    $script:Config.servers[$idx].password = $txtSrvPassword.Text
    Save-Config
    Update-ServerButtons
    Refresh-ServerStatus
    Write-Log "Server '$($txtSrvName.Text)' spremljen."
    Show-SRDialog "Server postavke spremljene!" "SR Launcher" "Success"
})

$btnAddServer.Add_Click({
    $newServer = [PSCustomObject]@{
        name = "Novi Server"; ip = ""; webPort = 8620
        gamePort = 8600; statsCode = ""; password = ""
    }
    $list = [System.Collections.ArrayList]@($script:Config.servers)
    $list.Add($newServer) | Out-Null
    $script:Config.servers = @($list)
    $script:Config.activeServer = $script:Config.servers.Count - 1
    Save-Config
    Update-ServerButtons
    Load-ServerToForm
    Write-Log "Novi server dodan. Uredi postavke i spremi."
})

$btnDeleteServer.Add_Click({
    if ($script:Config.servers.Count -le 1) {
        Show-SRDialog "Ne mozes obrisati zadnji server!" "Greska" "Error"
        return
    }
    $idx = [int]$script:Config.activeServer
    $name = $script:Config.servers[$idx].name
    $result = Show-SRConfirm "Obrisati server '$name'?" "Potvrda"
    if ($result -eq "Yes") {
        $list = [System.Collections.ArrayList]@($script:Config.servers)
        $list.RemoveAt($idx)
        $script:Config.servers = @($list)
        $script:Config.activeServer = 0
        Save-Config
        Update-ServerButtons
        Load-ServerToForm
        Refresh-ServerStatus
        Write-Log "Server '$name' obrisan."
    }
})

$btnSaveGitHub.Add_Click({
    $script:Config.githubRepo = $txtGitHubRepo.Text
    $script:GitHubRepo = $txtGitHubRepo.Text
    Save-Config
    Write-Log "GitHub repo spremljen: $($txtGitHubRepo.Text)"
    Show-SRDialog "GitHub repo spremljen!" "SR Launcher" "Success"
})

$btnChangeAdminPass.Add_Click({
    $newPass = $txtNewAdminPass.Password
    if ($newPass.Length -lt 4) {
        Show-SRDialog "Lozinka mora imati barem 4 znaka!" "Greska" "Error"
        return
    }
    $script:Config.adminHash = Get-SHA256 $newPass
    Save-Config
    $txtNewAdminPass.Clear()
    Write-Log "Admin lozinka promijenjena."
    Show-SRDialog "Admin lozinka promijenjena!" "SR Launcher" "Success"
})

$btnUpdateNotify.Add_Click({
    if ($script:LatestVersion) {
        $r = Show-SRConfirm "Nova verzija: v$($script:LatestVersion.version)`n`nSkinuti i instalirati?" "Update"
        if ($r -eq 'Yes') { Download-Update }
    }
})

$btnUpdateNow.Add_Click({
    if ($script:LatestVersion) {
        $r = Show-SRConfirm "Nova verzija: v$($script:LatestVersion.version)`n`nSkinuti i instalirati?" "Update"
        if ($r -eq 'Yes') { Download-Update }
    }
})

$btnClearLog.Add_Click({
    if ($script:LogBuffer) { $script:LogBuffer.Clear() }
    $txtLog.Clear()
    if ($txtLogCount) { $txtLogCount.Text = "0 redova" }
})
if ($btnLogCopy) {
    $btnLogCopy.Add_Click({
        try {
            [System.Windows.Clipboard]::SetText($txtLog.Text)
            Show-Toast "Log kopiran u clipboard" success
        } catch { Show-Toast "Greska: $_" error }
    })
}
if ($txtLogSearch) {
    $txtLogSearch.Add_TextChanged({
        # Re-render iz buffera s filtrom
        $filter = $txtLogSearch.Text
        if (-not $script:LogBuffer) { return }
        if ($filter -and $filter -notmatch '^Pretrazi') {
            $lines = @($script:LogBuffer | Where-Object { $_ -match [regex]::Escape($filter) })
        } else {
            $lines = @($script:LogBuffer)
        }
        $txtLog.Text = ($lines -join "`r`n")
        if ($chkLogAutoScroll.IsChecked) { $txtLog.ScrollToEnd() }
    })
}

# Filter event handlers
$filterAll.Add_Checked({ Apply-ModFilter "All" })
$filterServer.Add_Checked({ Apply-ModFilter "Server" })
$filterMissing.Add_Checked({ Apply-ModFilter "Missing" })
$filterExtra.Add_Checked({ Apply-ModFilter "Extra" })
$filterLocal.Add_Checked({ Apply-ModFilter "Local" })
if ($cmbModShow) {
    $cmbModShow.Add_SelectionChanged({
        if ($script:ModShowComboUpdating) { return }
        Apply-ModFilter
    })
}

if ($lstMods) {
    $lstMods.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        $btn = $e.OriginalSource
        if (-not $btn -or $btn.Name -ne 'btnModFavorite') { return }
        $item = $null
        try {
            $el = $btn
            while ($null -ne $el) {
                if ($el -is [System.Windows.Controls.ListBoxItem]) {
                    $item = $el.DataContext
                    break
                }
                $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el)
            }
        } catch {}
        if (-not $item) { $item = $lstMods.SelectedItem }
        if (-not $item) { return }
        $newFav = -not [bool]$item.IsFavorite
        Set-ModFavorite -Item $item -Favorite $newFav
        Update-ModShowCombo
        Apply-ModFilter
        try {
            $msg = if ($newFav) { 'Dodano u favorite' } else { 'Uklonjeno iz favorita' }
            Show-Toast "$msg : $($item.Name)" 'info' 2000
        } catch {}
        $e.Handled = $true
    }, $true)
}

# Game Options event handlers - auto-save on toggle click
$chkIntroScene.Add_Checked({
    $ok = Write-GameSetting "isIntroActive" "true"
    if ($ok) { Write-Log "Intro scena: UKLJUCENA" }
})
$chkIntroScene.Add_Unchecked({
    $ok = Write-GameSetting "isIntroActive" "false"
    if ($ok) { Write-Log "Intro scena: ISKLJUCENA" }
})
$chkDevConsole.Add_Checked({
    $ok = Write-GameSetting "developmentControls" "true"
    if ($ok) { Write-Log "Developer Console: UKLJUCEN" }
})
$chkDevConsole.Add_Unchecked({
    $ok = Write-GameSetting "developmentControls" "false"
    if ($ok) { Write-Log "Developer Console: ISKLJUCEN" }
})
$btnSaveGameOptions.Add_Click({
    $introVal = if ($chkIntroScene.IsChecked) { "true" } else { "false" }
    $devVal   = if ($chkDevConsole.IsChecked) { "true" } else { "false" }
    $ok1 = Write-GameSetting "isIntroActive" $introVal
    $ok2 = Write-GameSetting "developmentControls" $devVal
    if ($ok1 -or $ok2) {
        Write-Log "Opcije igre spremljene! Intro=$introVal DevConsole=$devVal"
        Show-SRDialog "Opcije igre spremljene!" "SR Launcher" "Success"
    } else {
        Show-SRDialog "Nije moguce spremiti opcije.`nProvjeri da gameSettings.xml postoji." "SR Launcher" "Warning"
    }
})

# ============================================================
# GAME PATH POPUP (if not found)
# ============================================================
$window.Add_ContentRendered({
    if (-not $script:Config.gamePath -or -not (Test-Path $script:Config.gamePath)) {
        $result = Show-SRConfirm "Farming Simulator 2025 nije automatski pronadjen.`nZelis li rucno odabrati putanju do igre?" "Putanja do igre"
        if ($result -eq 'Yes') {
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = "Pronadi FarmingSimulator2025.exe"
            $dlg.Filter = "FS25|FarmingSimulator2025.exe|Svi exe|*.exe"
            if ($dlg.ShowDialog($window)) {
                $script:Config.gamePath = $dlg.FileName
                Save-Config
                $txtGameExe.Text = $dlg.FileName
                Write-Log "Igra postavljena: $($dlg.FileName)"
            }
        }
    }
})

# ============================================================
# STARTUP (use preloaded data from splash screen)
# ============================================================
Sync-AppVersionFromScript | Out-Null
$txtVersion.Text = "v$($script:AppVersion)"
$txtGameExe.Text = $script:Config.gamePath
$txtModsPath.Text = $script:Config.modsPath
if ($script:Config.lastSync) { $txtLastSync.Text = "Zadnji sync: $($script:Config.lastSync)" }

# Load game settings toggles (use preloaded if available)
$gs = if ($script:PreloadedGameSettings) { $script:PreloadedGameSettings } else { Read-GameSettings }
$chkIntroScene.IsChecked = $gs.introScene
$chkDevConsole.IsChecked = $gs.devConsole

$localModCount = if ($null -ne $script:PreloadedLocalModCount) {
    $script:PreloadedLocalModCount
} elseif ($script:Config.modsPath -and (Test-Path $script:Config.modsPath)) {
    @(Get-ChildItem $script:Config.modsPath -Filter "*.zip" -ErrorAction SilentlyContinue).Count
} else { 0 }
$txtMyModCount.Text = "$localModCount"

Update-ServerButtons
Write-Log "Slavonska Ravnica Launcher v$($script:AppVersion)"
Write-Log "Game: $($script:Config.gamePath)"
Write-Log "Mods: $($script:Config.modsPath)"
try {
    $eff = Get-EffectiveModsPath
    if ($eff -and $eff -ne $script:Config.modsPath) { Write-Log "Multiplayer mod folder: $eff" }
    Ensure-ServerMpFolder | Out-Null
    Update-SidebarLibraryCounts
    Sync-MpFolderQuickPick
} catch {}
Write-Log "Serveri: $($script:Config.servers.Count)"
Write-Log "GitHub: $($script:GitHubRepo)"
Write-Log "gameSettings.xml: $(Get-GameSettingsPath)"
Write-Log "Config: $($script:ConfigPath)"
Update-LicenseUi

if ($btnCopyHwid) {
    $btnCopyHwid.Add_Click({
        try {
            [System.Windows.Clipboard]::SetText((Get-Hwid))
            Show-Toast -Message 'HWID kopiran u clipboard.' -Kind 'success'
        } catch {
            Show-SRDialog "Ne mogu kopirati HWID: $($_.Exception.Message)" "HWID" "Error"
        }
    })
}
if ($btnChangeLicense) {
    $btnChangeLicense.Add_Click({
        $res = Show-LicenseWindow
        if ($res -eq 'ok') {
            Update-LicenseUi
            Show-Toast -Message 'Licenca azurirana.' -Kind 'success'
        }
    })
}

# ============================================================
# v1.2 - TOAST NOTIFIKACIJE
# ============================================================
function Show-Toast {
    param(
        [string]$Message,
        [ValidateSet('info','success','warn','error')][string]$Kind = 'info',
        [int]$DurationMs = 3500
    )
    if (-not $toastHost) { return }
    if ($script:Config.toastsEnabled -eq $false) { return }
    $colors = @{
        info    = @{ bg='#161616'; fg='#eee';     accent='#F5C518' }
        success = @{ bg='#13301f'; fg='#aaf0c8';  accent='#30A46C' }
        warn    = @{ bg='#3a2a08'; fg='#ffd97a';  accent='#F5C518' }
        error   = @{ bg='#3a1414'; fg='#ffb8b8';  accent='#E5484D' }
    }
    $c = $colors[$Kind]
    $bd = New-Object System.Windows.Controls.Border
    $bd.CornerRadius = "8"
    $bd.Padding = "14,10"
    $bd.Margin = "0,0,0,8"
    $bd.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($c.bg)
    $bd.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($c.accent)
    $bd.BorderThickness = "1"
    $bd.MinWidth = 220
    $bd.MaxWidth = 360
    $bd.Opacity = 0
    $bd.IsHitTestVisible = $true
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Message
    $tb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($c.fg)
    $tb.FontSize = 12
    $tb.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI")
    $tb.TextWrapping = "Wrap"
    $bd.Child = $tb
    $toastHost.Children.Add($bd) | Out-Null

    # Fade in
    $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fadeIn.From = 0; $fadeIn.To = 1
    $fadeIn.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(180))
    $bd.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $fadeIn)

    # Auto-dismiss
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds($DurationMs)
    $t.Tag = $bd
    $t.Add_Tick({
        $t.Stop()
        $b = $t.Tag
        $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation
        $fadeOut.From = 1; $fadeOut.To = 0
        $fadeOut.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(220))
        $fadeOut.Add_Completed({ try { $toastHost.Children.Remove($b) | Out-Null } catch {} }.GetNewClosure())
        $b.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $fadeOut)
    }.GetNewClosure())
    $t.Start()
    # Klik = dismiss
    $bd.Add_MouseLeftButtonDown({
        param($s, $e)
        try { $toastHost.Children.Remove($s) | Out-Null } catch {}
    })
}

# ============================================================
# v1.2 - MOD SEARCH BOX
# ============================================================
$txtModSearch.Add_TextChanged({
    if ($txtModSearch.Text) { $txtModSearchPlaceholder.Visibility = "Collapsed" }
    else                    { $txtModSearchPlaceholder.Visibility = "Visible" }
    Apply-ModFilter (Get-CurrentFilter)
})

# ============================================================
# v1.2 - MOD DELETE / OPEN FOLDER / CONTEXT MENU
# ============================================================
function Get-SelectedModFile {
    $sel = $lstMods.SelectedItem
    if (-not $sel) { return $null }
    $modsPath = $script:Config.modsPath
    if (-not $modsPath -or -not (Test-Path $modsPath)) { return $null }
    # Name moze biti bez .zip ili sa .zip
    $fname = $sel.Name
    if ($fname -notlike "*.zip") { $fname = "$fname.zip" }
    $full = Join-Path $modsPath $fname
    if (Test-Path $full) { return $full }
    return $null
}

function Delete-SelectedMod {
    $sel = $lstMods.SelectedItem
    if (-not $sel) { Show-Toast "Odaberi mod u gridu za brisanje" "warn"; return }
    $f = Get-SelectedModFile
    if (-not $f) { Show-Toast "Mod nije pronaden lokalno (vec obrisan?)" "warn"; return }
    $r = Show-SRConfirm "Obrisati '$($sel.Name)'?`n`nFajl ide u Recycle Bin." "SR Launcher" "Obrisi" "Odustani"
    if ($r -eq 'Yes') {
        try {
            # Recycle bin (sigurnije od Remove-Item)
            Add-Type -AssemblyName Microsoft.VisualBasic
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f, 'OnlyErrorDialogs', 'SendToRecycleBin')
            Write-Log "Obrisan: $f"
            Show-Toast "Mod obrisan: $($sel.Name)" "success"
            Refresh-ModList
        } catch {
            Write-Log "GRESKA brisanja: $($_.Exception.Message)"
            Show-Toast "Greska brisanja: $($_.Exception.Message)" "error" 5000
        }
    }
}

$btnDeleteMod.Add_Click({ Delete-SelectedMod })
$ctxDeleteMod.Add_Click({ Delete-SelectedMod })
$btnOpenModsFolder.Add_Click({
    $modsPath = $script:Config.modsPath
    if ($modsPath -and (Test-Path $modsPath)) {
        Start-Process explorer.exe $modsPath
    } else {
        Show-Toast "Mods folder nije postavljen (Postavke)" "warn"
    }
})
$ctxOpenInExplorer.Add_Click({
    $f = Get-SelectedModFile
    if ($f) { Start-Process explorer.exe "/select,`"$f`"" }
    else    { Show-Toast "Mod nije pronaden lokalno" "warn" }
})
$ctxCopyName.Add_Click({
    $sel = $lstMods.SelectedItem
    if ($sel) {
        [System.Windows.Clipboard]::SetText($sel.Name)
        Show-Toast "Ime kopirano: $($sel.Name)" "info" 2000
    }
})

# ============================================================
# v1.2 - CUSTOM SERVER DIALOG
# ============================================================
function Show-AddServerDialog {
    [xml]$dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Dodaj custom server" Width="460" Height="540"
        WindowStartupLocation="CenterOwner" Background="#0d0d0d"
        WindowStyle="None" AllowsTransparency="True" ResizeMode="NoResize">
    <Border CornerRadius="10" Background="#0d0d0d" BorderBrush="#F5C518" BorderThickness="1">
        <Grid Margin="24">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="+ Dodaj svoj server" FontSize="18" FontWeight="Bold"
                       Foreground="#F5C518" FontFamily="Segoe UI" Margin="0,0,0,4"/>
            <TextBlock Grid.Row="0" Text="Sluzi za testiranje. Spremise se samo lokalno." FontSize="11"
                       Foreground="#888" FontFamily="Segoe UI" Margin="0,28,0,16"/>
            <StackPanel Grid.Row="1">
                <TextBlock Text="Ime servera" FontSize="11" Foreground="#888" Margin="0,8,0,4" FontFamily="Segoe UI"/>
                <TextBox x:Name="dlgName" Background="#1a1a1a" Foreground="#eee" BorderBrush="#333"
                         BorderThickness="1" Padding="10,8" FontSize="13" FontFamily="Segoe UI"/>
                <TextBlock Text="IP / hostname" FontSize="11" Foreground="#888" Margin="0,12,0,4" FontFamily="Segoe UI"/>
                <TextBox x:Name="dlgIp" Background="#1a1a1a" Foreground="#eee" BorderBrush="#333"
                         BorderThickness="1" Padding="10,8" FontSize="13" FontFamily="Segoe UI"/>
                <Grid Margin="0,12,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="10"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0">
                        <TextBlock Text="Web port" FontSize="11" Foreground="#888" Margin="0,0,0,4" FontFamily="Segoe UI"/>
                        <TextBox x:Name="dlgWebPort" Background="#1a1a1a" Foreground="#eee" BorderBrush="#333"
                                 BorderThickness="1" Padding="10,8" FontSize="13" FontFamily="Segoe UI" Text="8080"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2">
                        <TextBlock Text="Game port" FontSize="11" Foreground="#888" Margin="0,0,0,4" FontFamily="Segoe UI"/>
                        <TextBox x:Name="dlgGamePort" Background="#1a1a1a" Foreground="#eee" BorderBrush="#333"
                                 BorderThickness="1" Padding="10,8" FontSize="13" FontFamily="Segoe UI" Text="10000"/>
                    </StackPanel>
                </Grid>
                <TextBlock Text="Stats Code (iz dedicatedServerConfig.xml)" FontSize="11" Foreground="#888" Margin="0,12,0,4" FontFamily="Segoe UI"/>
                <TextBox x:Name="dlgStats" Background="#1a1a1a" Foreground="#eee" BorderBrush="#333"
                         BorderThickness="1" Padding="10,8" FontSize="13" FontFamily="Segoe UI"/>
                <TextBlock Text="Server Password (igracki)" FontSize="11" Foreground="#888" Margin="0,12,0,4" FontFamily="Segoe UI"/>
                <TextBox x:Name="dlgPass" Background="#1a1a1a" Foreground="#eee" BorderBrush="#333"
                         BorderThickness="1" Padding="10,8" FontSize="13" FontFamily="Segoe UI"/>
            </StackPanel>
            <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
                <Button x:Name="dlgCancel" Content="Odustani" Background="Transparent" Foreground="#888"
                        BorderThickness="1" BorderBrush="#333" Padding="18,9" FontFamily="Segoe UI"
                        FontSize="12" Cursor="Hand" Margin="0,0,8,0"/>
                <Button x:Name="dlgOk" Content="Dodaj Server" Background="#F5C518" Foreground="#111"
                        BorderThickness="0" Padding="20,9" FontFamily="Segoe UI" FontWeight="SemiBold"
                        FontSize="12" Cursor="Hand"/>
            </StackPanel>
        </Grid>
    </Border>
</Window>
'@
    $reader2 = New-Object System.Xml.XmlNodeReader $dlgXaml
    $dlg = [Windows.Markup.XamlReader]::Load($reader2)
    $dlg.Owner = $window
    $dlgName = $dlg.FindName("dlgName")
    $dlgIp = $dlg.FindName("dlgIp")
    $dlgWebPort = $dlg.FindName("dlgWebPort")
    $dlgGamePort = $dlg.FindName("dlgGamePort")
    $dlgStats = $dlg.FindName("dlgStats")
    $dlgPass = $dlg.FindName("dlgPass")
    $dlgOk = $dlg.FindName("dlgOk")
    $dlgCancel = $dlg.FindName("dlgCancel")
    $dlg.Add_MouseLeftButtonDown({ try { $dlg.DragMove() } catch {} })
    $dlgCancel.Add_Click({ $dlg.Tag = $null; $dlg.Close() })
    $dlgOk.Add_Click({
        if (-not $dlgName.Text -or -not $dlgIp.Text) {
            return
        }
        $wp = 8080; $gp = 10000
        [int]::TryParse($dlgWebPort.Text, [ref]$wp) | Out-Null
        [int]::TryParse($dlgGamePort.Text, [ref]$gp) | Out-Null
        $dlg.Tag = [PSCustomObject]@{
            name      = $dlgName.Text.Trim()
            ip        = $dlgIp.Text.Trim()
            webPort   = $wp
            gamePort  = $gp
            statsCode = $dlgStats.Text.Trim()
            password  = $dlgPass.Text
            isCustom  = $true
        }
        $dlg.Close()
    })
    $dlg.ShowDialog() | Out-Null
    return $dlg.Tag
}

$btnAddCustomServer.Add_Click({
    $newSrv = Show-AddServerDialog
    if ($newSrv) {
        # Provjeri duplikate po imenu
        if ($script:Config.servers | Where-Object { $_.name -eq $newSrv.name }) {
            Show-Toast ("Server {0} vec postoji" -f $newSrv.name) "warn"
            return
        }
        $script:Config.servers += $newSrv
        $script:Config.activeServer = $script:Config.servers.Count - 1
        Save-Config
        Update-ServerButtons
        Refresh-ServerStatus
        Update-ServerPings
        Show-Toast "Server dodan: $($newSrv.name)" "success"
        Write-Log ('Custom server dodan: {0} ({1}:{2})' -f $newSrv.name, $newSrv.ip, $newSrv.gamePort)
    }
})

# ============================================================
# v1.2 - CONFIG BACKUP / RESTORE
# ============================================================

# ============================================================
# v2.0 - TEME / IZGLED / PONASANJE
# ============================================================
function Apply-Theme {
    param([string]$hex = "#F5C518")
    try {
        $col = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
        $r=$col.R; $g=$col.G; $b=$col.B
        $bright = [System.Windows.Media.Color]::FromRgb(
            [byte][Math]::Min(255, $r+30),
            [byte][Math]::Min(255, $g+30),
            [byte][Math]::Min(255, $b+30))
        $dim = [System.Windows.Media.Color]::FromRgb(
            [byte]([Math]::Max(0, $r-50)),
            [byte]([Math]::Max(0, $g-50)),
            [byte]([Math]::Max(0, $b-50)))

        # Color map: hardcoded gold tints in XAML => corresponding new theme color.
        # Keys are uppercase hex strings (no leading #).
        $script:ColorRemap = @{
            "F5C518" = $col       # primary
            "FFD84D" = $bright    # bright accent
            "BF9B0F" = $dim       # dim
            "E5A82E" = $col       # warning gold
            "7A5A10" = $dim       # deep brown gold
            "3A2E10" = [System.Windows.Media.Color]::FromArgb(255,
                [byte]([Math]::Max(0,$r-90)), [byte]([Math]::Max(0,$g-90)), [byte]([Math]::Max(0,$b-90)))
        }

        # 1) Update named resource brushes (StaticResource consumers).
        $changed = 0
        foreach ($pair in @(@("Gold",$col),@("GoldBright",$bright),@("GoldDim",$dim))) {
            try {
                $br = $window.TryFindResource($pair[0])
                if (-not $br) { $br = $window.Resources[$pair[0]] }
                if ($br) {
                    if ($br.IsFrozen) {
                        $br = $br.Clone()
                        $window.Resources[$pair[0]] = $br
                    }
                    $anim = New-Object System.Windows.Media.Animation.ColorAnimation
                    $anim.To = $pair[1]
                    $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(350))
                    $br.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $anim)
                    $changed++
                }
            } catch { Write-Log "brush $($pair[0]) err: $_" }
        }

        # 2) Walk visual tree and remap any SolidColorBrush whose color matches
        #    a known gold tint to the new theme color. This catches the 70+
        #    hardcoded #F5C518 occurrences in the XAML.
        $walked = 0; $reskin = 0
        $visited = New-Object 'System.Collections.Generic.HashSet[int]'
        Reskin-VisualTree -Element $window -Map $script:ColorRemap -Counters ([ref]$walked) -Skinned ([ref]$reskin) -Visited $visited

        $script:Config.theme = $hex
        Write-Log "Tema: $hex (resource brushes: $changed, walked: $walked, reskinned: $reskin)"
    } catch { Write-Log "Theme apply error: $_" }
}

function Reskin-VisualTree {
    param(
        [System.Windows.DependencyObject]$Element,
        [hashtable]$Map,
        [ref]$Counters,
        [ref]$Skinned,
        [System.Collections.Generic.HashSet[int]]$Visited
    )
    if (-not $Element) { return }
    if ($Visited) {
        $hk = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Element)
        if (-not $Visited.Add($hk)) { return }
    }
    $Counters.Value++

    # Direct typed property access (faster than reflection per node).
    try {
        if ($Element -is [System.Windows.Controls.Control]) {
            foreach ($prop in 'Foreground','Background','BorderBrush') {
                $val = $Element.$prop
                if ($val -is [System.Windows.Media.SolidColorBrush]) {
                    $hex2 = ('{0:X2}{1:X2}{2:X2}' -f $val.Color.R,$val.Color.G,$val.Color.B)
                    if ($Map.ContainsKey($hex2)) {
                        $nb = New-Object System.Windows.Media.SolidColorBrush $Map[$hex2]
                        $nb.Opacity = $val.Opacity
                        $Element.$prop = $nb
                        $Skinned.Value++
                    }
                }
            }
        }
        elseif ($Element -is [System.Windows.Controls.TextBlock]) {
            foreach ($prop in 'Foreground','Background') {
                $val = $Element.$prop
                if ($val -is [System.Windows.Media.SolidColorBrush]) {
                    $hex2 = ('{0:X2}{1:X2}{2:X2}' -f $val.Color.R,$val.Color.G,$val.Color.B)
                    if ($Map.ContainsKey($hex2)) {
                        $nb = New-Object System.Windows.Media.SolidColorBrush $Map[$hex2]
                        $nb.Opacity = $val.Opacity
                        $Element.$prop = $nb
                        $Skinned.Value++
                    }
                }
            }
        }
        elseif ($Element -is [System.Windows.Controls.Border]) {
            foreach ($prop in 'Background','BorderBrush') {
                $val = $Element.$prop
                if ($val -is [System.Windows.Media.SolidColorBrush]) {
                    $hex2 = ('{0:X2}{1:X2}{2:X2}' -f $val.Color.R,$val.Color.G,$val.Color.B)
                    if ($Map.ContainsKey($hex2)) {
                        $nb = New-Object System.Windows.Media.SolidColorBrush $Map[$hex2]
                        $nb.Opacity = $val.Opacity
                        $Element.$prop = $nb
                        $Skinned.Value++
                    }
                }
            }
        }
        elseif ($Element -is [System.Windows.Controls.Panel]) {
            $val = $Element.Background
            if ($val -is [System.Windows.Media.SolidColorBrush]) {
                $hex2 = ('{0:X2}{1:X2}{2:X2}' -f $val.Color.R,$val.Color.G,$val.Color.B)
                if ($Map.ContainsKey($hex2)) {
                    $nb = New-Object System.Windows.Media.SolidColorBrush $Map[$hex2]
                    $nb.Opacity = $val.Opacity
                    $Element.Background = $nb
                    $Skinned.Value++
                }
            }
        }
        elseif ($Element -is [System.Windows.Shapes.Shape]) {
            foreach ($prop in 'Fill','Stroke') {
                $val = $Element.$prop
                if ($val -is [System.Windows.Media.SolidColorBrush]) {
                    $hex2 = ('{0:X2}{1:X2}{2:X2}' -f $val.Color.R,$val.Color.G,$val.Color.B)
                    if ($Map.ContainsKey($hex2)) {
                        $nb = New-Object System.Windows.Media.SolidColorBrush $Map[$hex2]
                        $nb.Opacity = $val.Opacity
                        $Element.$prop = $nb
                        $Skinned.Value++
                    }
                }
            }
        }
    } catch {}

    # Effects (DropShadow glow color)
    if ($Element -is [System.Windows.UIElement]) {
        try {
            $eff = $Element.Effect
            if ($eff -and $eff.GetType().Name -eq 'DropShadowEffect' -and -not $eff.IsFrozen) {
                $hex2 = ('{0:X2}{1:X2}{2:X2}' -f $eff.Color.R, $eff.Color.G, $eff.Color.B)
                if ($Map.ContainsKey($hex2)) {
                    $eff.Color = $Map[$hex2]
                    $Skinned.Value++
                }
            }
        } catch {}
    }

    # Recurse visual children only (logical fallback caused dupe walks/freeze)
    try {
        $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Element)
        for ($i = 0; $i -lt $count; $i++) {
            $child = [System.Windows.Media.VisualTreeHelper]::GetChild($Element, $i)
            Reskin-VisualTree -Element $child -Map $Map -Counters $Counters -Skinned $Skinned -Visited $Visited
        }
    } catch {}
}

function Apply-AnimBackground {
    param([bool]$enabled)
    if (-not $bgCanvas) { return }
    $bgCanvas.Visibility = if ($enabled) { "Visible" } else { "Collapsed" }
    $script:Config.animBg = $enabled
}

function Apply-GlowEffects {
    param([bool]$enabled)
    # Globalno: ako je off, isključi sve DropShadowEffect na top-level rootu
    # Praktično: postavi flag, sljedeci refresh primijeni; za sad samo persistira
    $script:Config.glow = $enabled
}

if ($themeGold)   { $themeGold.Add_Checked({ Apply-Theme "#F5C518"; Save-Config }) }
if ($themeGreen)  { $themeGreen.Add_Checked({ Apply-Theme "#30A46C"; Save-Config }) }
if ($themeBlue)   { $themeBlue.Add_Checked({ Apply-Theme "#5b8cff"; Save-Config }) }
if ($themePurple) { $themePurple.Add_Checked({ Apply-Theme "#9d8df5"; Save-Config }) }
if ($themeRed)    { $themeRed.Add_Checked({ Apply-Theme "#E5484D"; Save-Config }) }

if ($chkAnimBg) {
    $chkAnimBg.Add_Checked({   Apply-AnimBackground $true;  Save-Config })
    $chkAnimBg.Add_Unchecked({ Apply-AnimBackground $false; Save-Config })
}
if ($chkGlow) {
    $chkGlow.Add_Checked({   Apply-GlowEffects $true;  Save-Config })
    $chkGlow.Add_Unchecked({ Apply-GlowEffects $false; Save-Config })
}
if ($btnSaveBehavior) {
    $btnSaveBehavior.Add_Click({
        $script:Config.autoClose    = [bool]$chkAutoClose.IsChecked
        $script:Config.autoRefresh  = [bool]$chkAutoRefresh.IsChecked
        $script:Config.toastsEnabled= [bool]$chkToasts.IsChecked
        $script:Config.sizeCheck    = [bool]$chkSizeCheck.IsChecked
        Save-Config
        if ($chkHideWalkthrough) {
            $ws = Get-WalkthroughSettings
            $ws.skipOnLaunch = [bool]$chkHideWalkthrough.IsChecked
            Save-WalkthroughSettings $ws
        }
        Show-Toast "Postavke spremljene" "success"
    })
}

# Inicijalna primjena spremljene teme + flagova
try {
    if ($script:Config.theme) { Apply-Theme $script:Config.theme }
    if ($null -ne $script:Config.animBg)       { Apply-AnimBackground ([bool]$script:Config.animBg); $chkAnimBg.IsChecked = [bool]$script:Config.animBg }
    if ($null -ne $script:Config.glow)         { $chkGlow.IsChecked = [bool]$script:Config.glow }
    if ($null -ne $script:Config.autoClose)    { $chkAutoClose.IsChecked = [bool]$script:Config.autoClose }
    if ($null -ne $script:Config.autoRefresh)  { $chkAutoRefresh.IsChecked = [bool]$script:Config.autoRefresh }
    if ($null -ne $script:Config.toastsEnabled){ $chkToasts.IsChecked = [bool]$script:Config.toastsEnabled }
    if ($null -ne $script:Config.sizeCheck)    { $chkSizeCheck.IsChecked = [bool]$script:Config.sizeCheck }
    try {
        $wtSet = Get-WalkthroughSettings
        if ($chkHideWalkthrough) { $chkHideWalkthrough.IsChecked = [bool]$wtSet.skipOnLaunch }
    } catch {}
    # Auto-check theme radio
    switch ($script:Config.theme) {
        "#30A46C" { $themeGreen.IsChecked  = $true }
        "#5b8cff" { $themeBlue.IsChecked   = $true }
        "#9d8df5" { $themePurple.IsChecked = $true }
        "#E5484D" { $themeRed.IsChecked    = $true }
        default   { $themeGold.IsChecked   = $true }
    }
} catch {}

$btnExportConfig.Add_Click({
    $sfd = New-Object Microsoft.Win32.SaveFileDialog
    $sfd.Filter = "JSON config|*.json"
    $sfd.FileName = "sr_launcher_backup_$(Get-Date -Format 'yyyyMMdd_HHmm').json"
    if ($sfd.ShowDialog($window)) {
        try {
            Copy-Item $script:ConfigPath $sfd.FileName -Force
            Show-Toast "Config izvezen" "success"
            Write-Log "Config exportiran u: $($sfd.FileName)"
        } catch {
            Show-Toast "Export greska: $($_.Exception.Message)" "error"
        }
    }
})
$btnImportConfig.Add_Click({
    $ofd = New-Object Microsoft.Win32.OpenFileDialog
    $ofd.Filter = "JSON config|*.json"
    if ($ofd.ShowDialog($window)) {
        try {
            $imported = Get-Content $ofd.FileName -Raw | ConvertFrom-Json
            if (-not $imported.servers) { Show-Toast "Nevazeci config (nema servera)" "error"; return }
            $r = Show-SRConfirm "Uvezi config? Trenutni ce biti zamijenjen.`n`nServeri: $($imported.servers.Count)" "SR Launcher" "Uvezi" "Odustani"
            if ($r -eq 'Yes') {
                Copy-Item $ofd.FileName $script:ConfigPath -Force
                Show-Toast "Config uvezen - restart launchera" "success" 5000
                Write-Log "Config importiran iz: $($ofd.FileName). Restart preporucen."
            }
        } catch {
            Show-Toast "Import greska: $($_.Exception.Message)" "error"
        }
    }
})

$window.Add_Loaded({
  # Dashboard: preload s splasha; update provjera u zasebnom Loaded handleru iznad
    $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{
        try {
            if ($script:PreloadedServerStatus) {
                Refresh-ServerStatus -Silent -PreloadedStatus $script:PreloadedServerStatus
                $script:PreloadedServerStatus = $null
            } else {
                Refresh-ServerStatus -Silent
            }
        } catch {}
        try {
            if ($script:PreloadedModList) {
                Refresh-ModList -PreloadedServerMods $script:PreloadedModList
                $script:PreloadedModList = $null
            } elseif (-not $script:ModListCached) {
                Refresh-ModList
            }
        } catch {}
        try {
            $gs = $script:PreloadedGameSettings
            if (-not $gs) { $gs = Read-GameSettings }
            if ($gs) {
                $chkIntroScene.IsChecked = $gs.introScene
                $chkDevConsole.IsChecked = $gs.devConsole
            }
            $script:PreloadedGameSettings = $null
        } catch {}
    }) | Out-Null

    # Auto-refresh status every 60 seconds (tiho - bez log spama)
    $script:autoRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:autoRefreshTimer.Interval = [TimeSpan]::FromSeconds(60)
    $script:autoRefreshTimer.Add_Tick({ Refresh-ServerStatus -Silent })
    $script:autoRefreshTimer.Start()

    # Server pingovi - prvo odmah, pa svake 30s
    $script:pingTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:pingTimer.Interval = [TimeSpan]::FromSeconds(30)
    $script:pingTimer.Add_Tick({ Update-ServerPings })
    $script:pingTimer.Start()
    # Prvi ping nakon 500ms (ne blokiramo Loaded)
    $script:firstPing = New-Object System.Windows.Threading.DispatcherTimer
    $script:firstPing.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:firstPing.Add_Tick({ $script:firstPing.Stop(); Update-ServerPings })
    $script:firstPing.Start()

    # Walkthrough pri prvom pokretanju (ako nije iskljucen u AppData)
    $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ApplicationIdle, [Action]{
        try {
            if ($walkthroughOverlay) {
                $wt = Get-WalkthroughSettings
                if (-not $wt.skipOnLaunch) { Show-WalkthroughOverlay }
            }
        } catch {}
        try {
            if (Test-DesktopShortcutNeedsRepair) {
                Repair-SRManagerDesktopShortcut | Out-Null
            }
        } catch {}
    }) | Out-Null

    # =========================================================================
    # FARM-THEMED ANIMATED BACKGROUND (wheat, fence, farm silhouette, dust)
    # =========================================================================
    if ($bgCanvas) {
        try {
            $W = 1080.0
            $H = 740.0
            $rng = New-Object System.Random

            $goldDim    = [System.Windows.Media.ColorConverter]::ConvertFromString("#3a2e10")
            $goldWheat  = [System.Windows.Media.ColorConverter]::ConvertFromString("#7a5a10")
            $goldBright = [System.Windows.Media.ColorConverter]::ConvertFromString("#BF9B0F")
            $goldDust   = [System.Windows.Media.ColorConverter]::ConvertFromString("#F5C518")
            $silDark    = [System.Windows.Media.ColorConverter]::ConvertFromString("#0a0805")

            # ---- HORIZON GLOW (subtle warm strip) ----
            $horizon = New-Object System.Windows.Shapes.Rectangle
            $horizon.Width = $W
            $horizon.Height = 220
            $hgrad = New-Object System.Windows.Media.LinearGradientBrush
            $hgrad.StartPoint = [System.Windows.Point]::new(0,0)
            $hgrad.EndPoint = [System.Windows.Point]::new(0,1)
            $g1 = [System.Windows.Media.GradientStop]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#00000000"), 0.0)
            $g2 = [System.Windows.Media.GradientStop]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#1AF5C518"), 0.7)
            $g3 = [System.Windows.Media.GradientStop]::new([System.Windows.Media.ColorConverter]::ConvertFromString("#33BF9B0F"), 1.0)
            $hgrad.GradientStops.Add($g1); $hgrad.GradientStops.Add($g2); $hgrad.GradientStops.Add($g3)
            $horizon.Fill = $hgrad
            [System.Windows.Controls.Canvas]::SetLeft($horizon, 0)
            [System.Windows.Controls.Canvas]::SetTop($horizon, 480)
            [void]$bgCanvas.Children.Add($horizon)

            # ---- DISTANT FARM SILHOUETTES (right side) ----
            # Main barn (body + roof)
            $barnBody = New-Object System.Windows.Shapes.Rectangle
            $barnBody.Width = 70; $barnBody.Height = 32
            $barnBody.Fill = New-Object System.Windows.Media.SolidColorBrush $silDark
            $barnBody.Opacity = 0.85
            [System.Windows.Controls.Canvas]::SetLeft($barnBody, 820)
            [System.Windows.Controls.Canvas]::SetTop($barnBody, 558)
            [void]$bgCanvas.Children.Add($barnBody)

            $barnRoof = New-Object System.Windows.Shapes.Polygon
            $barnRoof.Points = New-Object System.Windows.Media.PointCollection
            $barnRoof.Points.Add([System.Windows.Point]::new(815,558))
            $barnRoof.Points.Add([System.Windows.Point]::new(855,536))
            $barnRoof.Points.Add([System.Windows.Point]::new(895,558))
            $barnRoof.Fill = New-Object System.Windows.Media.SolidColorBrush $silDark
            $barnRoof.Opacity = 0.9
            [void]$bgCanvas.Children.Add($barnRoof)

            # Silo
            $silo = New-Object System.Windows.Shapes.Rectangle
            $silo.Width = 14; $silo.Height = 46
            $silo.Fill = New-Object System.Windows.Media.SolidColorBrush $silDark
            $silo.Opacity = 0.85
            [System.Windows.Controls.Canvas]::SetLeft($silo, 902)
            [System.Windows.Controls.Canvas]::SetTop($silo, 544)
            [void]$bgCanvas.Children.Add($silo)
            $siloCap = New-Object System.Windows.Shapes.Ellipse
            $siloCap.Width = 14; $siloCap.Height = 8
            $siloCap.Fill = New-Object System.Windows.Media.SolidColorBrush $silDark
            $siloCap.Opacity = 0.9
            [System.Windows.Controls.Canvas]::SetLeft($siloCap, 902)
            [System.Windows.Controls.Canvas]::SetTop($siloCap, 540)
            [void]$bgCanvas.Children.Add($siloCap)

            # Small house (left of barn)
            $house = New-Object System.Windows.Shapes.Rectangle
            $house.Width = 36; $house.Height = 22
            $house.Fill = New-Object System.Windows.Media.SolidColorBrush $silDark
            $house.Opacity = 0.8
            [System.Windows.Controls.Canvas]::SetLeft($house, 760)
            [System.Windows.Controls.Canvas]::SetTop($house, 568)
            [void]$bgCanvas.Children.Add($house)
            $hroof = New-Object System.Windows.Shapes.Polygon
            $hroof.Points = New-Object System.Windows.Media.PointCollection
            $hroof.Points.Add([System.Windows.Point]::new(757,568))
            $hroof.Points.Add([System.Windows.Point]::new(778,553))
            $hroof.Points.Add([System.Windows.Point]::new(799,568))
            $hroof.Fill = New-Object System.Windows.Media.SolidColorBrush $silDark
            $hroof.Opacity = 0.85
            [void]$bgCanvas.Children.Add($hroof)

            # Distant trees
            foreach ($tx in @(120, 180, 240, 670, 990)) {
                $tr = New-Object System.Windows.Shapes.Ellipse
                $tr.Width = 28 + $rng.Next(0,14); $tr.Height = 32 + $rng.Next(0,16)
                $tr.Fill = New-Object System.Windows.Media.SolidColorBrush $silDark
                $tr.Opacity = 0.55
                [System.Windows.Controls.Canvas]::SetLeft($tr, $tx)
                [System.Windows.Controls.Canvas]::SetTop($tr, 568 - $tr.Height/2)
                [void]$bgCanvas.Children.Add($tr)
            }

            # ---- WOODEN FENCE (mid-bottom horizon line) ----
            $fenceY = 612
            $fenceBrush = New-Object System.Windows.Media.SolidColorBrush $goldDim
            # 2 horizontal rails
            for ($r=0; $r -lt 2; $r++) {
                $rail = New-Object System.Windows.Shapes.Line
                $rail.X1 = 0; $rail.X2 = $W
                $rail.Y1 = $fenceY + ($r*8); $rail.Y2 = $fenceY + ($r*8)
                $rail.Stroke = $fenceBrush
                $rail.StrokeThickness = 2
                $rail.Opacity = 0.45
                [void]$bgCanvas.Children.Add($rail)
            }
            # Vertical posts every 56px
            for ($x=20; $x -lt $W; $x += 56) {
                $post = New-Object System.Windows.Shapes.Line
                $post.X1 = $x; $post.X2 = $x
                $post.Y1 = $fenceY - 6; $post.Y2 = $fenceY + 22
                $post.Stroke = $fenceBrush
                $post.StrokeThickness = 3
                $post.Opacity = 0.55
                [void]$bgCanvas.Children.Add($post)
            }

            # ---- WHEAT FIELD (~110 strands across bottom) ----
            $wheatBrush1 = New-Object System.Windows.Media.SolidColorBrush $goldWheat
            $wheatBrush2 = New-Object System.Windows.Media.SolidColorBrush $goldBright
            for ($i=0; $i -lt 130; $i++) {
                $sx = $rng.Next(-8, [int]$W + 8)
                $sh = $rng.Next(34, 88)
                $sBaseY = 720 + $rng.Next(-6, 12)
                # Stalk
                $stalk = New-Object System.Windows.Shapes.Line
                $stalk.X1 = $sx; $stalk.X2 = $sx + $rng.Next(-3,4)
                $stalk.Y1 = $sBaseY; $stalk.Y2 = $sBaseY - $sh
                $stalk.Stroke = if ($i % 3 -eq 0) { $wheatBrush2 } else { $wheatBrush1 }
                $stalk.StrokeThickness = 1
                $stalk.Opacity = (0.18 + ($rng.NextDouble() * 0.28))
                [void]$bgCanvas.Children.Add($stalk)
                # Head (small angled line on top)
                $head = New-Object System.Windows.Shapes.Line
                $head.X1 = $stalk.X2 - 2; $head.X2 = $stalk.X2 + 2
                $head.Y1 = $stalk.Y2 - 4; $head.Y2 = $stalk.Y2
                $head.Stroke = $wheatBrush2
                $head.StrokeThickness = 2
                $head.Opacity = $stalk.Opacity * 1.3
                if ($head.Opacity -gt 1) { $head.Opacity = 1 }
                [void]$bgCanvas.Children.Add($head)
            }

            # ---- DUST PARTICLES (animated via timer) ----
            $script:DustParticles = New-Object System.Collections.ArrayList
            for ($d=0; $d -lt 28; $d++) {
                $dot = New-Object System.Windows.Shapes.Ellipse
                $sz = 2 + $rng.NextDouble() * 3.5
                $dot.Width = $sz; $dot.Height = $sz
                $dot.Fill = New-Object System.Windows.Media.SolidColorBrush $goldDust
                $dot.Opacity = 0.05 + ($rng.NextDouble() * 0.22)
                $startX = [double]$rng.Next(0, [int]$W)
                $startY = [double]$rng.Next(200, [int]$H)
                [System.Windows.Controls.Canvas]::SetLeft($dot, $startX)
                [System.Windows.Controls.Canvas]::SetTop($dot, $startY)
                [void]$bgCanvas.Children.Add($dot)
                [void]$script:DustParticles.Add([PSCustomObject]@{
                    El      = $dot
                    X       = $startX
                    Y       = $startY
                    Vx      = (0.10 + ($rng.NextDouble() * 0.45)) * $(if ($rng.Next(0,2) -eq 0) { 1 } else { -1 })
                    Vy      = -(0.15 + ($rng.NextDouble() * 0.45))
                    Phase   = $rng.NextDouble() * 6.283
                    Sway    = 0.15 + ($rng.NextDouble() * 0.55)
                    BaseOp  = $dot.Opacity
                })
            }

            $script:DustTick = 0
            $script:DustTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:DustTimer.Interval = [TimeSpan]::FromMilliseconds(40)
            $script:DustTimer.Add_Tick({
                $script:DustTick++
                $t = $script:DustTick * 0.04
                foreach ($p in $script:DustParticles) {
                    $p.X += $p.Vx + ([Math]::Sin($t + $p.Phase) * $p.Sway * 0.18)
                    $p.Y += $p.Vy
                    if ($p.Y -lt 120) {
                        $p.Y = 720
                        $p.X = [double](Get-Random -Minimum 0 -Maximum 1080)
                    }
                    if ($p.X -lt -10) { $p.X = 1085 }
                    if ($p.X -gt 1090) { $p.X = -5 }
                    [System.Windows.Controls.Canvas]::SetLeft($p.El, $p.X)
                    [System.Windows.Controls.Canvas]::SetTop($p.El, $p.Y)
                    # Subtle opacity flicker
                    $p.El.Opacity = $p.BaseOp * (0.75 + 0.25 * [Math]::Sin($t * 2 + $p.Phase))
                }
            })
            $script:DustTimer.Start()
        } catch {
            Write-Log "GRESKA pri kreiranju farm pozadine: $($_.Exception.Message)"
        }
    }
})

# ============================================================
# LICENSE GATE (prije nego se otvori glavni prozor)
# ============================================================
function Show-LicenseWindow {
    param([string]$prefillKey = "", [string]$errorMsg = "")
    $licXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Width="540" Height="430" WindowStartupLocation="CenterScreen" ShowInTaskbar="True">
    <Border CornerRadius="14" BorderThickness="1" ClipToBounds="True">
        <Border.BorderBrush>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#3a2e10" Offset="0"/>
                <GradientStop Color="#1f1f1f" Offset="1"/>
            </LinearGradientBrush>
        </Border.BorderBrush>
        <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#0d0d0d" Offset="0"/>
                <GradientStop Color="#0a0a0a" Offset="1"/>
            </LinearGradientBrush>
        </Border.Background>
        <Border.Effect>
            <DropShadowEffect Color="Black" BlurRadius="32" ShadowDepth="0" Opacity="0.7"/>
        </Border.Effect>
        <Grid x:Name="root">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <!-- Title bar -->
            <Grid Grid.Row="0" Height="48" x:Name="titleBar">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Slavonska Ravnica - Aktivacija" FontSize="12"
                           Foreground="#888" FontFamily="Segoe UI" VerticalAlignment="Center"
                           Margin="18,0,0,0"/>
                <Button Grid.Column="1" x:Name="btnLicClose" Width="36" Height="36"
                        Background="Transparent" BorderThickness="0" Foreground="#888"
                        FontFamily="Segoe MDL2 Assets" Content="&#xE8BB;" FontSize="11"
                        Cursor="Hand" Margin="0,0,8,0"/>
            </Grid>
            <!-- Body -->
            <StackPanel Grid.Row="1" Margin="40,8,40,12">
                <Border Width="56" Height="56" CornerRadius="14" HorizontalAlignment="Left"
                        Margin="0,0,0,18">
                    <Border.Background>
                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                            <GradientStop Color="#F5C518" Offset="0"/>
                            <GradientStop Color="#BF9B0F" Offset="1"/>
                        </LinearGradientBrush>
                    </Border.Background>
                    <Border.Effect>
                        <DropShadowEffect Color="#F5C518" BlurRadius="22" ShadowDepth="0" Opacity="0.6"/>
                    </Border.Effect>
                    <TextBlock Text="&#xE192;" FontFamily="Segoe MDL2 Assets" FontSize="26"
                               Foreground="#111" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <TextBlock Text="Aktivacija licence" FontSize="22" FontWeight="Bold"
                           Foreground="#f0f0f0" FontFamily="Segoe UI"/>
                <TextBlock Text="Unesi svoj licencni kljuc. Ako jos nemas, mozes zatraziti besplatnu 3-dnevnu probnu licencu (jedna po ra&#269;unalu)."
                           FontSize="12" Foreground="#888" FontFamily="Segoe UI"
                           TextWrapping="Wrap" Margin="0,6,0,18"/>

                <TextBlock Text="LICENCNI KLJUC" FontSize="9" FontWeight="Bold"
                           Foreground="#666" FontFamily="Segoe UI" Margin="0,0,0,6"/>
                <Border Background="#0a0a0a" CornerRadius="8" BorderBrush="#2a2a2a"
                        BorderThickness="1" Padding="12,3">
                    <TextBox x:Name="txtLicKey" Background="Transparent" BorderThickness="0"
                             Foreground="#F5C518" FontFamily="Consolas" FontSize="14"
                             Padding="0,8" CaretBrush="#F5C518"
                             Text=""/>
                </Border>

                <TextBlock x:Name="txtLicErr" Text="" Foreground="#E5484D" FontSize="11"
                           FontFamily="Segoe UI" Margin="0,10,0,0" TextWrapping="Wrap"
                           Visibility="Collapsed"/>
                <TextBlock x:Name="txtLicOk" Text="" Foreground="#30A46C" FontSize="11"
                           FontFamily="Segoe UI" Margin="0,10,0,0" TextWrapping="Wrap"
                           Visibility="Collapsed"/>

                <StackPanel Orientation="Horizontal" Margin="0,18,0,0">
                    <Button x:Name="btnLicActivate" Content="AKTIVIRAJ" Padding="22,10"
                            Background="#F5C518" Foreground="#111" FontWeight="Bold" FontSize="13"
                            BorderThickness="0" Cursor="Hand" FontFamily="Segoe UI"/>
                    <Button x:Name="btnLicTrial" Content="Probna licenca (3 dana)"
                            Background="Transparent" Foreground="#F5C518" FontSize="12"
                            BorderThickness="1" BorderBrush="#333" Cursor="Hand"
                            Padding="16,9" Margin="10,0,0,0" FontFamily="Segoe UI"/>
                </StackPanel>
            </StackPanel>
            <!-- Footer -->
            <Grid Grid.Row="2" Background="#080808" Height="36">
                <TextBlock x:Name="txtLicFooter" Text="HWID: -" FontSize="9" Foreground="#444"
                           FontFamily="Consolas" VerticalAlignment="Center" Margin="18,0,0,0"/>
            </Grid>
        </Grid>
    </Border>
</Window>
"@
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($licXaml))
    $licWin = [Windows.Markup.XamlReader]::Load($reader)
    $txt = $licWin.FindName("txtLicKey")
    $err = $licWin.FindName("txtLicErr")
    $okt = $licWin.FindName("txtLicOk")
    $btnA = $licWin.FindName("btnLicActivate")
    $btnT = $licWin.FindName("btnLicTrial")
    $btnC = $licWin.FindName("btnLicClose")
    $foot = $licWin.FindName("txtLicFooter")
    $tBar = $licWin.FindName("titleBar")
    $hwid = Get-Hwid
    $foot.Text = "HWID: $($hwid.Substring(0, [Math]::Min(16, $hwid.Length)))..."
    if ($prefillKey) { $txt.Text = $prefillKey }
    if ($errorMsg) { $err.Text = $errorMsg; $err.Visibility = "Visible" }
    $tBar.Add_MouseLeftButtonDown({ try { $licWin.DragMove() } catch {} })
    $btnC.Add_Click({ $licWin.Tag = "cancel"; $licWin.Close() })
    $btnT.Add_Click({
        $err.Visibility = "Collapsed"; $okt.Visibility = "Collapsed"
        $btnT.IsEnabled = $false; $btnT.Content = "Trazim..."
        try {
            $api = Get-LicenseApiConfig
            if (-not $api) {
                $err.Text = "Licenca API nije konfiguriran."
                $err.Visibility = "Visible"
                $btnT.IsEnabled = $true; $btnT.Content = "Probna licenca (3 dana)"
                return
            }
            $body = @{ hwid = $hwid; playerName = $env:USERNAME } | ConvertTo-Json -Compress
            $url = "$($api.url)/api/license/trial"
            $resp = Invoke-WebRequest -Uri $url -Method POST -Body $body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 15
            $obj = $resp.Content | ConvertFrom-Json
            if (-not $obj.ok) {
                $err.Text = if ($obj.reason) { $obj.reason } else { "Nepoznata greska." }
                $err.Visibility = "Visible"
                $btnT.IsEnabled = $true; $btnT.Content = "Probna licenca (3 dana)"
                return
            }
            $txt.Text = $obj.key
            $okt.Text = "Probna licenca generirana - klikni AKTIVIRAJ."
            $okt.Visibility = "Visible"
            $btnT.IsEnabled = $false; $btnT.Content = "Generirana"
        } catch {
            $msg = $_.Exception.Message
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader2 = New-Object System.IO.StreamReader($stream)
                    $errBody = $reader2.ReadToEnd()
                    $errObj = $errBody | ConvertFrom-Json -ErrorAction Stop
                    if ($errObj.reason) { $msg = [string]$errObj.reason }
                }
            } catch {}
            $err.Text = "Greska: $msg"
            $err.Visibility = "Visible"
            $btnT.IsEnabled = $true; $btnT.Content = "Probna licenca (3 dana)"
        }
    })
    $btnA.Add_Click({
        $err.Visibility = "Collapsed"; $okt.Visibility = "Collapsed"
        $key = ($txt.Text).Trim()
        if (-not $key) { $err.Text = "Unesi kljuc."; $err.Visibility = "Visible"; return }
        $btnA.IsEnabled = $false; $btnA.Content = "Provjera..."
        # Defer actual HTTP call so the UI repaints with "Provjera..." first.
        $licWin.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{
            $r = $null
            try {
                $r = Test-License -key $key -hwid $hwid
            } catch {
                $err.Text = "Greska kod provjere: $($_.Exception.Message)"
                $err.Visibility = "Visible"
                $btnA.IsEnabled = $true; $btnA.Content = "AKTIVIRAJ"
                return
            }
            if (-not $r -or -not $r.ok) {
                $err.Text = if ($r -and $r.reason) { [string]$r.reason } else { "Nepoznata greska." }
                $err.Visibility = "Visible"
                $btnA.IsEnabled = $true; $btnA.Content = "AKTIVIRAJ"
                return
            }
            # Save cache
            try {
                $cache = @{
                    key = $key
                    keyHash = (Get-SHA256 $key)
                    hwid = $hwid
                    expiresAt = $r.entry.expiresAt
                    discordId = [string]$r.entry.discordId
                    permanent = [bool]$r.entry.permanent
                    lastCheck = (Get-Date).ToUniversalTime().ToString("o")
                }
                Save-LicenseCache $cache | Out-Null
            } catch {
                $err.Text = "Greska kod spremanja: $($_.Exception.Message)"
                $err.Visibility = "Visible"
                $btnA.IsEnabled = $true; $btnA.Content = "AKTIVIRAJ"
                return
            }
            $script:CurrentLicenseKey = $key
            $okt.Text = "Licenca aktivirana. Pokrecem launcher..."
            $okt.Visibility = "Visible"
            $licWin.Tag = "ok"
            $tmr = New-Object System.Windows.Threading.DispatcherTimer
            $tmr.Interval = [TimeSpan]::FromMilliseconds(700)
            $tmr.Add_Tick({ $tmr.Stop(); try { $licWin.Close() } catch {} }.GetNewClosure())
            $tmr.Start()
        }) | Out-Null
    })
    $licWin.ShowDialog() | Out-Null
    return $licWin.Tag
}

function Ensure-LicenseValid {
    $hwid = Get-Hwid
    $cache = Get-LicenseCache
    # API not configured -> system disabled, allow
    if (-not (Get-LicenseApiConfig)) {
        $script:LicenseSystemDisabled = $true
        return $true
    }
    $key = if ($cache) { $cache.key } else { $null }
    if ($key) {
        $r = Test-License -key $key -hwid $hwid
        if ($r.ok) {
            $newCache = @{
                key = $key
                keyHash = (Get-SHA256 $key)
                hwid = $hwid
                expiresAt = $r.entry.expiresAt
                discordId = [string]$r.entry.discordId
                permanent = [bool]$r.entry.permanent
                lastCheck = (Get-Date).ToUniversalTime().ToString("o")
            }
            Save-LicenseCache $newCache | Out-Null
            $script:CurrentLicenseKey = $key
            return $true
        }
        # Network error -> grace period
        if ($r.status -eq 'network' -or $r.status -eq 'config') {
            try {
                $last = [datetime]::Parse($cache.lastCheck).ToUniversalTime()
                $hours = ((Get-Date).ToUniversalTime() - $last).TotalHours
                if ($hours -le $script:LicenseGraceHours) {
                    try {
                        if ($cache.permanent -eq $true) { $script:CurrentLicenseKey = $key; return $true }
                        $exp = [datetime]::Parse($cache.expiresAt).ToUniversalTime()
                        if ((Get-Date).ToUniversalTime() -le $exp) { $script:CurrentLicenseKey = $key; return $true }
                    } catch { $script:CurrentLicenseKey = $key; return $true }
                }
            } catch {}
            $res = Show-LicenseWindow -errorMsg "Server nedostupan. Treba ti internet barem jednom u $($script:LicenseGraceHours)h."
            return ($res -eq "ok")
        }
        # Validation failure (expired, revoked, hwid_mismatch, unknown) -> require re-entry
        $res = Show-LicenseWindow -errorMsg $r.reason
        return ($res -eq "ok")
    }
    # No cache -> prompt
    $res = Show-LicenseWindow
    return ($res -eq "ok")
}

# Licenca + mrezni preload (splash jos vidljiv - bez praznog ekrana prije glavnog prozora)
Set-SplashStep "Provjera licence..." 45
if (-not (Ensure-LicenseValid)) {
    Close-StartupSplash
    [System.Windows.MessageBox]::Show("Licenca nije aktivirana. Launcher se gasi.","Slavonska Ravnica","OK","Warning") | Out-Null
    return
}

Set-SplashStep "Sinkronizacija servera..." 58
try { $script:PreloadedServerStatus = Get-ServerStatus } catch {}

Set-SplashStep "Provjera modova..." 74
try { $script:PreloadedModList = Get-ServerModList } catch {}

Set-SplashStep "Ucitavam opcije igre..." 86
try { $script:PreloadedGameSettings = Read-GameSettings } catch {}
Invoke-SplashPump
Set-SplashStep "Pokrecem..." 100
Close-StartupSplash

# ============================================================
# AUTO-UPDATE PROMPT (provjera u pozadini nakon prikaza prozora)
# ============================================================
$window.Add_Loaded({
    try {
        if (Check-ForUpdate) {
            $btnUpdateNotify.Content = "Nova verzija v$($script:LatestVersion.version)!"
            $btnUpdateNotify.Visibility = "Visible"
            $txtUpdateInfo.Text = "v$($script:LatestVersion.version) dostupna!"
            $updateBanner.Visibility = "Visible"
            Write-Log "NOVA VERZIJA dostupna: v$($script:LatestVersion.version)"
            $r = Show-SRConfirm "Dostupna je nova verzija launchera: v$($script:LatestVersion.version)`n`nTrenutna: v$($script:AppVersion)`n`nSkinuti i instalirati sada?" "Update dostupan"
            if ($r -eq 'Yes') { Download-Update }
        }
    } catch { Write-Log "Auto-update prompt greska: $($_.Exception.Message)" }
})

# ============================================================
# MOD CHANGES SINCE LAST LAUNCH (server-authoritative)
# ============================================================
try {
    $sinceIso = if ($script:Config.lastLaunchAt) { [string]$script:Config.lastLaunchAt } else { $null }
    $window.Add_Loaded({
        try {
            $changes = Get-ModChangesSinceFromBot -SinceIso $sinceIso
            if ($changes -and $changes.Count -gt 0) {
                $added   = @($changes | Where-Object { $_.type -eq 'added' }).Count
                $updated = @($changes | Where-Object { $_.type -eq 'updated' }).Count
                $removed = @($changes | Where-Object { $_.type -eq 'removed' }).Count
                $parts = @()
                if ($added)   { $parts += "+$added novih" }
                if ($updated) { $parts += "$updated azurirano" }
                if ($removed) { $parts += "-$removed uklonjeno" }
                if ($parts.Count -gt 0) {
                    Show-Toast -Message ("Promjene modova: " + ($parts -join ', ')) -Kind 'info'
                    Write-Log ("Mod promjene od zadnjeg pokretanja: " + ($parts -join ', '))
                }
            }
        } catch { Write-Log "Greska kod dohvata mod promjena: $($_.Exception.Message)" }
        try {
            $script:Config | Add-Member -NotePropertyName lastLaunchAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
            Save-Config
        } catch {}
    })
} catch {}

$window.ShowDialog() | Out-Null
