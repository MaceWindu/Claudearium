# TabColor.ps1 — verify that open-claudearium.ps1 propagates the
# per-project tabColor from the profile into the wt tab. Runs against
# the ephemeral test distro (NeedsDistro=$true) so it never touches the
# user's real profile or state.
[CmdletBinding()]
param([switch]$NonInteractive)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$openClaude   = Join-Path $repoRoot 'open-claudearium.ps1'

Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')          -Force
Import-Module (Join-Path $repoRoot 'modules\Profile.psm1')      -Force
Import-Module (Join-Path $repoRoot 'tests\lib\ManualTest.psm1') -Force
Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force

# Test distro + isolated profile (set up by Invoke-TestRun before any
# manual test runs).
$distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
if (-not (Test-DistroExists -Name $distro)) {
    return [pscustomobject]@{
        Name = 'manual/TabColor'; Passed = $false; Skipped = $true
        Notes = "test distro '$distro' is not registered (Invoke-TestRun should have provisioned it)"
    }
}

$testProject = 'manualtest-tabcolor'
$testSession = 'red-probe'
$tabColor    = '#E81123'  # vivid red — easy to spot
$remoteUrl   = 'file:///tmp/manualtest-tabcolor-remote.git'
$profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'manual-tabcolor'

return Invoke-ManualTest `
    -Name 'open-claudearium tab color' `
    -Instructions @"
This test will (against the ephemeral test distro '$distro'):
  - create a sentinel project '$testProject' with tabColor=$tabColor
  - create a session '$testSession' off master
  - run open-claudearium.ps1 to launch a wt tab
  - clean everything up after you answer

A wt tab should open shortly with a RED color strip ($tabColor).
You may close the tab any time after answering.
"@ `
    -Setup {
        # In-distro bare repo as the remote. Avoids any network dependency.
        $bashSetup = @'
set -e
rm -rf /tmp/manualtest-tabcolor-remote.git /tmp/manualtest-tabcolor-seed
git init --bare /tmp/manualtest-tabcolor-remote.git >/dev/null
git -C /tmp/manualtest-tabcolor-remote.git symbolic-ref HEAD refs/heads/master >/dev/null
mkdir /tmp/manualtest-tabcolor-seed && cd /tmp/manualtest-tabcolor-seed
git init -q -b master
git config user.email t@t && git config user.name t
echo manualtest > README.md
git add . && git commit -qm init
git push -q /tmp/manualtest-tabcolor-remote.git master
'@
        Invoke-InDistroScript -Name $distro -User 'claude' -Script $bashSetup | Out-Host

        Invoke-Claudearium -DistroName $distro -ProfilePath $profilePath -Args @{
            Verb='project'; SubVerb='add'; Arg=$testProject
            Remote=$remoteUrl; DefaultBranch='master'
        } | Out-Null

        # `project add -NonInteractive` doesn't accept a tabColor; patch the
        # profile entry directly so the test exercises the resolution path
        # `project.tabColor -> session.tabColor -> wt --tabColor`.
        $spec = Read-Profile -Path $profilePath -Raw
        foreach ($p in @($spec.projects)) {
            if ([string]$p.name -eq $testProject) { $p.tabColor = $tabColor }
        }
        Write-Profile -Path $profilePath -Spec $spec

        Invoke-Claudearium -DistroName $distro -ProfilePath $profilePath -Args @{
            Verb='session'; SubVerb='new'; Arg=$testSession
            Project=$testProject; Branch='master'
        } | Out-Null

        Write-Host "  Launching wt tab via open-claudearium..." -ForegroundColor DarkGray
        & $openClaude -Name $distro -ProfilePath $profilePath `
            -Project $testProject -Session $testSession | Out-Host

        Start-Sleep -Milliseconds 1500
    } `
    -Question 'Did a new wt tab open with a RED color strip (#E81123)?' `
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
                -Command 'rm -rf /tmp/manualtest-tabcolor-remote.git /tmp/manualtest-tabcolor-seed' `
                -AllowFail -CaptureOutput | Out-Null
        } catch { }
        Remove-Item -LiteralPath $profilePath -ErrorAction SilentlyContinue
        Write-Host '  Cleanup done. You can close the wt tab the test opened.' -ForegroundColor DarkGray
    } `
    -NonInteractive:$NonInteractive
