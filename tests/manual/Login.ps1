# Login.ps1 — automatically spawn the four `login` subverbs in four
# separate wt tabs so the tester only needs to glance at each tab and
# confirm an auth prompt rendered. The user closes the tabs after
# answering; the test doesn't try to inject input or auto-cancel each
# flow.
[CmdletBinding()]
param([switch]$NonInteractive)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$claudearium = Join-Path $repoRoot 'claudearium.ps1'

Import-Module (Join-Path $repoRoot 'tests\lib\ManualTest.psm1') -Force

$distro = Get-RealDistroForManualTest
if (-not (Test-RealDistroReady -DistroName $distro)) {
    return [pscustomobject]@{
        Name = 'manual/Login'; Passed = $false; Skipped = $true
        Notes = "real distro '$distro' is not registered; run 'claudearium.ps1 setup' first"
    }
}

$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if (-not $wt) {
    return [pscustomobject]@{
        Name = 'manual/Login'; Passed = $false; Skipped = $true
        Notes = 'wt.exe not on PATH; install Windows Terminal to run this test'
    }
}

$loginCmds = @('claude','gh','glab','acli')

return Invoke-ManualTest `
    -Name 'login subverbs each reach their auth flow' `
    -Instructions @"
This test will open four wt tabs, one per login subverb:
$(($loginCmds | ForEach-Object { "  - .\claudearium.ps1 login $_" }) -join "`n")

Expected: each tab shows an interactive auth prompt (OAuth URL +
code for claude; gh/glab/acli's own auth selectors). You can Ctrl+C
out of each after seeing the prompt — no need to complete OAuth.

The tabs will stay open until you close them. Cleanup only verifies
the tests didn't leave profile state behind.
"@ `
    -Setup {
        # Open each login subverb in its own wt tab in the current window.
        # `pwsh -NoExit` keeps the shell open after Ctrl+C so the tester can
        # see what the verb produced before closing the tab.
        foreach ($verb in $loginCmds) {
            $title = "login-$verb"
            $cmdLine = ". '$claudearium' login $verb"
            $args = @('-w', '0', 'new-tab', '--title', $title, 'pwsh', '-NoExit', '-Command', $cmdLine)
            Start-Process -FilePath 'wt.exe' -ArgumentList $args | Out-Null
            Start-Sleep -Milliseconds 350   # avoid wt argv races
        }
        Write-Host "  Opened 4 wt tabs (one per login subverb)." -ForegroundColor DarkGray
        Write-Host "  Glance at each to confirm an auth prompt rendered." -ForegroundColor DarkGray
    } `
    -Question 'Did all four login subverb tabs show their respective auth prompts?' `
    -Cleanup {
        Write-Host '  Cleanup: close the four wt tabs the test opened.' -ForegroundColor DarkGray
    } `
    -NonInteractive:$NonInteractive
