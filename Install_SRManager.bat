@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1
title Slavonska Ravnica - Installer

set "DEFAULT_DIR=%LOCALAPPDATA%\SRManager"
set "REPO=7oncha/SRManager-Installer"
set "EXE_NAME=SRManager.exe"
set "ICO_NAME=sr_logo.ico"

echo.
echo  ╔══════════════════════════════════════════════╗
echo  ║     Slavonska Ravnica - SR Manager           ║
echo  ║     Installer v1.0                           ║
echo  ╚══════════════════════════════════════════════╝
echo.

:: ── Ask install location ──
echo  Zadani folder: %DEFAULT_DIR%
echo.
set /p "CUSTOM_DIR=  Unesi folder za instalaciju (ili ENTER za zadani): "

if "%CUSTOM_DIR%"=="" (
    set "INSTALL_DIR=%DEFAULT_DIR%"
) else (
    set "INSTALL_DIR=%CUSTOM_DIR%"
)

:: Remove trailing backslash if present
if "%INSTALL_DIR:~-1%"=="\" set "INSTALL_DIR=%INSTALL_DIR:~0,-1%"

echo.
echo  Instalacija u: %INSTALL_DIR%
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
echo  [2/6] Skidam SRManager.exe...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest '%DL_URL%' -OutFile '%INSTALL_DIR%\%EXE_NAME%' -Headers @{'User-Agent'='SRManager'}; Write-Host '  OK' } catch { Write-Host '  GRESKA:' $_.Exception.Message; exit 1 }"

if %errorlevel% neq 0 (
    echo.
    echo  Greska pri skidanju. Provjeri internet.
    pause
    exit /b 1
)

:: Download launcher script (.ps1) i ostale datoteke s GitHub raw-a
set "RAW_URL=https://raw.githubusercontent.com/%REPO%/master"
echo  [3/6] Skidam launcher skriptu...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest '%RAW_URL%/SlavonskaRavnica.ps1' -OutFile '%INSTALL_DIR%\SlavonskaRavnica.ps1' -Headers @{'User-Agent'='SRManager'}; Write-Host '  OK' } catch { Write-Host '  GRESKA:' $_.Exception.Message; exit 1 }"

echo  [4/6] Skidam pomocne datoteke...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ProgressPreference='SilentlyContinue'; $base='%RAW_URL%'; $dir='%INSTALL_DIR%'; $h=@{'User-Agent'='SRManager'}; foreach($f in @('sr_shared_config.json','SR Manager.bat','SR Manager.vbs')) { try { Invoke-WebRequest \"$base/$f\" -OutFile \"$dir\$f\" -Headers $h } catch {} }; Write-Host '  OK'"

:: Download icon (from repo raw content)
echo  [5/6] Skidam ikonu...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest '%RAW_URL%/sr_logo.ico' -OutFile '%INSTALL_DIR%\%ICO_NAME%'; Invoke-WebRequest '%RAW_URL%/sr_logo.png' -OutFile '%INSTALL_DIR%\sr_logo.png' } catch {}; Write-Host '  OK'"

:: ── Ask about desktop shortcut ──
echo  [6/6] Desktop shortcut
echo.
set /p "MAKE_SHORTCUT=  Zelis li kreirati Desktop ikonu? (D/N): "

if /i "%MAKE_SHORTCUT%"=="D" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
      "$ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut([IO.Path]::Combine([Environment]::GetFolderPath('Desktop'), 'SR Manager.lnk')); $sc.TargetPath = '%INSTALL_DIR%\%EXE_NAME%'; $sc.WorkingDirectory = '%INSTALL_DIR%'; $ico = '%INSTALL_DIR%\%ICO_NAME%'; if(Test-Path $ico) { $sc.IconLocation = $ico }; $sc.Description = 'Slavonska Ravnica Launcher'; $sc.Save(); Write-Host '  Shortcut kreiran!'"
) else (
    echo   Shortcut preskocen.
)

echo.
echo  ╔══════════════════════════════════════════════╗
echo  ║  Instalacija zavrsena!                       ║
echo  ║                                              ║
echo  ║  Lokacija: %INSTALL_DIR%
echo  ║  Buduce azuriranje je automatsko.            ║
echo  ╚══════════════════════════════════════════════╝
echo.

set /p "RUN_NOW=  Zelis li pokrenuti SR Manager? (D/N): "
if /i "%RUN_NOW%"=="D" (
    start "" "%INSTALL_DIR%\%EXE_NAME%"
)
echo.
echo  Gotovo!
timeout /t 3
exit
