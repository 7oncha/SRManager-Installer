; ============================================================
;  SR Manager - NSIS Installer
;  Generira jedan .exe koji instalira SR Manager na korisnikov racunal
;  Kompajliranje: makensis installer.nsi
; ============================================================

!include "MUI2.nsh"
!include "FileFunc.nsh"

; ---- Osnovne postavke ----
Name "SR Manager - Slavonska Ravnica"
OutFile "dist\SRManager_Setup.exe"
InstallDir "$LOCALAPPDATA\SR Manager"
InstallDirRegKey HKCU "Software\SRManager" "InstallDir"
RequestExecutionLevel user
Unicode True

; ---- Verzija (azuriraj za svaki release) ----
!define VERSION "2.4.0.0"
!define PUBLISHER "Slavonska Ravnica"
!define WEBSITE "https://discord.gg/slavonskaravnica"

VIProductVersion "${VERSION}"
VIAddVersionKey "ProductName" "SR Manager"
VIAddVersionKey "CompanyName" "${PUBLISHER}"
VIAddVersionKey "FileDescription" "SR Manager Installer - Slavonska Ravnica FS25"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "${PUBLISHER}"

; ---- Ikona ----
!define MUI_ICON "sr_logo.ico"
!define MUI_UNICON "sr_logo.ico"

; ---- MUI stranice ----
!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "SR Manager - Instalacija"
!define MUI_WELCOMEPAGE_TEXT "Ovaj program ce instalirati SR Manager (Slavonska Ravnica launcher za FS25) na tvoj racunal.$\r$\n$\r$\nPreporucamo zatvoriti sve ostale aplikacije prije nastavka.$\r$\n$\r$\nKlikni Dalje za nastavak."
!define MUI_FINISHPAGE_RUN "wscript.exe"
!define MUI_FINISHPAGE_RUN_PARAMETERS '"$INSTDIR\SR Manager.vbs"'
!define MUI_FINISHPAGE_RUN_TEXT "Pokreni SR Manager"
!define MUI_FINISHPAGE_LINK "Discord: Slavonska Ravnica"
!define MUI_FINISHPAGE_LINK_LOCATION "${WEBSITE}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

; ---- Jezik ----
!insertmacro MUI_LANGUAGE "Croatian"

; ============================================================
;  Instalacija
; ============================================================
Section "Instaliraj" SecInstall
    SetOutPath "$INSTDIR"

    ; Glavne datoteke
    File "SlavonskaRavnica.ps1"
    File "sr_shared_config.json"
    File "sr_logo.ico"
    File "sr_logo.png"

    ; Launcher wrapper datoteke
    File "package\Pokreni SR Manager.bat"
    File "package\SR Manager.vbs"
    File "package\TEST-POKRENI.bat"
    File "package\Fix-Desktop-Shortcut.bat"
    File "package\CITAJME.txt"

    ; SRManager.exe wrapper (opcionalan - /nonfatal za CI build bez njega)
    File /nonfatal "SRManager.exe"

    ; Spremi install dir u registry
    WriteRegStr HKCU "Software\SRManager" "InstallDir" "$INSTDIR"
    WriteRegStr HKCU "Software\SRManager" "Version" "${VERSION}"

    ; Uninstall registry (Programs & Features / Dodaj/Ukloni programe)
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SRManager" \
        "DisplayName" "SR Manager - Slavonska Ravnica"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SRManager" \
        "UninstallString" '"$INSTDIR\Uninstall.exe"'
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SRManager" \
        "DisplayIcon" "$INSTDIR\sr_logo.ico"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SRManager" \
        "Publisher" "${PUBLISHER}"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SRManager" \
        "DisplayVersion" "${VERSION}"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SRManager" \
        "URLInfoAbout" "${WEBSITE}"
    WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SRManager" \
        "NoModify" 1
    WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SRManager" \
        "NoRepair" 1

    ; Izracunaj velicinu instalacije
    ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
    IntFmt $0 "0x%08X" $0
    WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SRManager" \
        "EstimatedSize" $0

    ; Kreiraj uninstaller
    WriteUninstaller "$INSTDIR\Uninstall.exe"

    ; Desktop shortcut (koristi .vbs da sakrije CMD prozor)
    CreateShortcut "$DESKTOP\SR Manager.lnk" "wscript.exe" '"$INSTDIR\SR Manager.vbs"' \
        "$INSTDIR\sr_logo.ico" 0 SW_SHOWNORMAL "" "Slavonska Ravnica - SR Manager"

    ; Start Menu
    CreateDirectory "$SMPROGRAMS\SR Manager"
    CreateShortcut "$SMPROGRAMS\SR Manager\SR Manager.lnk" "wscript.exe" '"$INSTDIR\SR Manager.vbs"' \
        "$INSTDIR\sr_logo.ico" 0 SW_SHOWNORMAL "" "Slavonska Ravnica - SR Manager"
    CreateShortcut "$SMPROGRAMS\SR Manager\Deinstaliraj.lnk" "$INSTDIR\Uninstall.exe" "" \
        "" 0 SW_SHOWNORMAL "" "Deinstaliraj SR Manager"

SectionEnd

; ============================================================
;  Deinstalacija
; ============================================================
Section "Uninstall"

    ; Izbrisi datoteke
    Delete "$INSTDIR\SlavonskaRavnica.ps1"
    Delete "$INSTDIR\sr_shared_config.json"
    Delete "$INSTDIR\sr_logo.ico"
    Delete "$INSTDIR\sr_logo.png"
    Delete "$INSTDIR\Pokreni SR Manager.bat"
    Delete "$INSTDIR\SR Manager.vbs"
    Delete "$INSTDIR\TEST-POKRENI.bat"
    Delete "$INSTDIR\Fix-Desktop-Shortcut.bat"
    Delete "$INSTDIR\CITAJME.txt"
    Delete "$INSTDIR\SRManager.exe"
    Delete "$INSTDIR\sr_launch_error.log"
    Delete "$INSTDIR\Uninstall.exe"

    ; Izbrisi generirane cache direktorije (ako postoje)
    RMDir /r "$INSTDIR\mod_thumbs"

    ; Izbrisi install direktorij (samo ako je prazan)
    RMDir "$INSTDIR"

    ; Izbrisi shortcute
    Delete "$DESKTOP\SR Manager.lnk"
    Delete "$SMPROGRAMS\SR Manager\SR Manager.lnk"
    Delete "$SMPROGRAMS\SR Manager\Deinstaliraj.lnk"
    RMDir "$SMPROGRAMS\SR Manager"

    ; Izbrisi registry
    DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\SRManager"
    DeleteRegKey HKCU "Software\SRManager"

SectionEnd
