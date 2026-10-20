@echo off
rem v219: start the unattended bench/job runner (see infamous-recomp\tools\bench\runner.ps1). Leave the window open.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0infamous-recomp\tools\bench\runner.ps1"
pause
