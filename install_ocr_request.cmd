@echo off
setlocal EnableExtensions

chcp 65001 >nul 2>nul

set "BABELDOC_ROOT=%BABELDOC_PROJECT_ROOT%"
if defined BABELDOC_ROOT goto babeldoc_root_ready
for %%I in ("%~dp0..") do set "REPOSITORY_PARENT=%%~fI"
set "BABELDOC_ROOT=%REPOSITORY_PARENT%\BabelDOC"
:babeldoc_root_ready
set "PYTHON_EXE=%BABELDOC_ROOT%\.venv\Scripts\python.exe"

if not exist "%PYTHON_EXE%" (
    echo [ERROR] BabelDOC virtual environment was not found:
    echo         "%PYTHON_EXE%"
    echo Set BABELDOC_PROJECT_ROOT to the BabelDOC project directory and try again.
    exit /b 1
)

if /I "%~1"=="--check" goto verify
if not "%~1"=="" (
    echo Usage: %~nx0 [--check]
    exit /b 2
)

echo Installing the tested OCR dependencies into:
echo   "%PYTHON_EXE%"
echo.

set "UV_EXE="
for /f "delims=" %%I in ('where uv.exe 2^>nul') do if not defined UV_EXE set "UV_EXE=%%I"
if not defined UV_EXE if exist "%USERPROFILE%\Miniconda3\Scripts\uv.exe" set "UV_EXE=%USERPROFILE%\Miniconda3\Scripts\uv.exe"

if defined UV_EXE (
    "%UV_EXE%" pip install --python "%PYTHON_EXE%" ^
        "PyMuPDF==1.27.2.3" ^
        "Pillow==12.2.0" ^
        "opencv-python==4.13.0.92" ^
        "numpy==2.4.6" ^
        "requests==2.34.2" ^
        "rapidocr-onnxruntime==1.4.4"
) else (
    "%PYTHON_EXE%" -m pip install ^
        "PyMuPDF==1.27.2.3" ^
        "Pillow==12.2.0" ^
        "opencv-python==4.13.0.92" ^
        "numpy==2.4.6" ^
        "requests==2.34.2" ^
        "rapidocr-onnxruntime==1.4.4"
)

if errorlevel 1 (
    echo.
    echo [ERROR] OCR dependency installation failed.
    exit /b 1
)

:verify
echo.
echo Verifying OCR dependencies...
set "VERIFY_FAILED=0"
"%PYTHON_EXE%" -c "import fitz; import importlib.metadata as m; print('[OK] PyMuPDF ' + m.version('PyMuPDF'))"
if errorlevel 1 set "VERIFY_FAILED=1"
"%PYTHON_EXE%" -c "import PIL; import importlib.metadata as m; print('[OK] Pillow ' + m.version('Pillow'))"
if errorlevel 1 set "VERIFY_FAILED=1"
"%PYTHON_EXE%" -c "import cv2; import importlib.metadata as m; print('[OK] OpenCV ' + m.version('opencv-python'))"
if errorlevel 1 set "VERIFY_FAILED=1"
"%PYTHON_EXE%" -c "import numpy; import importlib.metadata as m; print('[OK] NumPy ' + m.version('numpy'))"
if errorlevel 1 set "VERIFY_FAILED=1"
"%PYTHON_EXE%" -c "import requests; import importlib.metadata as m; print('[OK] requests ' + m.version('requests'))"
if errorlevel 1 set "VERIFY_FAILED=1"
"%PYTHON_EXE%" -c "import rapidocr_onnxruntime; import importlib.metadata as m; print('[OK] RapidOCR ' + m.version('rapidocr-onnxruntime'))"
if errorlevel 1 set "VERIFY_FAILED=1"

if "%VERIFY_FAILED%"=="1" (
    echo.
    echo [ERROR] One or more OCR dependencies could not be imported.
    exit /b 1
)

echo.
if /I "%~1"=="--check" (
    echo OCR dependency check passed. No packages were changed.
) else (
    echo OCR dependencies are installed and ready.
)
exit /b 0
