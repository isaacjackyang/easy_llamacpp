@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "STOP_PS1=%SCRIPT_DIR%stop.ps1"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%STOP_PS1%" (
    echo Cannot find stop script: "%STOP_PS1%"
    exit /b 1
)

if not exist "%POWERSHELL_EXE%" (
    set "POWERSHELL_EXE=powershell.exe"
)

"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%STOP_PS1%" %*
exit /b %ERRORLEVEL%
