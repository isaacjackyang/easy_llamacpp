@echo off
setlocal EnableExtensions

chcp 65001 >nul 2>nul

set "SCRIPT_DIR=%~dp0"
set "MONITOR_PY=%SCRIPT_DIR%Monitor.py"

if not exist "%MONITOR_PY%" (
    echo Cannot find monitor script: "%SCRIPT_DIR%Monitor.py"
    exit /b 1
)

set "PYTHON_CMD="
where py >nul 2>nul
if not errorlevel 1 (
    set "PYTHON_CMD=py"
    goto run_monitor
)

where python >nul 2>nul
if not errorlevel 1 (
    set "PYTHON_CMD=python"
    goto run_monitor
)

echo Cannot find Python launcher. Install Python or add it to PATH.
exit /b 1

:run_monitor
if /I "%PYTHON_CMD%"=="py" (
    "%PYTHON_CMD%" "%MONITOR_PY%" %*
) else (
    "%PYTHON_CMD%" "%MONITOR_PY%" %*
)
exit /b %ERRORLEVEL%
