@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1
title Slavonska Ravnica - Installer

set "INSTALL_DIR=%LOCALAPPDATA%\SRManager"
set "REPO=7oncha/SRManager-Installer"
set "EXE_NAME=SRManager.exe"
set "ICO_NAME=sr_logo.ico"

echo.
echo  ╔══════════════════════════════════════════════╗
echo  ║     Slavonska Ravnica - SR Manager           ║
echo  ║     Installer v1.0                           ║
echo  ╚══════════════════════════════════════════════╝
echo.
echo  Install folder: %INSTALL_DIR%
echo.

:: Create install directory
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"

:: Get latest release download URL from GitHub API
echo  [1/4] Trazim najnoviju verziju...
set "API_URL=https://api.github.com/repos/%REPO%/releases/latest"

:: Try PowerShell to download
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ProgressPreference='SilentlyContinue'; try { $r = Invoke-RestMethod '%API_URL%' -Headers @{'User-Agent'='SRManager'}; $asset = $r.assets | Where-Object { $_.name -eq '%EXE_NAME%' } | Select-Object -First 1; if($asset) { $asset.browser_download_url | Out-File '%TEMP%\sr_dl_url.txt' -Encoding ascii -NoNewline; Write-Host '  Verzija:' $r.tag_name } else { Write-Host '  GRESKA: .exe nije pronadjen u releaseu'; exit 1 } } catch { Write-Host '  GRESKA:' $_.Exception.Message; exit 1 }"

if %errorlevel% neq 0 (
    echo.
    echo  Greska pri dohvatu verzije. Provjeri internet konekciju.
    pause
    exit /b 1
)

set /p DL_URL=<"%TEMP%\sr_dl_url.txt"
del "%TEMP%\sr_dl_url.txt" 2>nul

:: Download exe
echo  [2/4] Skidam SRManager.exe...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest '%DL_URL%' -OutFile '%INSTALL_DIR%\%EXE_NAME%' -Headers @{'User-Agent'='SRManager'}; Write-Host '  OK' } catch { Write-Host '  GRESKA:' $_.Exception.Message; exit 1 }"

if %errorlevel% neq 0 (
    echo.
    echo  Greska pri skidanju. Provjeri internet.
    pause
    exit /b 1
)

:: Download icon (from repo raw content)
echo  [3/4] Skidam ikonu...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest 'https://raw.githubusercontent.com/%REPO%/main/sr_logo.ico' -OutFile '%INSTALL_DIR%\%ICO_NAME%'; Write-Host '  OK' } catch { Write-Host '  Ikona preskocena' }"

:: Create desktop shortcut
echo  [4/4] Kreiram shortcut...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut([IO.Path]::Combine([Environment]::GetFolderPath('Desktop'), 'SR Manager.lnk')); $sc.TargetPath = '%INSTALL_DIR%\%EXE_NAME%'; $sc.WorkingDirectory = '%INSTALL_DIR%'; $ico = '%INSTALL_DIR%\%ICO_NAME%'; if(Test-Path $ico) { $sc.IconLocation = $ico }; $sc.Description = 'Slavonska Ravnica Launcher'; $sc.Save(); Write-Host '  OK'"

echo.
echo  ╔══════════════════════════════════════════════╗
echo  ║  Instalacija zavrsena!                       ║
echo  ║                                              ║
echo  ║  SR Manager se nalazi na Desktopu.           ║
echo  ║  Buduce azuriranje je automatsko.            ║
echo  ╚══════════════════════════════════════════════╝
echo.
echo  Pokrecem SR Manager...
start "" "%INSTALL_DIR%\%EXE_NAME%"
timeout /t 5
exit
