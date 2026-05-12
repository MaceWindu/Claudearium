# Login.ps1 — spawn the four `login` subverbs in separate wt tabs so
# the tester only needs to glance at each and confirm an auth prompt
# rendered. Runs against the ephemeral test distro; the four login
# tools are installed as part of setup so each tab has something to
# launch.
[CmdletBinding()]
param([switch]$NonInteractive)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$claudearium = Join-Path $repoRoot 'claudearium.ps1'

Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')          -Force
Import-Module (Join-Path $repoRoot 'tests\lib\ManualTest.psm1') -Force
Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force

$distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
if (-not (Test-DistroExists -Name $distro)) {
    return [pscustomobject]@{
        Name = 'manual/Login'; Passed = $false; Skipped = $true
        Notes = "test distro '$distro' is not registered (Invoke-TestRun should have provisioned it)"
    }
}

$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if (-not $wt) {
    return [pscustomobject]@{
        Name = 'manual/Login'; Passed = $false; Skipped = $true
        Notes = 'wt.exe not on PATH; install Windows Terminal to run this test'
    }
}

# Subverb -> tool-catalog name. All four tools are installed up-front
# so each subverb has something to launch.
$loginPairs  = @(
    @{ Subverb='claude'; Tool='claudeCode' }
    @{ Subverb='gh';     Tool='gh' }
    @{ Subverb='glab';   Tool='glab' }
    @{ Subverb='acli';   Tool='acli' }
)
$loginCmds   = @($loginPairs | ForEach-Object { $_.Subverb })
$profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'manual-login'

return Invoke-ManualTest `
    -Name 'login subverbs each reach their auth flow' `
    -Instructions @"
This test will (against the ephemeral test distro '$distro'):
  - install claudeCode + gh + glab + acli (slow first time, a few minutes)
  - open one wt tab per subverb running '.\claudearium.ps1 login <verb>'
  - clean up after you answer

Expected: each tab shows an interactive auth prompt (OAuth URL +
code for claude; gh/glab/acli's own auth selectors). Ctrl+C out of
each after seeing the prompt — no need to complete OAuth.

The tabs will stay open until you close them.
"@ `
    -Setup {
        foreach ($p in $loginPairs) {
            Write-Host ("  Installing '{0}' in '$distro'..." -f $p.Tool) -ForegroundColor DarkGray
            Invoke-Claudearium -DistroName $distro -ProfilePath $profilePath -Args @{
                Verb='tools'; SubVerb='install'; Arg=$p.Tool
            } | Out-Null
        }

        # Open each login subverb in its own wt tab in the current window.
        # `pwsh -NoExit` keeps the shell open after Ctrl+C so the tester can
        # see what the verb produced before closing the tab.
        foreach ($verb in $loginCmds) {
            $title = "login-$verb"
            $cmdLine = ". '$claudearium' -Name '$distro' -ProfilePath '$profilePath' login $verb"
            $wtArgs = @('-w', '0', 'new-tab', '--title', $title, 'pwsh', '-NoExit', '-Command', $cmdLine)
            Start-Process -FilePath 'wt.exe' -ArgumentList $wtArgs | Out-Null
            Start-Sleep -Milliseconds 350   # avoid wt argv races
        }
        Write-Host ("  Opened {0} wt tab(s) (one per login subverb)." -f $loginCmds.Count) -ForegroundColor DarkGray
        Write-Host "  Glance at each to confirm an auth prompt rendered." -ForegroundColor DarkGray
    } `
    -Question ("Did all {0} login subverb tab(s) show their respective auth prompts?" -f $loginCmds.Count) `
    -Cleanup {
        Remove-Item -LiteralPath $profilePath -ErrorAction SilentlyContinue
        Write-Host ("  Cleanup: close the {0} wt tab(s) the test opened." -f $loginCmds.Count) -ForegroundColor DarkGray
    } `
    -NonInteractive:$NonInteractive
