@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "SYNC_PS1=%SCRIPT_DIR%PS1\Update_OpenClaw_Status.ps1"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%SYNC_PS1%" (
  echo Cannot find OpenClaw sync script: "%SYNC_PS1%"
  exit /b 1
)

if not exist "%POWERSHELL_EXE%" (
  set "POWERSHELL_EXE=powershell.exe"
)

"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SYNC_PS1%" %*
set "EXIT_CODE=%ERRORLEVEL%"

endlocal & exit /b %EXIT_CODE%
