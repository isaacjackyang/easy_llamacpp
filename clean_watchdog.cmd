@echo off
setlocal EnableExtensions

chcp 65001 >nul 2>nul

set "SCRIPT_DIR=%~dp0"
set "CLEANUP_PS1=%SCRIPT_DIR%PS1\clean_legacy_watchdog.ps1"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%POWERSHELL_EXE%" set "POWERSHELL_EXE=powershell.exe"

if not exist "%CLEANUP_PS1%" (
    echo Cannot find cleanup script: "%CLEANUP_PS1%"
    exit /b 1
)

"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CLEANUP_PS1%" %*
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Watchdog cleanup failed with exit code %EXIT_CODE%.
)

exit /b %EXIT_CODE%
