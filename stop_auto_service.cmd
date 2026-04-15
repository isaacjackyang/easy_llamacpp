@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "STOP_AUTO_PS1=%SCRIPT_DIR%PS1\Stop_Auto_Service.ps1"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%STOP_AUTO_PS1%" (
    set "STOP_AUTO_PS1=%SCRIPT_DIR%Stop_Auto_Service.ps1"
)

if not exist "%STOP_AUTO_PS1%" (
    echo Cannot find auto-service stop script: "%SCRIPT_DIR%PS1\Stop_Auto_Service.ps1"
    exit /b 1
)

if not exist "%POWERSHELL_EXE%" (
    set "POWERSHELL_EXE=powershell.exe"
)

"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%STOP_AUTO_PS1%" %*
set "EXIT_CODE=%ERRORLEVEL%"

endlocal & exit /b %EXIT_CODE%
