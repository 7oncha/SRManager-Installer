@echo off
if exist "%~dp0SRManager.exe" (
    start "" "%~dp0SRManager.exe"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0SlavonskaRavnica.ps1"
)
