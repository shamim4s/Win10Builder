@echo off
setlocal
cd /d "%~dp0"
title Windows 10 Pro en-US ISO Builder v5
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Win10Pro-v5.ps1"
echo.
echo Exit code: %ERRORLEVEL%
pause
