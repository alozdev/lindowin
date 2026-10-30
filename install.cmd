@echo off
rem Double-click to install Docker Engine on WSL 2 (no Docker Desktop).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
