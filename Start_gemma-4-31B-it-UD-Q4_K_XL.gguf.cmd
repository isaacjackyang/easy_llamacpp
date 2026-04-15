@echo off
setlocal

call "%~dp0Start.cmd" ^
  -BypassMenu ^
  -Background ^
  -NoPause ^
  -OpenPath / ^
  -GpuLayers auto ^
  -ModelPath "E:\LLM Model\gemma-4-31B-it-UD-Q4_K_XL.gguf" ^
  --ctx-size 110000 ^
  --fit-target 0,0 ^
  --cache-ram 0 ^
  --parallel 1 ^
  --temp 0.7 ^
  --top-k 20 ^
  --top-p 0.8 ^
  --min-p 0 ^
  --presence-penalty 1.5 ^
  --seed 42

exit /b %ERRORLEVEL%
