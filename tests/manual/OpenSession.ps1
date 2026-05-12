# OpenSession.ps1 — verify that open-claudearium.ps1 spawns a wt tab
# that lands in the session worktree with `claude` starting up. Runs
# against the ephemeral test distro and installs claudeCode first so
# the launched tab actually has something to run.
[CmdletBinding()]
param([switch]$NonInteractive)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$openClaude   = Join-Path $repoRoot 'open-claudearium.ps1'

Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')          -Force
Import-Module (Join-Path $repoRoot 'tests\lib\ManualTest.psm1') -Force
Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force

$distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
if (-not (Test-DistroExists -Name $distro)) {
    return [pscustomobject]@{
        Name = 'manual/OpenSession'; Passed = $false; Skipped = $true
        Notes = "test distro '$distro' is not registered (Invoke-TestRun should have provisioned it)"
    }
}

$testProject = 'manualtest-opensession'
$testSession = 'launch-probe'
$remoteUrl   = 'file:///tmp/manualtest-opensession-remote.git'
$profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'manual-opensession'

return Invoke-ManualTest `
    -Name 'open-claudearium launches wt + claude' `
    -Instructions @"
This test will (against the ephemeral test distro '$distro'):
  - install claudeCode (so the tab has something to run)
  - create a sentinel project '$testProject'
  - create a session '$testSession' off master
  - run open-claudearium.ps1 to launch a wt tab in that session
  - clean up after you answer

Expected: a new wt tab opens, you land in the session worktree
  with `claude` starting up (first-run shows OAuth; later runs open
  the REPL).
"@ `
    -Setup {
        Write-Host "  Installing claudeCode in '$distro' (may take a few minutes)..." -ForegroundColor DarkGray
        Invoke-Claudearium -DistroName $distro -ProfilePath $profilePath -Args @{
            Verb='tools'; SubVerb='install'; Arg='claudeCode'
        } | Out-Null

        $bashSetup = @'
set -e
rm -rf /tmp/manualtest-opensession-remote.git /tmp/manualtest-opensession-seed
git init --bare /tmp/manualtest-opensession-remote.git >/dev/null
git -C /tmp/manualtest-opensession-remote.git symbolic-ref HEAD refs/heads/master >/dev/null
mkdir /tmp/manualtest-opensession-seed && cd /tmp/manualtest-opensession-seed
git init -q -b master
git config user.email t@t && git config user.name t
echo manualtest > README.md
git add . && git commit -qm init
git push -q /tmp/manualtest-opensession-remote.git master
'@
        Invoke-InDistroScript -Name $distro -User 'claude' -Script $bashSetup | Out-Host

        Invoke-Claudearium -DistroName $distro -ProfilePath $profilePath -Args @{
            Verb='project'; SubVerb='add'; Arg=$testProject
            Remote=$remoteUrl; DefaultBranch='master'
        } | Out-Null

        Invoke-Claudearium -DistroName $distro -ProfilePath $profilePath -Args @{
            Verb='session'; SubVerb='new'; Arg=$testSession
            Project=$testProject; Branch='master'
        } | Out-Null

        Write-Host "  Launching wt tab via open-claudearium..." -ForegroundColor DarkGray
        & $openClaude -Name $distro -ProfilePath $profilePath `
            -Project $testProject -Session $testSession | Out-Host
        Start-Sleep -Milliseconds 1500
    } `
    -Question 'Did a wt tab open in the session worktree with claude starting up?' `
    -Cleanup {
        try {
            Invoke-Claudearium -DistroName $distro -ProfilePath $profilePath -AllowFail -Args @{
                Verb='session'; SubVerb='remove'; Arg=$testSession
                Project=$testProject; Force=$true
            } | Out-Null
        } catch { }
        try {
            Invoke-Claudearium -DistroName $distro -ProfilePath $profilePath -AllowFail -Args @{
                Verb='project'; SubVerb='remove'; Arg=$testProject; Force=$true
            } | Out-Null
        } catch { }
        try {
            Invoke-InDistro -Name $distro -User 'claude' `
                -Command 'rm -rf /tmp/manualtest-opensession-remote.git /tmp/manualtest-opensession-seed' `
                -AllowFail -CaptureOutput | Out-Null
        } catch { }
        Remove-Item -LiteralPath $profilePath -ErrorAction SilentlyContinue
        Write-Host '  Cleanup done. You can close the wt tab the test opened.' -ForegroundColor DarkGray
    } `
    -NonInteractive:$NonInteractive
