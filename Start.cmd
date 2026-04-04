@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "LAUNCHER_PS1=%SCRIPT_DIR%PS1\Start_LCPP.ps1"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%LAUNCHER_PS1%" (
    set "LAUNCHER_PS1=%SCRIPT_DIR%Start_LCPP.ps1"
)

if not exist "%LAUNCHER_PS1%" (
    echo Cannot find launcher script: "%SCRIPT_DIR%PS1\Start_LCPP.ps1"
    exit /b 1
)

if not exist "%POWERSHELL_EXE%" (
    set "POWERSHELL_EXE=powershell.exe"
)

"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER_PS1%" -ReturnNonZeroOnError -WrapperControlsPause %*
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Start failed with exit code %EXIT_CODE%.
    echo.
    if /I not "%LCPP_NO_PAUSE_ON_ERROR%"=="1" pause
)

exit /b %EXIT_CODE%
