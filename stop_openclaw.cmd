@echo off
setlocal

set "OPENCLAW_STOP_CMD=%USERPROFILE%\.openclaw\stop.cmd"

if not exist "%OPENCLAW_STOP_CMD%" (
  echo Cannot find OpenClaw stop command: "%OPENCLAW_STOP_CMD%"
  exit /b 1
)

call "%OPENCLAW_STOP_CMD%" %*
set "EXIT_CODE=%ERRORLEVEL%"

endlocal & exit /b %EXIT_CODE%
