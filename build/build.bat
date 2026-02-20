@echo off
REM build/build.bat — Windows build script
REM Downloads python-build-standalone and creates the bundled environment.

setlocal enabledelayedexpansion

set PYTHON_VERSION=3.12
set PBS_RELEASE=20241101
set PBS_TRIPLE=x86_64-pc-windows-msvc

set SCRIPT_DIR=%~dp0
set PROJECT_ROOT=%SCRIPT_DIR%..
set BUNDLE_DIR=%SCRIPT_DIR%bundle
set DOWNLOAD_DIR=%SCRIPT_DIR%.cache

set PBS_FILENAME=cpython-%PYTHON_VERSION%+%PBS_RELEASE%-%PBS_TRIPLE%-install_only_stripped.tar.gz
set PBS_URL=https://github.com/astral-sh/python-build-standalone/releases/download/%PBS_RELEASE%/%PBS_FILENAME%

echo ==> Building for target: windows-x86_64

REM Clean and prepare
if exist "%BUNDLE_DIR%" rmdir /s /q "%BUNDLE_DIR%"
mkdir "%BUNDLE_DIR%"
if not exist "%DOWNLOAD_DIR%" mkdir "%DOWNLOAD_DIR%"

REM Download
if not exist "%DOWNLOAD_DIR%\%PBS_FILENAME%" (
    echo ==> Downloading python-build-standalone...
    curl -L --fail -o "%DOWNLOAD_DIR%\%PBS_FILENAME%" "%PBS_URL%"
)

REM Extract
echo ==> Extracting Python runtime...
mkdir "%BUNDLE_DIR%\python-runtime"
tar -xf "%DOWNLOAD_DIR%\%PBS_FILENAME%" -C "%BUNDLE_DIR%\python-runtime" --strip-components=1

REM Install dependencies
echo ==> Installing Python dependencies...
mkdir "%BUNDLE_DIR%\python-venv\site-packages"

where uv >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo     Using uv for dependency installation
    cd /d "%PROJECT_ROOT%\backend"
    uv pip compile pyproject.toml -o "%TEMP%\requirements.txt"
    cd /d "%PROJECT_ROOT%"
    uv pip install --python "%BUNDLE_DIR%\python-runtime\python.exe" -r "%TEMP%\requirements.txt" --target "%BUNDLE_DIR%\python-venv\site-packages"
) else (
    echo     Using pip for dependency installation
    "%BUNDLE_DIR%\python-runtime\python.exe" -m pip install --target "%BUNDLE_DIR%\python-venv\site-packages" -r "%PROJECT_ROOT%\backend\requirements.txt" --no-cache-dir
)

echo ==> Bundle ready at: %BUNDLE_DIR%
echo Done!
