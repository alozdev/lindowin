@echo off
rem lindowin: double-click to install headless Linux Docker for Windows.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
