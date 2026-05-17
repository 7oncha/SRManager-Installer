@echo off

cd /d "%~dp0"

if not exist "%~dp0SlavonskaRavnica.ps1" (

    echo GRESKA: SlavonskaRavnica.ps1 nije u ovom folderu.

    echo Raspakiraj CIJELI SR_Manager.zip - sve datoteke moraju biti zajedno.

    pause

    exit /b 1

)

powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0SlavonskaRavnica.ps1" 2>> "%~dp0sr_launch_error.log"
if errorlevel 1 (
    echo.
    echo GRESKA: Launcher nije uspio pokrenuti. Provjeri sr_launch_error.log u ovom folderu.
    echo Ako koristis SRManager.exe - to je installer, ne launcher. Koristi ovaj .bat.
    pause
    exit /b 1
)

