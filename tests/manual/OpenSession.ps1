# OpenSession.ps1 — verify that open-claudearium.ps1 actually spawns a
# wt tab that lands in the session's worktree and starts claude. Like
# TabColor.ps1, the test creates a sentinel project + session, runs
# open-claudearium, and asks the tester to confirm. Uses sentinel
# names that don't collide with the TabColor test, so the two can
# run sequentially.
[CmdletBinding()]
param([switch]$NonInteractive)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$claudearium  = Join-Path $repoRoot 'claudearium.ps1'
$openClaude   = Join-Path $repoRoot 'open-claudearium.ps1'

Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')      -Force
Import-Module (Join-Path $repoRoot 'tests\lib\ManualTest.psm1') -Force

$distro      = Get-RealDistroForManualTest
$testProject = 'manualtest-opensession'
$testSession = 'launch-probe'
$remoteUrl   = 'file:///tmp/manualtest-opensession-remote.git'

if (-not (Test-RealDistroReady -DistroName $distro)) {
    return [pscustomobject]@{
        Name = 'manual/OpenSession'; Passed = $false; Skipped = $true
        Notes = "real distro '$distro' is not registered; run 'claudearium.ps1 setup' first"
    }
}

return Invoke-ManualTest `
    -Name 'open-claudearium launches wt + claude' `
    -Instructions @"
This test will:
  - create a sentinel project '$testProject'
  - create a session 'launch-probe' off master
  - run open-claudearium.ps1 to launch a wt tab in that session
  - clean up after you answer

Expected: a new wt tab opens, you land in
  /home/claude/projects/$testProject/sessions/$testSession
  with `claude` starting up (first-run shows OAuth; later runs open
  the REPL).
"@ `
    -Setup {
        $listOut = & $claudearium project list 2>&1 | Out-String
        if ($listOut -match "(?m)^\s*$testProject\b") {
            throw "Project '$testProject' already exists. Remove it manually or rename the sentinel."
        }

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

        & $claudearium project add $testProject `
            -Remote $remoteUrl -DefaultBranch master -NonInteractive | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "project add failed (exit $LASTEXITCODE)" }

        & $claudearium session new $testSession `
            -Project $testProject -Branch master -NonInteractive | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "session new failed (exit $LASTEXITCODE)" }

        Write-Host "  Launching wt tab via open-claudearium..." -ForegroundColor DarkGray
        & $openClaude -Project $testProject -Session $testSession | Out-Host
        Start-Sleep -Milliseconds 1500
    } `
    -Question 'Did a wt tab open in the session worktree with claude starting up?' `
    -Cleanup {
        try { & $claudearium session remove $testSession -Project $testProject -Force -NonInteractive | Out-Host } catch { }
        try { & $claudearium project remove $testProject -Force -NonInteractive | Out-Host } catch { }
        try {
            Invoke-InDistro -Name $distro -User 'claude' `
                -Command 'rm -rf /tmp/manualtest-opensession-remote.git /tmp/manualtest-opensession-seed' `
                -AllowFail -CaptureOutput | Out-Null
        } catch { }
        Write-Host '  Cleanup done. You can close the wt tab the test opened.' -ForegroundColor DarkGray
    } `
    -NonInteractive:$NonInteractive
