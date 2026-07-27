@echo off
REM Double-click to release Recovery Tracker (runs deploy.ps1 next to this file).
REM Arguments pass through, e.g.:  deploy.bat -DryRun   or   deploy.bat -Doctor
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
echo.
pause
