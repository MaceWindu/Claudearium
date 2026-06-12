# WtAppearance.ps1 — verify that a project's icon / background image / opacity
# flow through the generated Windows Terminal profile fragment into the launched
# tab. Runs against the ephemeral test distro and an isolated profile, and
# snapshots/restores the user's real WT fragment so it is never clobbered.
#
# Caveat surfaced to the human: Windows Terminal loads fragments only at
# startup, so the test asks the user to close all WT windows first, then opens a
# fresh one.
[CmdletBinding()]
param([switch]$NonInteractive)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$openClaude = Join-Path $repoRoot 'open-claudearium.ps1'

Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')             -Force
Import-Module (Join-Path $repoRoot 'modules\Profile.psm1')         -Force
Import-Module (Join-Path $repoRoot 'modules\WinTerminal.psm1')     -Force
Import-Module (Join-Path $repoRoot 'tests\lib\ManualTest.psm1')    -Force
Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force

$distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
if (-not (Test-DistroExists -Name $distro)) {
    return [pscustomobject]@{
        Name = 'manual/WtAppearance'; Passed = $false; Skipped = $true
        Notes = "test distro '$distro' is not registered (Invoke-TestRun should have provisioned it)"
    }
}

$testProject = 'manualtest-wtappearance'
$testSession = 'appearance-probe'
$remoteUrl   = 'file:///tmp/manualtest-wtappearance-remote.git'
$profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'manual-wtappearance'

# Snapshot the user's real fragment so we can restore it after the test.
$fragPath    = Get-WtFragmentPath
$fragBackup  = if (Test-Path -LiteralPath $fragPath -PathType Leaf) { Get-Content -LiteralPath $fragPath -Raw } else { $null }

return Invoke-ManualTest `
    -Name 'open-claudearium WT appearance (icon + background + opacity)' `
    -Instructions @"
This test will (against the ephemeral test distro '$distro'):
  - create a sentinel project '$testProject' with:
        icon                   = 🚀
        backgroundImage        = desktopWallpaper
        backgroundImageOpacity = 30%
  - generate the Windows Terminal profile fragment ('wt-profiles apply')
  - create a session '$testSession' off master
  - run open-claudearium.ps1 to launch a wt tab using that profile
  - restore your real WT fragment + clean everything up after you answer

IMPORTANT: Windows Terminal only reads fragments at startup. Close ALL open
Windows Terminal windows now (run this test from a plain PowerShell console,
not inside Windows Terminal), so the launched tab starts a fresh wt process.
"@ `
    -Setup {
        $bashSetup = @'
set -e
rm -rf /tmp/manualtest-wtappearance-remote.git /tmp/manualtest-wtappearance-seed
git init --bare /tmp/manualtest-wtappearance-remote.git >/dev/null
git -C /tmp/manualtest-wtappearance-remote.git symbolic-ref HEAD refs/heads/master >/dev/null
mkdir /tmp/manualtest-wtappearance-seed && cd /tmp/manualtest-wtappearance-seed
git init -q -b master
git config user.email t@t && git config user.name t
echo manualtest > README.md
git add . && git commit -qm init
git push -q /tmp/manualtest-wtappearance-remote.git master
'@
        Invoke-InDistroScript -Name $distro -User 'claude' -Script $bashSetup | Out-Host

        Invoke-Claudearium -DistroName $distro -ProfilePath $profilePath -Args @{
            Verb='project'; SubVerb='add'; Arg=$testProject
            Remote=$remoteUrl; DefaultBranch='master'
        } | Out-Null

        # `project add -NonInteractive` doesn't accept the appearance fields;
        # patch the profile entry directly to exercise the fragment-generation +
        # `-p` launch path.
        $spec = Read-Profile -Path $profilePath -Raw
        foreach ($p in @($spec.projects)) {
            if ([string]$p.name -eq $testProject) {
                $p.icon                   = '🚀'
                $p.backgroundImage        = 'desktopWallpaper'
                $p.backgroundImageOpacity = 30
            }
        }
        Write-Profile -Path $profilePath -Spec $spec

        Invoke-Claudearium -DistroName $distro -ProfilePath $profilePath -Args @{
            Verb='wt-profiles'; SubVerb='apply'
        } | Out-Host

        Invoke-Claudearium -DistroName $distro -ProfilePath $profilePath -Args @{
            Verb='session'; SubVerb='new'; Arg=$testSession
            Project=$testProject; Branch='master'
        } | Out-Null

        Write-Host "  Launching wt tab via open-claudearium..." -ForegroundColor DarkGray
        & $openClaude -Name $distro -ProfilePath $profilePath `
            -Project $testProject -Session $testSession | Out-Host

        Start-Sleep -Milliseconds 1500
    } `
    -Question 'Did a new wt tab open with a 🚀 tab icon AND a faint (~30%) desktop-wallpaper background?' `
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
                -Command 'rm -rf /tmp/manualtest-wtappearance-remote.git /tmp/manualtest-wtappearance-seed' `
                -AllowFail -CaptureOutput | Out-Null
        } catch { }
        # Restore the user's real WT fragment (or remove the one we created).
        if ($null -ne $fragBackup) {
            $dir = Split-Path -Parent $fragPath
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
            Set-Content -LiteralPath $fragPath -Value $fragBackup -Encoding UTF8
        }
        elseif (Test-Path -LiteralPath $fragPath -PathType Leaf) {
            Remove-Item -LiteralPath $fragPath -Force
        }
        Remove-Item -LiteralPath $profilePath -ErrorAction SilentlyContinue
        Write-Host '  Cleanup done (real WT fragment restored). You can close the wt tab.' -ForegroundColor DarkGray
    } `
    -NonInteractive:$NonInteractive
