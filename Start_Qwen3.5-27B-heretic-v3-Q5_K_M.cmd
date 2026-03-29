@echo off
setlocal

call "%~dp0Start.cmd" ^
  -BypassMenu ^
  -Background ^
  -NoPause ^
  -OpenPath / ^
  -GpuLayers auto ^
  -AutoTune ^
  -ModelPath "E:\LLM Model\Qwen3.5-27B-heretic-v3-Q5_K_M.gguf" ^
  --temp 0.7 ^
  --top-k 20 ^
  --top-p 0.8 ^
  --min-p 0 ^
  --presence-penalty 1.5 ^
  --seed 42

exit /b %ERRORLEVEL%
