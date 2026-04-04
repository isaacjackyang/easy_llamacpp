@echo off
setlocal EnableExtensions

rem ============================================================
rem Default target repo: the Git repo that contains this script.
set "SCRIPT_DIR=%~dp0"
for /f "usebackq delims=" %%I in (`git -C "%SCRIPT_DIR%" rev-parse --show-toplevel 2^>nul`) do set "DEFAULT_REPO=%%I"
if not defined DEFAULT_REPO set "DEFAULT_REPO=%SCRIPT_DIR%"

rem Default commit message used only when you do not pass one.
set "DEFAULT_COMMIT_MESSAGE=Update easy_llamacpp"

rem Expected GitHub remote for this repo.
set "EXPECTED_REMOTE_URL=https://github.com/isaacjackyang/easy_llamacpp"
rem ============================================================

if /I "%~1"=="/?" goto :usage
if /I "%~1"=="-h" goto :usage
if /I "%~1"=="--help" goto :usage

set "TARGET_REPO=%DEFAULT_REPO%"
set "COMMIT_MESSAGE="

if not "%~1"=="" (
    if exist "%~f1\.git\" (
        set "TARGET_REPO=%~f1"
        shift /1
    ) else (
        call :looks_like_path "%~1"
        if not errorlevel 1 (
            if not exist "%~f1\" (
                echo Repository path does not exist:
                echo %~f1
                pause
                exit /b 1
            )

            echo This folder is not a Git repository:
            echo %~f1
            pause
            exit /b 1
        )
    )
)

:collect_message
if "%~1"=="" goto args_done
if defined COMMIT_MESSAGE (
    set "COMMIT_MESSAGE=%COMMIT_MESSAGE% %~1"
) else (
    set "COMMIT_MESSAGE=%~1"
)
shift /1
goto collect_message

:args_done
if not defined COMMIT_MESSAGE set "COMMIT_MESSAGE=%DEFAULT_COMMIT_MESSAGE%"

pushd "%TARGET_REPO%" >nul 2>&1 || (
    echo Failed to enter repository folder:
    echo %TARGET_REPO%
    pause
    exit /b 1
)

where git >nul 2>&1
if errorlevel 1 (
    echo git.exe was not found. Install Git first, then try again.
    goto :fail
)

if not exist ".git" (
    echo This folder is not a Git repository:
    echo %CD%
    goto :fail
)

for /f "usebackq delims=" %%I in (`git branch --show-current`) do set "CURRENT_BRANCH=%%I"
if not defined CURRENT_BRANCH (
    echo Could not determine the current branch.
    goto :fail
)

for /f "usebackq delims=" %%I in (`git remote get-url origin 2^>nul`) do set "ORIGIN_URL=%%I"
if not defined ORIGIN_URL (
    echo Remote "origin" is missing. Adding:
    echo %EXPECTED_REMOTE_URL%
    git remote add origin %EXPECTED_REMOTE_URL%
    if errorlevel 1 goto :fail
    set "ORIGIN_URL=%EXPECTED_REMOTE_URL%"
)

echo Repository : %CD%
echo Branch     : %CURRENT_BRANCH%
echo Remote     : %ORIGIN_URL%
echo Message    : %COMMIT_MESSAGE%
if /I not "%ORIGIN_URL%"=="%EXPECTED_REMOTE_URL%" (
    echo Warning    : origin does not match expected repo.
    echo Expected   : %EXPECTED_REMOTE_URL%
)
echo.
echo Staging all changes...
git add -A
if errorlevel 1 goto :fail

git diff --cached --quiet --exit-code
if errorlevel 1 goto :has_changes
echo No staged changes to commit.
popd >nul
exit /b 0

:has_changes
echo.
echo Creating commit...
git commit -m "%COMMIT_MESSAGE%"
if errorlevel 1 goto :fail

echo.
echo Pushing to GitHub...
git push origin %CURRENT_BRANCH%
if errorlevel 1 goto :fail

echo.
echo GitHub update completed successfully.
popd >nul
exit /b 0

:fail
echo.
echo GitHub update failed.
popd >nul
pause
exit /b 1

:looks_like_path
set "CANDIDATE=%~1"
if "%CANDIDATE%"=="." exit /b 0
if "%CANDIDATE%"==".." exit /b 0
echo(%CANDIDATE%| findstr /r "[\\/:]" >nul
if errorlevel 1 exit /b 1
exit /b 0

:usage
echo Usage:
echo   commit_github.cmd [repo_path] [commit message]
echo.
echo Default repo:
echo   %DEFAULT_REPO%
echo.
echo Default remote:
echo   %EXPECTED_REMOTE_URL%
echo.
echo Examples:
echo   commit_github.cmd "Update project files"
echo   commit_github.cmd . "Fix launcher error handling"
echo   commit_github.cmd "F:\Documents\GitHub\easy_llamacpp" "Refresh scripts and docs"
exit /b 0
