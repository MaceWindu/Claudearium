@echo off
rem Wrapper for claudearium.ps1.
rem
rem Why this exists: files extracted from a downloaded zip carry a Mark-of-the-
rem Web (Zone.Identifier) alternate data stream, which under the default
rem RemoteSigned execution policy refuses to load unsigned .ps1/.psm1 files.
rem Invoking pwsh with -ExecutionPolicy Bypass ignores the MOTW for this one
rem launch. claudearium.ps1 itself then runs Unblock-File over the install
rem tree so subsequent direct .ps1 invocations work too.
where pwsh >nul 2>nul
if errorlevel 1 (
    echo claudearium requires PowerShell 7+. Install from https://aka.ms/PowerShell-Release 1>&2
    exit /b 1
)
rem When invoked with no args (interactive dashboard), prefer Windows
rem Terminal so the user gets a modern console. With args (scripted use)
rem we run pwsh directly so exit codes and output propagate to the caller.
if not "%~1"=="" goto direct
where wt >nul 2>nul
if errorlevel 1 goto direct
wt -- pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0claudearium.ps1"
exit /b 0
:direct
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0claudearium.ps1" %*
exit /b %errorlevel%
