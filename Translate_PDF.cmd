@echo off
setlocal EnableExtensions

chcp 65001 >nul 2>nul

set "SCRIPT_DIR=%~dp0"
set "TRANSLATOR_PS1=%SCRIPT_DIR%PS1\Translate_PDF.ps1"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%TRANSLATOR_PS1%" (
    echo Cannot find translator UI: "%TRANSLATOR_PS1%"
    exit /b 1
)

if not exist "%POWERSHELL_EXE%" set "POWERSHELL_EXE=powershell.exe"

"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%TRANSLATOR_PS1%" %*
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo.
    echo PDF translation exited with code %EXIT_CODE%.
    echo The error details are shown above. Press any key after reviewing them.
    if /I not "%BABELDOC_NO_PAUSE_ON_ERROR%"=="1" pause
)

exit /b %EXIT_CODE%
