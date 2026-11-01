@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0"
if errorlevel 1 (
    echo [ERROR] Cannot enter the release directory.
    pause
    exit /b 1
)
where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Windows PowerShell is required.
    pause
    exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\menu.ps1"
set "RC=%ERRORLEVEL%"
exit /b %RC%
