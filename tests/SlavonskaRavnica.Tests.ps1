#Requires -Modules Pester
# Unit testovi za SlavonskaRavnica.ps1 — ciste logicke funkcije (bez WPF/Win32).
# Pokretanje: pwsh -NoProfile -Command "Invoke-Pester ./tests -Output Detailed"

BeforeAll {
    . "$PSScriptRoot/Import-TestFunctions.ps1"
}

# ============================================================
# Get-SHA256
# ============================================================
Describe 'Get-SHA256' {
    It 'vraca tocan SHA-256 hash za poznati string' {
        # echo -n "hello" | sha256sum -> 2cf24dba...
        Get-SHA256 'hello' | Should -Be '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
    }
    It 'vraca razlicite hashove za razlicite inpute' {
        $a = Get-SHA256 'abc'
        $b = Get-SHA256 'def'
        $a | Should -Not -Be $b
    }
    It 'vraca prazan-string hash za prazan input' {
        $h = Get-SHA256 ''
        # SHA-256 od praznog stringa je poznat
        $h | Should -Be 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    }
    It 'vraca lowercase hex bez crtica' {
        $h = Get-SHA256 'test'
        $h | Should -Match '^[a-f0-9]{64}$'
    }
}

# ============================================================
# Get-FileSha256
# ============================================================
Describe 'Get-FileSha256' {
    It 'vraca tocan hash za datoteku' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "test-sha256-$(Get-Random).txt"
        try {
            [System.IO.File]::WriteAllBytes($tmp, [System.Text.Encoding]::UTF8.GetBytes('hello'))
            $hash = Get-FileSha256 -Path $tmp
            $hash | Should -Be '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    It 'vraca prazan string za nepostojecu datoteku' {
        Get-FileSha256 -Path '/nonexistent/file.bin' | Should -Be ''
    }
}

# ============================================================
# Normalize-LauncherVersion
# ============================================================
Describe 'Normalize-LauncherVersion' {
    It 'uklanja v prefiks' {
        Normalize-LauncherVersion 'v1.2.3' | Should -Be '1.2.3'
    }
    It 'trimma whitespace' {
        Normalize-LauncherVersion '  v2.0.0  ' | Should -Be '2.0.0'
    }
    It 'vraca prazan string za null/prazan' {
        Normalize-LauncherVersion '' | Should -Be ''
        Normalize-LauncherVersion $null | Should -Be ''
    }
    It 'ostavlja verziju bez v prefiksa nepromijenjenu' {
        Normalize-LauncherVersion '3.1.0' | Should -Be '3.1.0'
    }
}

# ============================================================
# Test-PlaceholderGameVersion
# ============================================================
Describe 'Test-PlaceholderGameVersion' {
    It 'vraca true za prazan/null' {
        Test-PlaceholderGameVersion '' | Should -Be $true
        Test-PlaceholderGameVersion $null | Should -Be $true
    }
    It 'vraca true za 0.0.0.0' {
        Test-PlaceholderGameVersion '0.0.0.0' | Should -Be $true
    }
    It 'vraca true za Windows PE placeholder 10.x.x.x' {
        Test-PlaceholderGameVersion '10.0.0.0' | Should -Be $true
        Test-PlaceholderGameVersion '10.0.26100.1' | Should -Be $true
    }
    It 'vraca false za pravu verziju igre' {
        Test-PlaceholderGameVersion '1.5.0.0' | Should -Be $false
        Test-PlaceholderGameVersion '1.9.1.0' | Should -Be $false
    }
}

# ============================================================
# Get-VersionFromXmlText
# ============================================================
Describe 'Get-VersionFromXmlText' {
    It 'parsira version number atribut' {
        $xml = '<game><version number="1.5.0.0" /></game>'
        Get-VersionFromXmlText $xml | Should -Be '1.5.0.0'
    }
    It 'parsira version element s tekstualnim sadrzajem' {
        $xml = '<mod><version>2.1.0</version></mod>'
        Get-VersionFromXmlText $xml | Should -Be '2.1.0'
    }
    It 'parsira version value atribut' {
        $xml = '<root><version value="3.0" /></root>'
        Get-VersionFromXmlText $xml | Should -Be '3.0'
    }
    It 'parsira gameVersion element' {
        $xml = '<settings><gameVersion>1.9.1.0</gameVersion></settings>'
        Get-VersionFromXmlText $xml | Should -Be '1.9.1.0'
    }
    It 'vraca prazan string za prazan input' {
        Get-VersionFromXmlText '' | Should -Be ''
        Get-VersionFromXmlText $null | Should -Be ''
    }
    It 'vraca prazan string ako nema version taga' {
        Get-VersionFromXmlText '<root><name>test</name></root>' | Should -Be ''
    }
}

# ============================================================
# Get-NormalizedModZipName
# ============================================================
Describe 'Get-NormalizedModZipName' {
    It 'dodaje .zip sufiks ako nedostaje' {
        Get-NormalizedModZipName 'FS25_MyMod' | Should -Be 'fs25_mymod.zip'
    }
    It 'ne duplicira .zip' {
        Get-NormalizedModZipName 'FS25_MyMod.zip' | Should -Be 'fs25_mymod.zip'
    }
    It 'vraca lowercase' {
        Get-NormalizedModZipName 'FS25_BigMap.zip' | Should -Be 'fs25_bigmap.zip'
    }
    It 'trimma whitespace' {
        Get-NormalizedModZipName '  FS25_Test  ' | Should -Be 'fs25_test.zip'
    }
    It 'vraca prazan string za prazan input' {
        Get-NormalizedModZipName '' | Should -Be ''
        Get-NormalizedModZipName $null | Should -Be ''
    }
}

# ============================================================
# Get-CanonicalModKey
# ============================================================
Describe 'Get-CanonicalModKey' {
    It 'uklanja FS25_ prefiks' {
        Get-CanonicalModKey 'FS25_CoolMod.zip' | Should -Be 'coolmod'
    }
    It 'uklanja verzijski sufiks' {
        Get-CanonicalModKey 'FS25_MyMod_v1.0.0.9.zip' | Should -Be 'mymod'
    }
    It 'uklanja beta/alpha sufikse' {
        Get-CanonicalModKey 'FS25_TestMod_beta.zip' | Should -Be 'testmod'
    }
    It 'normalizira razmake i crtice' {
        Get-CanonicalModKey 'fs25-cool-mod.zip' | Should -Be 'coolmod'
    }
    It 'radi bez .zip ekstenzije' {
        Get-CanonicalModKey 'FS25_BigMap' | Should -Be 'bigmap'
    }
    It 'vraca prazan string za prazan input' {
        Get-CanonicalModKey '' | Should -Be ''
        Get-CanonicalModKey $null | Should -Be ''
    }
    It 'uklanja specijalne znakove osim alfanumerickih' {
        Get-CanonicalModKey 'FS25_My Mod (v2).zip' | Should -Be 'mymodv2'
    }
}

# ============================================================
# Build-LocalModIndex i Find-LocalModEntry
# ============================================================
Describe 'Build-LocalModIndex' {
    It 'gradi indeks po normaliziranom i kanonickom kljucu' {
        $mods = @(
            [PSCustomObject]@{ Name = 'FS25_CoolMod.zip'; BaseName = 'FS25_CoolMod' },
            [PSCustomObject]@{ Name = 'FS25_BigMap_v2.0.zip'; BaseName = 'FS25_BigMap_v2.0' }
        )
        $index = Build-LocalModIndex $mods
        $index.ByNorm | Should -Not -BeNullOrEmpty
        $index.ByCanon | Should -Not -BeNullOrEmpty
        $index.ByNorm['fs25_coolmod.zip'].Name | Should -Be 'FS25_CoolMod.zip'
    }
}

Describe 'Find-LocalModEntry' {
    BeforeAll {
        $script:TestMods = @(
            [PSCustomObject]@{ Name = 'FS25_CoolMod.zip'; BaseName = 'FS25_CoolMod' },
            [PSCustomObject]@{ Name = 'FS25_BigMap_v2.0.zip'; BaseName = 'FS25_BigMap_v2.0' }
        )
        $script:TestIndex = Build-LocalModIndex $script:TestMods
    }

    It 'pronalazi mod po tocnom imenu' {
        $entry = Find-LocalModEntry -LocalIndex $script:TestIndex -ServerName 'FS25_CoolMod.zip'
        $entry | Should -Not -BeNullOrEmpty
        $entry.Name | Should -Be 'FS25_CoolMod.zip'
    }
    It 'pronalazi mod po kanonickom kljucu (razlicita verzija)' {
        $entry = Find-LocalModEntry -LocalIndex $script:TestIndex -ServerName 'FS25_BigMap_v3.0.zip'
        $entry | Should -Not -BeNullOrEmpty
        $entry.Name | Should -Be 'FS25_BigMap_v2.0.zip'
    }
    It 'vraca null za nepostojeci mod' {
        $entry = Find-LocalModEntry -LocalIndex $script:TestIndex -ServerName 'FS25_NotHere.zip'
        $entry | Should -BeNullOrEmpty
    }
    It 'vraca null za prazan index' {
        Find-LocalModEntry -LocalIndex $null -ServerName 'FS25_Test.zip' | Should -BeNullOrEmpty
    }
}

# ============================================================
# Resolve-ServerModEntry
# ============================================================
Describe 'Resolve-ServerModEntry' {
    BeforeAll {
        $script:ServerMods = @(
            [PSCustomObject]@{ Name = 'FS25_Tractor.zip'; Url = 'http://srv/mods/FS25_Tractor.zip' },
            [PSCustomObject]@{ Name = 'FS25_BigPlow_v1.0.zip'; Url = 'http://srv/mods/FS25_BigPlow_v1.0.zip' }
        )
    }
    It 'pronalazi po tocnom imenu' {
        $r = Resolve-ServerModEntry -ServerMods $script:ServerMods -DisplayOrZipName 'FS25_Tractor.zip'
        $r | Should -Not -BeNullOrEmpty
        $r.Url | Should -Be 'http://srv/mods/FS25_Tractor.zip'
    }
    It 'pronalazi po imenu bez .zip' {
        $r = Resolve-ServerModEntry -ServerMods $script:ServerMods -DisplayOrZipName 'FS25_Tractor'
        $r | Should -Not -BeNullOrEmpty
    }
    It 'pronalazi po kanonickom kljucu' {
        $r = Resolve-ServerModEntry -ServerMods $script:ServerMods -DisplayOrZipName 'FS25_BigPlow_v2.0.zip'
        $r | Should -Not -BeNullOrEmpty
        $r.Name | Should -Be 'FS25_BigPlow_v1.0.zip'
    }
    It 'vraca null za nepostojeci mod' {
        $r = Resolve-ServerModEntry -ServerMods $script:ServerMods -DisplayOrZipName 'FS25_Missing.zip'
        $r | Should -BeNullOrEmpty
    }
    It 'vraca null za prazan input' {
        Resolve-ServerModEntry -ServerMods @() -DisplayOrZipName '' | Should -BeNullOrEmpty
        Resolve-ServerModEntry -ServerMods $null -DisplayOrZipName 'test' | Should -BeNullOrEmpty
    }
}

# ============================================================
# Normalize-ModTypeLabel
# ============================================================
Describe 'Normalize-ModTypeLabel' {
    It 'mapira poznate tipove' {
        Normalize-ModTypeLabel 'map' | Should -Be 'Map'
        Normalize-ModTypeLabel 'maps' | Should -Be 'Map'
        Normalize-ModTypeLabel 'vehicle' | Should -Be 'Vehicle'
        Normalize-ModTypeLabel 'vehicles' | Should -Be 'Vehicle'
        Normalize-ModTypeLabel 'tractor' | Should -Be 'Vehicle'
        Normalize-ModTypeLabel 'trailer' | Should -Be 'Vehicle'
        Normalize-ModTypeLabel 'placeable' | Should -Be 'Placeable'
        Normalize-ModTypeLabel 'placeables' | Should -Be 'Placeable'
        Normalize-ModTypeLabel 'building' | Should -Be 'Placeable'
        Normalize-ModTypeLabel 'production' | Should -Be 'Placeable'
        Normalize-ModTypeLabel 'script' | Should -Be 'Script'
        Normalize-ModTypeLabel 'scripts' | Should -Be 'Script'
        Normalize-ModTypeLabel 'animal' | Should -Be 'Animal'
        Normalize-ModTypeLabel 'animals' | Should -Be 'Animal'
    }
    It 'radi case-insensitive' {
        Normalize-ModTypeLabel 'MAP' | Should -Be 'Map'
        Normalize-ModTypeLabel 'Vehicle' | Should -Be 'Vehicle'
        Normalize-ModTypeLabel 'SCRIPT' | Should -Be 'Script'
    }
    It 'vraca Other za prazan/null' {
        Normalize-ModTypeLabel '' | Should -Be 'Other'
        Normalize-ModTypeLabel $null | Should -Be 'Other'
    }
    It 'capitalizira nepoznate tipove' {
        Normalize-ModTypeLabel 'special' | Should -Be 'Special'
    }
    It 'prepoznaje vehicle substring u proizvoljnom stringu' {
        Normalize-ModTypeLabel 'myVehiclePack' | Should -Be 'Vehicle'
    }
}

# ============================================================
# Get-ModTypeSortOrder
# ============================================================
Describe 'Get-ModTypeSortOrder' {
    It 'Map je prvi (0)' {
        Get-ModTypeSortOrder 'Map' | Should -Be 0
    }
    It 'vraca rastuce vrijednosti za poznate tipove' {
        (Get-ModTypeSortOrder 'Map') | Should -BeLessThan (Get-ModTypeSortOrder 'Vehicle')
        (Get-ModTypeSortOrder 'Vehicle') | Should -BeLessThan (Get-ModTypeSortOrder 'Placeable')
        (Get-ModTypeSortOrder 'Other') | Should -BeLessThan (Get-ModTypeSortOrder 'Unknown')
    }
    It 'nepoznati tip vraca 7' {
        Get-ModTypeSortOrder 'SomethingElse' | Should -Be 7
    }
}

# ============================================================
# Get-ModSyncStatusLabel
# ============================================================
Describe 'Get-ModSyncStatusLabel' {
    It 'mapira poznate statuse na hrvatske labele' {
        Get-ModSyncStatusLabel 'OK' | Should -Be 'Sinkronizirano'
        Get-ModSyncStatusLabel 'FALI' | Should -Be 'Nedostaje'
        Get-ModSyncStatusLabel 'ZASTARIO' | Should -Be 'Azuriraj'
        Get-ModSyncStatusLabel 'Extra' | Should -Be 'Lokalno extra'
        Get-ModSyncStatusLabel 'Lokalno' | Should -Be 'Lokalno'
    }
    It 'vraca Mod za nepoznati status' {
        Get-ModSyncStatusLabel 'NESTO' | Should -Be 'Mod'
        Get-ModSyncStatusLabel '' | Should -Be 'Mod'
    }
}

# ============================================================
# Get-ModTypeFromModDescXml
# ============================================================
Describe 'Get-ModTypeFromModDescXml' {
    It 'prepoznaje mapu iz <map> elementa' {
        $xml = '<modDesc><map id="test" /></modDesc>'
        Get-ModTypeFromModDescXml $xml | Should -Be 'Map'
    }
    It 'prepoznaje vozilo iz <vehicle> elementa' {
        $xml = '<modDesc><vehicle><name>Tractor</name></vehicle></modDesc>'
        Get-ModTypeFromModDescXml $xml | Should -Be 'Vehicle'
    }
    It 'prepoznaje placeable iz <placeable> elementa' {
        $xml = '<modDesc><placeable type="silo" /></modDesc>'
        Get-ModTypeFromModDescXml $xml | Should -Be 'Placeable'
    }
    It 'prepoznaje script iz <script> elementa' {
        $xml = '<modDesc><script filename="main.lua" /></modDesc>'
        Get-ModTypeFromModDescXml $xml | Should -Be 'Script'
    }
    It 'prepoznaje zivotinju iz <animal> elementa' {
        $xml = '<modDesc><animal name="cow" /></modDesc>'
        Get-ModTypeFromModDescXml $xml | Should -Be 'Animal'
    }
    It 'prepoznaje alat iz <handTool> elementa' {
        $xml = '<modDesc><handTool name="wrench" /></modDesc>'
        Get-ModTypeFromModDescXml $xml | Should -Be 'Tool'
    }
    It 'fallback na regex detekciju ako nema strukturiranog elementa' {
        $xml = '<modDesc><otherStuff /><map something="yes" /></modDesc>'
        # ovdje postoji <map> element pa se detektira kao Map putem property pristupa
        Get-ModTypeFromModDescXml $xml | Should -Be 'Map'
    }
    It 'vraca Other za prazan XML' {
        Get-ModTypeFromModDescXml '' | Should -Be 'Other'
        Get-ModTypeFromModDescXml $null | Should -Be 'Other'
    }
    It 'vraca Other za XML bez prepoznatljivih elemenata' {
        $xml = '<modDesc><description>Just a mod</description></modDesc>'
        Get-ModTypeFromModDescXml $xml | Should -Be 'Other'
    }
}

# ============================================================
# Get-ModIconFilenameFromModDescXml
# ============================================================
Describe 'Get-ModIconFilenameFromModDescXml' {
    It 'parsira iconFilename element' {
        $xml = '<modDesc><iconFilename>icon_mymod.dds</iconFilename></modDesc>'
        Get-ModIconFilenameFromModDescXml $xml | Should -Be 'icon_mymod.dds'
    }
    It 'parsira iconFilename atribut' {
        $xml = '<modDesc iconFilename="store/icon.png" />'
        Get-ModIconFilenameFromModDescXml $xml | Should -Be 'store/icon.png'
    }
    It 'parsira storeIcon element' {
        $xml = '<modDesc><storeIcon>assets/store_icon.png</storeIcon></modDesc>'
        Get-ModIconFilenameFromModDescXml $xml | Should -Be 'assets/store_icon.png'
    }
    It 'parsira storeIcon atribut' {
        $xml = '<modDesc storeIcon="icon.dds" />'
        Get-ModIconFilenameFromModDescXml $xml | Should -Be 'icon.dds'
    }
    It 'vraca null za prazan/null input' {
        Get-ModIconFilenameFromModDescXml '' | Should -BeNullOrEmpty
        Get-ModIconFilenameFromModDescXml $null | Should -BeNullOrEmpty
    }
    It 'vraca null ako nema icon reference' {
        Get-ModIconFilenameFromModDescXml '<modDesc><title>Test</title></modDesc>' | Should -BeNullOrEmpty
    }
}

# ============================================================
# Get-ModCategoryHrLabel
# ============================================================
Describe 'Get-ModCategoryHrLabel' {
    It 'mapira kljuceve na hrvatske labele' {
        Get-ModCategoryHrLabel 'All' | Should -Be 'Svi modovi'
        Get-ModCategoryHrLabel 'Favourites' | Should -Be 'Favoriti'
        Get-ModCategoryHrLabel 'Vehicle' | Should -Be 'Vozila'
        Get-ModCategoryHrLabel 'Placeable' | Should -Be 'Objekti'
        Get-ModCategoryHrLabel 'Map' | Should -Be 'Mape'
        Get-ModCategoryHrLabel 'Script' | Should -Be 'Skripte'
        Get-ModCategoryHrLabel 'Animal' | Should -Be 'Zivotinje'
    }
    It 'vraca Ostalo za nepoznati kljuc' {
        Get-ModCategoryHrLabel 'Tool' | Should -Be 'Ostalo'
        Get-ModCategoryHrLabel '' | Should -Be 'Ostalo'
    }
}

# ============================================================
# Get-ModFavoriteKey
# ============================================================
Describe 'Get-ModFavoriteKey' {
    It 'koristi ZipName ako postoji' {
        $item = [PSCustomObject]@{ ZipName = 'FS25_MyMod.zip'; Name = 'My Mod' }
        $key = Get-ModFavoriteKey $item
        $key | Should -Be 'mymod'
    }
    It 'fallback na Name ako nema ZipName' {
        $item = [PSCustomObject]@{ Name = 'FS25_TestMod' }
        $key = Get-ModFavoriteKey $item
        $key | Should -Be 'testmod'
    }
    It 'vraca prazan string za null item' {
        Get-ModFavoriteKey $null | Should -Be ''
    }
}

# ============================================================
# Read-TextFileUtf8
# ============================================================
Describe 'Read-TextFileUtf8' {
    It 'cita UTF-8 datoteku bez BOM-a' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "test-utf8-$(Get-Random).txt"
        try {
            [System.IO.File]::WriteAllBytes($tmp, [System.Text.Encoding]::UTF8.GetBytes('Pozdrav svijete'))
            $content = Read-TextFileUtf8 -Path $tmp
            $content | Should -Be 'Pozdrav svijete'
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    It 'uklanja BOM marker' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "test-bom-$(Get-Random).txt"
        try {
            $bom = [byte[]](0xEF, 0xBB, 0xBF)
            $text = [System.Text.Encoding]::UTF8.GetBytes('BOM test')
            $all = $bom + $text
            [System.IO.File]::WriteAllBytes($tmp, $all)
            $content = Read-TextFileUtf8 -Path $tmp
            $content | Should -Be 'BOM test'
            $content[0] | Should -Not -Be ([char]0xFEFF)
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    It 'vraca null za nepostojecu datoteku' {
        Read-TextFileUtf8 -Path '/nonexistent/file.txt' | Should -BeNullOrEmpty
    }
}

# ============================================================
# Format-MpFolderDisplayLabel
# ============================================================
Describe 'Format-MpFolderDisplayLabel' {
    It 'kombinira label i path' {
        Format-MpFolderDisplayLabel 'My Folder' 'C:\Mods\SR' | Should -Be 'My Folder - C:\Mods\SR'
    }
    It 'skracuje dugacak path na 72 znaka' {
        $longPath = 'C:\' + ('A' * 100)
        $result = Format-MpFolderDisplayLabel 'Folder' $longPath
        $result | Should -Match '\.\.\.'
        # "Folder - " (10) + "..." (3) + 69 = 82
        $result.Length | Should -BeLessOrEqual 82
    }
    It 'vraca samo label ako nema patha' {
        Format-MpFolderDisplayLabel 'Just Label' '' | Should -Be 'Just Label'
        Format-MpFolderDisplayLabel 'Just Label' $null | Should -Be 'Just Label'
    }
    It 'koristi Folder kao default label' {
        Format-MpFolderDisplayLabel '' 'C:\Test' | Should -Be 'Folder - C:\Test'
        Format-MpFolderDisplayLabel $null 'C:\Test' | Should -Be 'Folder - C:\Test'
    }
}

# ============================================================
# Convert-Rgb565ToArgb
# ============================================================
Describe 'Convert-Rgb565ToArgb' {
    # PS Core ne podrzava [uint32]0xFF... literal (hex overflow), koristimo decimalne vrijednosti
    It 'konvertira crnu boju (0x0000) na ARGB s alpha=255' {
        $argb = Convert-Rgb565ToArgb -C ([uint16]0x0000)
        $argb | Should -BeOfType [uint32]
        $argb | Should -Be 4278190080  # 0xFF000000
    }
    It 'konvertira bijelu boju (0xFFFF) na puni ARGB' {
        $argb = Convert-Rgb565ToArgb -C ([uint16]0xFFFF)
        $argb | Should -Be 4294967295  # 0xFFFFFFFF
    }
    It 'cista crvena (0xF800) ima R=255, G=0, B=0' {
        $argb = Convert-Rgb565ToArgb -C ([uint16]0xF800)
        $argb | Should -Be 4294901760  # 0xFFFF0000
    }
    It 'cista zelena (0x07E0) ima G=255' {
        $argb = Convert-Rgb565ToArgb -C ([uint16]0x07E0)
        $argb | Should -Be 4278255360  # 0xFF00FF00
    }
    It 'cista plava (0x001F) ima B=255' {
        $argb = Convert-Rgb565ToArgb -C ([uint16]0x001F)
        $argb | Should -Be 4278190335  # 0xFF0000FF
    }
    It 'podrzava custom alpha vrijednost' {
        $argb = Convert-Rgb565ToArgb -C ([uint16]0x0000) -A ([byte]128)
        $argb | Should -Be 2147483648  # 0x80000000
    }
}

# ============================================================
# New-ModSyncItem
# ============================================================
Describe 'New-ModSyncItem' {
    It 'kreira objekt sa svim potrebnim propertyima' {
        $item = New-ModSyncItem -Status 'OK' -DisplayName 'Test Mod' -ZipName 'test.zip' `
            -Local '1.0 MB' -Server '1.0 MB' -Size '1.0 MB' -ModType 'Vehicle'
        $item.Status | Should -Be 'OK'
        $item.Name | Should -Be 'Test Mod'
        $item.ZipName | Should -Be 'test.zip'
        $item.Category | Should -Be 'Vehicle'
        $item.ModType | Should -Be 'Vehicle'
        $item.Initial | Should -Be 'T'
        $item.HasThumb | Should -Be $false
        $item.IsFavorite | Should -Be $false
    }
    It 'normalizira ModType' {
        $item = New-ModSyncItem -Status 'OK' -DisplayName 'Test' -ZipName 'test.zip' `
            -Local '' -Server '' -Size '' -ModType 'maps'
        $item.ModType | Should -Be 'Map'
    }
    It 'koristi Other kao default ModType' {
        $item = New-ModSyncItem -Status 'OK' -DisplayName 'Test' -ZipName 'test.zip' `
            -Local '' -Server '' -Size ''
        $item.ModType | Should -Be 'Other'
    }
    It 'postavlja pravilne sort order i initial' {
        $item = New-ModSyncItem -Status 'FALI' -DisplayName 'Alpha Mod' -ZipName 'a.zip' `
            -Local '' -Server '' -Size '' -ModType 'Map'
        $item.Initial | Should -Be 'A'
        $item.ModTypeSort | Should -Be 0
    }
    It 'sadrzi ToolTipText sa statusom' {
        $item = New-ModSyncItem -Status 'ZASTARIO' -DisplayName 'My Mod' -ZipName 'my.zip' `
            -Local '1 MB' -Server '2 MB' -Size '2 MB'
        $item.ToolTipText | Should -Match 'ZASTARIO'
        $item.ToolTipText | Should -Match 'Azuriraj'
    }
    It 'ukljucuje verziju u tooltip ako nije default' {
        $item = New-ModSyncItem -Status 'OK' -DisplayName 'V Mod' -ZipName 'v.zip' `
            -Local '' -Server '' -Size '' -Version '3.2.1'
        $item.ToolTipText | Should -Match '3\.2\.1'
        $item.Version | Should -Be '3.2.1'
    }
}

# ============================================================
# Get-AppVersionFromScript
# ============================================================
Describe 'Get-AppVersionFromScript' {
    It 'izvlaci verziju iz ps1 skripte' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "test-ver-$(Get-Random).ps1"
        try {
            $content = @'
$script:AppVersion = "2.5.0"
# ostali kod
'@
            [System.IO.File]::WriteAllText($tmp, $content)
            $v = Get-AppVersionFromScript -Path $tmp
            $v | Should -Be '2.5.0'
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    It 'vraca null za skriptu bez verzije' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "test-nover-$(Get-Random).ps1"
        try {
            [System.IO.File]::WriteAllText($tmp, '# nema verzije')
            $v = Get-AppVersionFromScript -Path $tmp
            $v | Should -BeNullOrEmpty
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    It 'vraca null za nepostojecu datoteku' {
        Get-AppVersionFromScript -Path '/tmp/nonexistent-script.ps1' | Should -BeNullOrEmpty
    }
}

# ============================================================
# Test-LauncherUpdateAvailable
# ============================================================
Describe 'Test-LauncherUpdateAvailable' {
    BeforeAll {
        # Postavljamo $script:AppVersion za testove
        $script:AppVersion = '1.0.0'
    }
    It 'vraca true ako je remote verzija novija' {
        Test-LauncherUpdateAvailable 'v2.0.0' | Should -Be $true
    }
    It 'vraca false ako je remote verzija starija' {
        Test-LauncherUpdateAvailable 'v0.9.0' | Should -Be $false
    }
    It 'vraca false ako je remote isti kao lokalni' {
        Test-LauncherUpdateAvailable 'v1.0.0' | Should -Be $false
    }
    It 'vraca false ako je remote verzija bez v prefiksa ista' {
        Test-LauncherUpdateAvailable '1.0.0' | Should -Be $false
    }
    It 'vraca false za prazan remote' {
        Test-LauncherUpdateAvailable '' | Should -Be $false
        Test-LauncherUpdateAvailable $null | Should -Be $false
    }
}

# ============================================================
# Get-LauncherZipDownloadUrl
# ============================================================
Describe 'Get-LauncherZipDownloadUrl' {
    BeforeAll {
        $script:UpdateGitHubRepo = '7oncha/SRManager-Installer'
        $script:LauncherZipName = 'SR_Manager.zip'
        # Mock Get-LauncherManifest da ne gadja mrezu
        function Get-LauncherManifest { return $null }
    }
    It 'koristi release asset URL ako postoji' {
        $assets = @(
            [PSCustomObject]@{ name = 'SR_Manager.zip'; browser_download_url = 'https://github.com/test/release/SR_Manager.zip' }
        )
        $url = Get-LauncherZipDownloadUrl -ReleaseAssets $assets -TagName 'v1.0'
        $url | Should -Be 'https://github.com/test/release/SR_Manager.zip'
    }
    It 'konstruira URL iz TagName ako nema asseta' {
        $url = Get-LauncherZipDownloadUrl -ReleaseAssets @() -TagName 'v2.0'
        $url | Should -Be 'https://github.com/7oncha/SRManager-Installer/releases/download/v2.0/SR_Manager.zip'
    }
    It 'dodaje v prefiks na tag ako nedostaje' {
        $url = Get-LauncherZipDownloadUrl -ReleaseAssets @() -TagName '3.0'
        $url | Should -Be 'https://github.com/7oncha/SRManager-Installer/releases/download/v3.0/SR_Manager.zip'
    }
    It 'fallback na latest URL' {
        $url = Get-LauncherZipDownloadUrl -ReleaseAssets $null -TagName $null
        $url | Should -Be 'https://github.com/7oncha/SRManager-Installer/releases/latest/download/SR_Manager.zip'
    }
}
