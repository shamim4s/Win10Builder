@echo off
setlocal EnableExtensions

title Windows 10 Pro ISO Builder v6

cd /d "%~dp0"

:: ------------------------------------------------------------
:: Check whether this CMD is already elevated
:: ------------------------------------------------------------
net session >nul 2>&1

if %errorlevel% neq 0 (
    echo.
    echo ================================================================
    echo Requesting Administrator privileges...
    echo ================================================================
    echo.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%ComSpec%' -ArgumentList '/k ""%~f0""' -Verb RunAs"

    exit /b 0
)

echo.
echo ================================================================
echo Windows 10 Pro ISO Builder v6
echo ================================================================
echo.
echo Running as Administrator.
echo.
echo Working directory:
echo %CD%
echo.

:: ------------------------------------------------------------
:: Verify script exists
:: ------------------------------------------------------------
if not exist "%~dp0Build-Win10Pro-v6-FIXED-3.ps1" (
    echo [ERROR] Build-Win10Pro-v6-FIXED-3.ps1 was not found.
    echo.
    pause
    exit /b 1
)

:: ------------------------------------------------------------
:: Run PowerShell and KEEP THIS WINDOW OPEN
:: ------------------------------------------------------------
echo Starting PowerShell builder...
echo.
echo DO NOT CLOSE THIS WINDOW.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Win10Pro-v6-FIXED-3.ps1"

set "EXITCODE=%ERRORLEVEL%"

echo.
echo ================================================================
if "%EXITCODE%"=="0" (
    echo BUILD SCRIPT FINISHED SUCCESSFULLY
) else (
    echo BUILD SCRIPT FAILED
)
echo Exit code: %EXITCODE%
echo ================================================================
echo.

if exist "%~dp0Logs" (
    echo Recent log files:
    dir /b /o-d "%~dp0Logs\Build-v6-*.log" 2>nul
    echo.
)

echo Press any key to close this window...
pause >nul

exit /b %EXITCODE%