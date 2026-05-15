@echo off
rem Wrapper for open-claudearium.ps1. See claudearium.cmd for why this exists
rem (Mark-of-the-Web on downloaded zip files vs. RemoteSigned execution policy).
where pwsh >nul 2>nul
if errorlevel 1 (
    echo open-claudearium requires PowerShell 7+. Install from https://aka.ms/PowerShell-Release 1>&2
    exit /b 1
)
rem When invoked with no args (interactive launcher), prefer Windows
rem Terminal so the user gets a modern console. With args (scripted use)
rem we run pwsh directly so exit codes and output propagate to the caller.
if not "%~1"=="" goto direct
where wt >nul 2>nul
if errorlevel 1 goto direct
wt -- pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0open-claudearium.ps1"
exit /b 0
:direct
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0open-claudearium.ps1" %*
exit /b %errorlevel%
