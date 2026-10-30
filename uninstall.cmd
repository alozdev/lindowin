@echo off
rem Double-click to uninstall. Your WSL distro (containers, images, volumes) is kept.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
echo.
pause
