@echo off
chcp 65001 >nul
title Setup Antigravity Auto-Hub
echo ==============================================================================
echo   CAI DAT ANTIGRAVITY AUTO-ROTATION HUB (WINDOWS)
echo ==============================================================================
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1"
set "setupExit=%errorlevel%"
echo.
pause
exit /b %setupExit%
