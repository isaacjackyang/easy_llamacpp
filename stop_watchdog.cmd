@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "WATCHDOG_PS1=%SCRIPT_DIR%PS1\watchdog_control.ps1"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%WATCHDOG_PS1%" (
    echo Cannot find watchdog control script: "%SCRIPT_DIR%PS1\watchdog_control.ps1"
    exit /b 1
)

if not exist "%POWERSHELL_EXE%" (
    set "POWERSHELL_EXE=powershell.exe"
)

"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%WATCHDOG_PS1%" -Stop %*
exit /b %ERRORLEVEL%
