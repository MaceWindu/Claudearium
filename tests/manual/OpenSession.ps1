# OpenSession.ps1 — confirm open-claudearium.ps1 actually spawns a
# Windows Terminal tab and lands the user in the session's worktree
# with `claude` ready to run.
[CmdletBinding()]
param([switch]$NonInteractive)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $repoRoot 'tests\lib\ManualTest.psm1') -Force

return Invoke-ManualTest `
    -Name 'open-claudearium launches wt tab' `
    -Instructions @"
Goal: end-to-end check of the open-claudearium.ps1 launcher.

1. Ensure you have at least one session via:
     .\claudearium.ps1 session list
   (create one with `session new` if not).
2. From a separate pwsh window, run:
     .\open-claudearium.ps1
3. Pick a session from the menu.

Expected:
- A new Windows Terminal tab opens.
- The tab is at /home/claude/projects/<proj>/sessions/<name>.
- `claude` starts automatically (first-run will prompt for OAuth;
  on subsequent runs you land in the Claude REPL).
"@ `
    -Question 'Did wt open with the session checked out and claude running?' `
    -NonInteractive:$NonInteractive
