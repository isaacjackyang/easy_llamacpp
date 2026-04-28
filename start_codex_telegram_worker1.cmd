@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%PS1\Start_Codex_Telegram_Worker1.ps1"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%PS1%" (
  echo Cannot find Codex Telegram worker1 start script: "%PS1%"
  exit /b 1
)

if not exist "%POWERSHELL_EXE%" (
  set "POWERSHELL_EXE=powershell.exe"
)

"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "EXIT_CODE=%ERRORLEVEL%"

endlocal & exit /b %EXIT_CODE%
