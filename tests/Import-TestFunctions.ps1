# Pomocna skripta: izvlaci individual funkcije iz SlavonskaRavnica.ps1 putem AST parsera.
# Na Linuxu ne mozemo dot-sourceati cijelu skriptu (zahtijeva WPF/Win32),
# pa parsiramo AST i evaluiramo samo ciste logicke funkcije.

param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot '..' 'SlavonskaRavnica.ps1')
)

$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath, [ref]$null, [ref]$errors
)
if ($errors.Count -gt 0) {
    throw "Greska pri parsiranju $ScriptPath : $($errors | Out-String)"
}

# Funkcije koje se mogu sigurno izvrsiti na Linux pwsh (nema WPF/Win32 ovisnosti)
$safeFunctions = @(
    'Get-SHA256',
    'Get-FileSha256',
    'Normalize-LauncherVersion',
    'Test-PlaceholderGameVersion',
    'Get-VersionFromXmlText',
    'Get-NormalizedModZipName',
    'Get-CanonicalModKey',
    'Build-LocalModIndex',
    'Find-LocalModEntry',
    'Resolve-ServerModEntry',
    'Normalize-ModTypeLabel',
    'Get-ModTypeSortOrder',
    'Get-ModSyncStatusLabel',
    'Get-ModTypeFromModDescXml',
    'Get-ModIconFilenameFromModDescXml',
    'Get-ModCategoryHrLabel',
    'Get-ModFavoriteKey',
    'Read-TextFileUtf8',
    'Format-MpFolderDisplayLabel',
    'Convert-Rgb565ToArgb',
    'New-ModSyncItem',
    'Get-AppVersionFromScript',
    'Get-LauncherZipDownloadUrl',
    'Test-LauncherUpdateAvailable'
)

$allFunctions = $ast.FindAll(
    { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] },
    $true
)

foreach ($fn in $allFunctions) {
    if ($fn.Name -in $safeFunctions) {
        try {
            Invoke-Expression $fn.Extent.Text
        } catch {
            Write-Warning "Preskocena funkcija $($fn.Name): $($_.Exception.Message)"
        }
    }
}
