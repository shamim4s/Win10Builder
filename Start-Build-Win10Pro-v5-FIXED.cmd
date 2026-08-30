@echo off
setlocal
cd /d "%~dp0"

:: Request Administrator elevation
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-Process -FilePath '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%~dp0Build-Win10Pro-v5-FIXED.ps1""' -Verb RunAs"
    exit /b
)

echo Running as Administrator.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Win10Pro-v5-FIXED.ps1"

set "EXITCODE=%ERRORLEVEL%"
echo.
echo Build exited with code %EXITCODE%.
pause
exit /b %EXITCODE%