@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "LAUNCHER_PS1=%SCRIPT_DIR%Start_LCPP.ps1"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%LAUNCHER_PS1%" (
    echo Cannot find launcher script: "%LAUNCHER_PS1%"
    exit /b 1
)

if not exist "%POWERSHELL_EXE%" (
    set "POWERSHELL_EXE=powershell.exe"
)

"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER_PS1%" %*
exit /b %ERRORLEVEL%
