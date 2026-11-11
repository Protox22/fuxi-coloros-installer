@echo off
cd /d "%~dp0"
title Fuxi super resize - Devine Machinery
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0resize.ps1" %*
set ERR=%ERRORLEVEL%
echo.
echo Exit code %ERR%.
pause
exit /b %ERR%
