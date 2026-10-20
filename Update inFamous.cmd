@echo off
rem Created by infamous-installer: downloads what changed on GitHub and rebuilds what that needs.
cd /d "%~dp0"
"installer\infamous-installer.exe" update
echo.
pause
