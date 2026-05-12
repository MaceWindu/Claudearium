# TabColor.ps1 — verify that open-claudearium.ps1 propagates the
# per-project tabColor from the profile into the wt tab. The test
# creates a sentinel project + session with a vivid red color, opens
# it, and asks the tester to confirm the tab color visually. All
# state mutations are cleaned up in the finally path.
[CmdletBinding()]
param([switch]$NonInteractive)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$claudearium  = Join-Path $repoRoot 'claudearium.ps1'
$openClaude   = Join-Path $repoRoot 'open-claudearium.ps1'

Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')      -Force
Import-Module (Join-Path $repoRoot 'modules\Profile.psm1')  -Force
Import-Module (Join-Path $repoRoot 'tests\lib\ManualTest.psm1') -Force

$distro      = Get-RealDistroForManualTest
$testProject = 'manualtest-tabcolor'
$testSession = 'red-probe'
$tabColor    = '#E81123'  # vivid red — easy to spot
$remoteUrl   = 'file:///tmp/manualtest-tabcolor-remote.git'

if (-not (Test-RealDistroReady -DistroName $distro)) {
    return [pscustomobject]@{
        Name = 'manual/TabColor'; Passed = $false; Skipped = $true
        Notes = "real distro '$distro' is not registered; run 'claudearium.ps1 setup' first"
    }
}

return Invoke-ManualTest `
    -Name 'open-claudearium tab color' `
    -Instructions @"
This test will:
  - create a sentinel project '$testProject' with tabColor=$tabColor in your profile
  - create a session 'red-probe' off master
  - run open-claudearium.ps1 to launch a wt tab
  - clean everything up after you answer

A wt tab should open shortly with a RED color strip ($tabColor).
You may close the tab any time after answering.
"@ `
    -Setup {
        # Refuse to clobber a real project of the same name.
        $listOut = & $claudearium project list 2>&1 | Out-String
        if ($listOut -match "(?m)^\s*$testProject\b") {
            throw "Project '$testProject' already exists. Remove it manually or rename the sentinel."
        }

        # In-distro bare repo as the remote. Avoid any network dependency.
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

        # Add project to profile.
        & $claudearium project add $testProject `
            -Remote $remoteUrl -DefaultBranch master -NonInteractive | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "project add failed (exit $LASTEXITCODE)" }

        # `project add -NonInteractive` doesn't accept a tabColor; patch the
        # profile entry directly so the test exercises the resolution path
        # `project.tabColor -> session.tabColor -> wt --tabColor`.
        $pp = Get-DefaultProfilePath
        $spec = Read-Profile -Path $pp -Raw
        foreach ($p in @($spec.projects)) {
            if ([string]$p.name -eq $testProject) { $p.tabColor = $tabColor }
        }
        Write-Profile -Path $pp -Spec $spec

        # Create session.
        & $claudearium session new $testSession `
            -Project $testProject -Branch master -NonInteractive | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "session new failed (exit $LASTEXITCODE)" }

        # Launch open-claudearium for that exact session. Start-Process
        # returns immediately so the prompt comes up while wt opens.
        Write-Host "  Launching wt tab via open-claudearium..." -ForegroundColor DarkGray
        & $openClaude -Project $testProject -Session $testSession | Out-Host

        # Tiny pause to let wt actually paint the tab before the user looks.
        Start-Sleep -Milliseconds 1500
    } `
    -Question 'Did a new wt tab open with a RED color strip (#E81123)?' `
    -Cleanup {
        # Best-effort cleanup; never throw out of finally.
        try { & $claudearium session remove $testSession -Project $testProject -Force -NonInteractive | Out-Host } catch { }
        try { & $claudearium project remove $testProject -Force -NonInteractive | Out-Host } catch { }
        try {
            Invoke-InDistro -Name $distro -User 'claude' `
                -Command 'rm -rf /tmp/manualtest-tabcolor-remote.git /tmp/manualtest-tabcolor-seed' `
                -AllowFail -CaptureOutput | Out-Null
        } catch { }
        Write-Host '  Cleanup done. You can close the wt tab the test opened.' -ForegroundColor DarkGray
    } `
    -NonInteractive:$NonInteractive
