@echo off
REM Installs the qBittorrent auto-updater: sign-in scheduled task + no more update popup.
REM Run this once. It asks for administrator rights a single time.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0qbt-updater.ps1" -Install %*
pause
