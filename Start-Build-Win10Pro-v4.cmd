@echo off
setlocal
cd /d "%~dp0"
title Windows 10 Pro ISO Builder v4
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Win10Pro-v4.ps1"
echo.
pause
