@echo off
setlocal
cd /d "%~dp0"

set "INSTALL=%~dp0"
set "INSTALL=%INSTALL:~0,-1%"
set "DESKTOP=%USERPROFILE%\Desktop"
set "LNK=%DESKTOP%\SR Manager.lnk"
set "BAT=%INSTALL%\Pokreni SR Manager.bat"
set "ICO=%INSTALL%\sr_logo.ico"

if not exist "%BAT%" (
    echo GRESKA: Pokreni SR Manager.bat nije u: %INSTALL%
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ws=New-Object -ComObject WScript.Shell; $s=$ws.CreateShortcut('%LNK%'); $s.TargetPath='%BAT%'; $s.Arguments=''; $s.WorkingDirectory='%INSTALL%'; $s.Description='Slavonska Ravnica - SR Manager'; if (Test-Path '%ICO%') { $s.IconLocation='%ICO%,0' }; $s.WindowStyle=7; $s.Save()"

if errorlevel 1 (
    echo GRESKA: shortcut nije kreiran.
    pause
    exit /b 1
)

echo Desktop prečac azuriran: %LNK%
echo Cilj: %BAT%
pause
