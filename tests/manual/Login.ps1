# Login.ps1 — sanity-check that the four `login` subverbs actually
# trigger their respective interactive auth flows.
[CmdletBinding()]
param([switch]$NonInteractive)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $repoRoot 'tests\lib\ManualTest.psm1') -Force

return Invoke-ManualTest `
    -Name 'login flows (claude / gh / glab / acli)' `
    -Instructions @"
Goal: confirm each login subverb runs its tool's interactive auth.
You don't have to complete every login — just verify each one PROMPTS.

1. .\claudearium.ps1 login claude
     -> 'claude' starts; first-run shows the OAuth URL + code.
     -> on subsequent runs, claude opens the REPL (no prompt needed).

2. .\claudearium.ps1 login gh
     -> 'gh auth login' interactive flow (browser/code).

3. .\claudearium.ps1 login glab
     -> 'glab auth login' interactive flow.

4. .\claudearium.ps1 login acli
     -> Atlassian CLI starts; tells you to run `acli auth status`
        or similar.

You can Ctrl+C out of each after seeing the prompt — no need to
finish the OAuth dance for this check.
"@ `
    -Question 'Did all four login subverbs reach their interactive auth flow?' `
    -NonInteractive:$NonInteractive
