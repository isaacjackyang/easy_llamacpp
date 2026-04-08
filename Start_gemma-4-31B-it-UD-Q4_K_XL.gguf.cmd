@echo off
setlocal

call "%~dp0Start.cmd" ^
  -BypassMenu ^
  -Background ^
  -NoPause ^
  -OpenPath / ^
  -GpuLayers auto ^
  -AutoTune ^
  -ModelPath "E:\LLM Model\gemma-4-31B-it-UD-Q4_K_XL.gguf" ^
  --temp 0.7 ^
  --top-k 20 ^
  --top-p 0.8 ^
  --min-p 0 ^
  --presence-penalty 1.5 ^
  --seed 42

exit /b %ERRORLEVEL%
