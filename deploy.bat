@echo off
REM Double-click to deploy Recovery Track (runs deploy.ps1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1"
echo.
pause
