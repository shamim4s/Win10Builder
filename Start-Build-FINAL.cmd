@echo off
setlocal
cd /d "%~dp0"
title Windows 10 Pro 22H2 ISO Builder
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Win10Pro-v3.ps1"
echo.
pause
