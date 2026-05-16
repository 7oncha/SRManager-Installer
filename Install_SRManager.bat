@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1
title Slavonska Ravnica - Installer

set "DEFAULT_DIR=%LOCALAPPDATA%\SRManager"
set "BOT_URL=https://server-bot-production-a3a0.up.railway.app"
set "RAW_URL=https://raw.githubusercontent.com/7oncha/SRManager-Installer/master"
set "RELEASE_URL=https://github.com/7oncha/SRManager-Installer/releases/latest/download"

echo.
echo  ========================================================
echo     Slavonska Ravnica - SR Manager
echo     Installer v2.0
echo  ========================================================
echo.

:: Pitaj za lokaciju instalacije
echo  Zadani folder: %DEFAULT_DIR%
echo.
set /p "CUSTOM_DIR=  Unesi folder za instalaciju (ili ENTER za zadani): "

if "%CUSTOM_DIR%"=="" (
    set "INSTALL_DIR=%DEFAULT_DIR%"
) else (
    set "INSTALL_DIR=%CUSTOM_DIR%"
)

if "%INSTALL_DIR:~-1%"=="\" set "INSTALL_DIR=%INSTALL_DIR:~0,-1%"

echo.
echo  Instalacija u: %INSTALL_DIR%
echo.

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"

:: Skidam datoteke koristeci certutil (ugraden u Windows, nema AV problema)
echo  [1/5] Skidam SRManager.exe...
certutil -urlcache -split -f "%RELEASE_URL%/SRManager.exe" "%INSTALL_DIR%\SRManager.exe" >nul 2>&1
if exist "%INSTALL_DIR%\SRManager.exe" (echo    OK) else (echo    GRESKA - provjeri internet & pause & exit /b 1)

echo  [2/5] Skidam launcher skriptu...
certutil -urlcache -split -f "%BOT_URL%/launcher/script" "%INSTALL_DIR%\SlavonskaRavnica.ps1" >nul 2>&1
if not exist "%INSTALL_DIR%\SlavonskaRavnica.ps1" (
    certutil -urlcache -split -f "%RAW_URL%/SlavonskaRavnica.ps1" "%INSTALL_DIR%\SlavonskaRavnica.ps1" >nul 2>&1
)
if exist "%INSTALL_DIR%\SlavonskaRavnica.ps1" (echo    OK) else (echo    GRESKA & pause & exit /b 1)

echo  [3/5] Skidam konfiguraciju...
certutil -urlcache -split -f "%BOT_URL%/launcher/config" "%INSTALL_DIR%\sr_shared_config.json" >nul 2>&1
if not exist "%INSTALL_DIR%\sr_shared_config.json" (
    certutil -urlcache -split -f "%RAW_URL%/sr_shared_config.json" "%INSTALL_DIR%\sr_shared_config.json" >nul 2>&1
)
certutil -urlcache -split -f "%RAW_URL%/SR%%20Manager.bat" "%INSTALL_DIR%\SR Manager.bat" >nul 2>&1
certutil -urlcache -split -f "%RAW_URL%/SR%%20Manager.vbs" "%INSTALL_DIR%\SR Manager.vbs" >nul 2>&1
echo    OK

echo  [4/5] Skidam ikone...
certutil -urlcache -split -f "%RAW_URL%/sr_logo.ico" "%INSTALL_DIR%\sr_logo.ico" >nul 2>&1
certutil -urlcache -split -f "%RAW_URL%/sr_logo.png" "%INSTALL_DIR%\sr_logo.png" >nul 2>&1
echo    OK

echo  [5/5] Kreiram Desktop shortcut...
set "DESKTOP=%USERPROFILE%\Desktop"
set "SHORTCUT=%DESKTOP%\SR Manager.lnk"
:: Kreiraj shortcut koristeci mshta (bez PowerShella)
echo Set ws = CreateObject("WScript.Shell") > "%TEMP%\sr_shortcut.vbs"
echo Set sc = ws.CreateShortcut("%SHORTCUT%") >> "%TEMP%\sr_shortcut.vbs"
echo sc.TargetPath = "%INSTALL_DIR%\SRManager.exe" >> "%TEMP%\sr_shortcut.vbs"
echo sc.WorkingDirectory = "%INSTALL_DIR%" >> "%TEMP%\sr_shortcut.vbs"
echo sc.IconLocation = "%INSTALL_DIR%\sr_logo.ico" >> "%TEMP%\sr_shortcut.vbs"
echo sc.Description = "Slavonska Ravnica Launcher" >> "%TEMP%\sr_shortcut.vbs"
echo sc.Save >> "%TEMP%\sr_shortcut.vbs"
cscript //nologo "%TEMP%\sr_shortcut.vbs" >nul 2>&1
del "%TEMP%\sr_shortcut.vbs" >nul 2>&1
echo    Shortcut kreiran!

echo.
echo  ========================================================
echo     Instalacija zavrsena!
echo.
echo     Lokacija: %INSTALL_DIR%
echo     Pokreni SR Manager sa Desktopa.
echo  ========================================================
echo.

set /p "RUN_NOW=  Zelis li pokrenuti SR Manager? (D/N): "
if /i "%RUN_NOW%"=="D" (
    start "" "%INSTALL_DIR%\SRManager.exe"
)
echo.
echo  Gotovo!
timeout /t 3
exit
