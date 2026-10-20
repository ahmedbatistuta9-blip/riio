@echo off
rem Rebuilds "dist\inFamous Setup.exe" from the current installer config.
cd /d "%~dp0"
"installer\target\release\infamous-installer.exe" package --out "dist\inFamous Setup.exe" > "installer\package.log" 2>&1
echo exit %ERRORLEVEL% >> "installer\package.log"
type "installer\package.log"
