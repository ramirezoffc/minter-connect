@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0connect.ps1" -Stop
set "MINTER_CONNECT_EXIT=%ERRORLEVEL%"
if "%MINTER_CONNECT_EXIT%"=="0" exit /b 0
echo.
pause
exit /b %MINTER_CONNECT_EXIT%
