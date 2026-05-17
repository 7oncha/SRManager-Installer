@echo off
cd /d "%~dp0"
title SR Manager - test pokretanje
echo.
echo === SR Manager TEST (vidljive greske) ===
echo Folder: %~dp0
echo.

if not exist "%~dp0SlavonskaRavnica.ps1" (
    echo GRESKA: SlavonskaRavnica.ps1 nije u ovom folderu.
    echo Raspakiraj CIJELI SR_Manager.zip.
    pause
    exit /b 1
)

echo Pokrecem PowerShell (-STA, bez skrivanja prozora)...
echo Ako se pojavi crveni tekst - to je uzrok problema.
echo.
set SR_MANAGER_TEST=1
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0SlavonskaRavnica.ps1"
set ERR=%ERRORLEVEL%
echo.
echo --- Kraj (exit code %ERR%) ---
if not "%ERR%"=="0" echo Launcher je zavrsio s greskom.
pause
exit /b %ERR%
