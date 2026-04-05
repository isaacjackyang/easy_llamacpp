@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "INSTALL_PS1=%SCRIPT_DIR%PS1\Install_LCPP.ps1"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "INSTALL_FIXED_ARGS=-Source LatestRelease -Backend CUDA"

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

rem install_latest.cmd is an opinionated wrapper: always build the latest CUDA release.
rem For CPU, Vulkan, or custom refs, run PS1\Install_LCPP.ps1 directly.
"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_PS1%" %* %INSTALL_FIXED_ARGS%
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Install failed with exit code %EXIT_CODE%.
    echo.
    echo If you want to compile llama.cpp locally on Windows, install one of these first:
    echo   1. Visual Studio Community with C++
    echo   2. Visual Studio Build Tools with C++
    echo.
    echo Required workload:
    echo   Desktop development with C++
    echo.
    echo Tip: run install_latest.cmd from an existing terminal if you want to keep the full log.
    echo.
    if /I not "%LCPP_NO_PAUSE_ON_ERROR%"=="1" pause
)

exit /b %EXIT_CODE%
