@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "INSTALL_PS1=%SCRIPT_DIR%PS1\Install_LCPP.ps1"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%INSTALL_PS1%" (
    set "INSTALL_PS1=%SCRIPT_DIR%Install_LCPP.ps1"
)

if not exist "%INSTALL_PS1%" (
    echo Cannot find install script: "%SCRIPT_DIR%PS1\Install_LCPP.ps1"
    exit /b 1
)

if not exist "%POWERSHELL_EXE%" (
    set "POWERSHELL_EXE=powershell.exe"
)

"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_PS1%" %*
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Install failed with exit code %EXIT_CODE%.
    echo.
    echo If you want to compile llama.cpp locally on Windows, install one of these first:
    echo   1. Visual Studio 2022 Community
    echo   2. Visual Studio 2022 Build Tools
    echo.
    echo Required workload:
    echo   Desktop development with C++
    echo.
    echo Tip: run install_all.cmd from an existing terminal if you want to keep the full log.
    echo.
    if /I not "%LCPP_NO_PAUSE_ON_ERROR%"=="1" pause
)

exit /b %EXIT_CODE%
