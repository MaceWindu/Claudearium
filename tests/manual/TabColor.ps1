# TabColor.ps1 — manual verification that wt picks up the project-
# configured tab color when open-claudearium.ps1 launches a session.
# No automated setup: the tester drives `claudearium.ps1 project add`
# / `session new` against their real distro.
[CmdletBinding()]
param([switch]$NonInteractive)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $repoRoot 'tests\lib\ManualTest.psm1') -Force

return Invoke-ManualTest `
    -Name 'Windows Terminal tab color' `
    -Instructions @"
Goal: confirm wt tab colour follows the per-project tabColor in the profile.

1. From an existing project, edit its tabColor to a vivid value
   (e.g. red #E81123). Quickest path:
     .\claudearium.ps1 project edit-color <project>
   (or hand-edit the profile under
   %LOCALAPPDATA%\claudearium\claudearium.profile.json).
2. Create a new session for that project (or use an existing one):
     .\claudearium.ps1 session new probe -Project <project> -Branch <existing>
3. Open it:
     .\open-claudearium.ps1
   pick the 'probe' session.
4. Observe the wt window. The new tab's color strip should match the
   color you set in step 1.
"@ `
    -Question 'Does the wt tab use the project tabColor?' `
    -NonInteractive:$NonInteractive
