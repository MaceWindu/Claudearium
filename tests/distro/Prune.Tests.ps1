# Prune.Tests.ps1 — end-to-end coverage for the `prune` verb against a real
# ephemeral distro. Builds a session, manually corrupts the state by deleting
# the worktree dir, then asserts that prune detects + repairs the drift.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')   -Force
    Import-Module (Join-Path $repoRoot 'modules\State.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
    $script:repoRoot    = $repoRoot
    $script:distro      = $distro
    $script:profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'prune'

    # Same in-distro bare repo pattern as Project.Tests.ps1.
    Invoke-InDistroScript -Name $distro -User 'claude' -Script @'
set -e
rm -rf /tmp/prune-test-remote.git /tmp/prune-test-seed
git init --bare /tmp/prune-test-remote.git >/dev/null
git -C /tmp/prune-test-remote.git symbolic-ref HEAD refs/heads/master >/dev/null
mkdir /tmp/prune-test-seed && cd /tmp/prune-test-seed
git init -q -b master
git config user.email t@t && git config user.name t
echo hi > README.md
git add . && git commit -qm init
git push -q /tmp/prune-test-remote.git master
'@
    $script:remoteUrl = 'file:///tmp/prune-test-remote.git'
    $script:proj = 'prunetest'

    Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath -Args @{
        Verb='project'; SubVerb='add'; Arg=$script:proj
        Remote=$script:remoteUrl; DefaultBranch='master'
    }
    # Register a launch-pad session. It is NOT opened, so no tmux session exists
    # for it yet — which makes it `dead` from the liveness check's point of view
    # (a tracked record with no running tmux session). That's the drift the
    # `sessions` prune scope detects + repairs under the curation-main model.
    Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath -Args @{
        Verb='session'; SubVerb='new'; Arg='dev'; Project=$script:proj
    }
    $script:uh = Get-TestProjectUserHome -DistroName $script:distro -Project $script:proj
}

AfterAll {
    try {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='project'; SubVerb='remove'; Arg=$script:proj; Force=$true } -AllowFail | Out-Null
    } finally {
        Invoke-InDistro -Name $script:distro -User 'claude' -AllowFail -CaptureOutput `
            -Command 'rm -rf /tmp/prune-test-remote.git /tmp/prune-test-seed' | Out-Null
        Invoke-InDistroScript -Name $script:distro -User 'root' -AllowFail -Script @'
for u in $(getent passwd | awk -F: '$1 ~ /^cp-prunetest/ {print $1}'); do
  pkill -KILL -u "$u" 2>/dev/null || true
  userdel -r "$u" 2>/dev/null || true
done
'@ | Out-Null
        Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
    }
}

Describe 'prune detects dead sessions whose tmux session is not running' -Tag 'distro' {
    It 'reports the dead session in -DryRun without mutating state' {
        $claudearium = Get-ClaudeariumScriptPath
        $out = & $claudearium prune -Scope sessions -DryRun `
            -Name $script:distro -ProfilePath $script:profilePath -NonInteractive *>&1
        $txt = ($out -join "`n")
        $txt | Should -Match 'dead: '
        $txt | Should -Match ([regex]::Escape($script:proj))

        # State must still have the session (we ran -DryRun).
        $state = Read-State -DistroName $script:distro
        @($state.sessions | Where-Object { $_.project -eq $script:proj -and $_.name -eq 'dev' }).Count | Should -Be 1
    }

    It 'removes the dead session record when run without -DryRun' {
        $claudearium = Get-ClaudeariumScriptPath
        & $claudearium prune -Scope all -Force `
            -Name $script:distro -ProfilePath $script:profilePath -NonInteractive *>&1 | Out-Null

        $state = Read-State -DistroName $script:distro
        @($state.sessions | Where-Object { $_.project -eq $script:proj -and $_.name -eq 'dev' }).Count | Should -Be 0
    }

    It 'is a no-op on a clean distro (no scopes find drift)' {
        $claudearium = Get-ClaudeariumScriptPath
        $out = & $claudearium prune -Scope all `
            -Name $script:distro -ProfilePath $script:profilePath -NonInteractive *>&1
        ($out -join "`n") | Should -Match 'Nothing to prune'
    }
}
