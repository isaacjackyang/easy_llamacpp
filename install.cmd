@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "INSTALL_PS1=%SCRIPT_DIR%PS1\Install_LCPP_Prebuilt.ps1"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%INSTALL_PS1%" (
    set "INSTALL_PS1=%SCRIPT_DIR%Install_LCPP_Prebuilt.ps1"
)

if not exist "%INSTALL_PS1%" (
    echo Cannot find install script: "%SCRIPT_DIR%PS1\Install_LCPP_Prebuilt.ps1"
    exit /b 1
)

if not exist "%POWERSHELL_EXE%" (
    set "POWERSHELL_EXE=powershell.exe"
)

rem install.cmd is the recommended wrapper: install the latest official Windows CUDA binaries.
"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_PS1%" %*
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Install failed with exit code %EXIT_CODE%.
    echo.
    echo install.cmd uses the latest official Windows CUDA release binaries.
    echo If you need a local source build instead, run install_latest.cmd.
    echo.
    echo Tip: run install.cmd from an existing terminal if you want to keep the full log.
    echo.
    if /I not "%LCPP_NO_PAUSE_ON_ERROR%"=="1" pause
)

exit /b %EXIT_CODE%
