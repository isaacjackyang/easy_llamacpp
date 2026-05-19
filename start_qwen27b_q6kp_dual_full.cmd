@echo off
setlocal EnableExtensions

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

"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER_PS1%" ^
  -ReturnNonZeroOnError ^
  -WrapperControlsPause ^
  -BypassMenu ^
  -Background ^
  -NoBrowser ^
  -NoPause ^
  -ModelPath "D:\LLM Model\Qwen3.6-27B-Uncensored-HauhauCS-Aggressive-Q6_K_P.gguf" ^
  -VisionMmprojPath "D:\LLM Model\mmproj-Qwen3.6-27B-Uncensored-HauhauCS-Aggressive-f16.gguf" ^
  -GpuLayers all ^
  --split-mode layer ^
  --tensor-split 1,1 ^
  --ctx-size 98304 ^
  --fit-target 128 ^
  --cache-ram 0 ^
  --host 127.0.0.1 ^
  %*
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Start failed with exit code %EXIT_CODE%.
    echo.
    if /I not "%LCPP_NO_PAUSE_ON_ERROR%"=="1" pause
)

exit /b %EXIT_CODE%
