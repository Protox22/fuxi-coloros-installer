@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0"
if errorlevel 1 exit /b 1
where py >nul 2>&1
if not errorlevel 1 goto use_py
where python >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Python 3.8 or newer is required only for preparing a changed ROM.
    exit /b 1
)
python "%~dp0prepare-payload.py" %*
exit /b %errorlevel%
:use_py
py -3 "%~dp0prepare-payload.py" %*
exit /b %errorlevel%
