@echo off
rem Pushes the curated repository in github\ to https://github.com/whompay/inFAMOUSreborn (branch main),
rem where "Update now" / "Update inFamous" fetch new versions from. Uses your own git login.
rem It only commits what is in github\ -- refresh that folder first the way you build it.
setlocal
cd /d "%~dp0github" || (echo github\ folder not found & goto :fail)
where git >nul 2>&1 || (echo git is not installed: https://git-scm.com/download/win & goto :fail)
git remote get-url origin >nul 2>&1 || git remote add origin https://github.com/whompay/inFAMOUSreborn.git
git add -A || goto :fail
git diff --cached --quiet || git commit -q -m "Update %DATE% %TIME:~0,5%" || goto :fail
git push -u origin main || goto :fail
echo.
echo Pushed. Players get it with "Update now" in Setup or the "Update inFamous" shortcut.
if not defined NOPAUSE pause
exit /b 0
:fail
echo.
echo PUBLISH FAILED
if not defined NOPAUSE pause
exit /b 1
