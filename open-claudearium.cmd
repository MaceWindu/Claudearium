@echo off
rem Wrapper for open-claudearium.ps1. See claudearium.cmd for why this exists
rem (Mark-of-the-Web on downloaded zip files vs. RemoteSigned execution policy).
where pwsh >nul 2>nul
if errorlevel 1 (
    echo claudearium requires PowerShell 7+. Install from https://aka.ms/PowerShell-Release 1>&2
    exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0open-claudearium.ps1" %*
exit /b %errorlevel%
