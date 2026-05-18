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
    Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath -Args @{
        Verb='session'; SubVerb='new'; Arg='dev'
        Project=$script:proj; Branch='master'
    }
}

AfterAll {
    try {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='project'; SubVerb='remove'; Arg=$script:proj; Force=$true } -AllowFail | Out-Null
    } catch {}
    Invoke-InDistro -Name $script:distro -User 'claude' -AllowFail -CaptureOutput `
        -Command 'rm -rf /tmp/prune-test-remote.git /tmp/prune-test-seed' | Out-Null
    Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
}

Describe 'prune detects orphaned sessions when the worktree dir is gone' -Tag 'distro' {
    # Simulate drift: rm -rf the worktree directly, leaving state.sessions
    # pointing at a path that no longer exists.
    It 'reports the orphan in -DryRun without mutating state' {
        Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command "rm -rf /home/claude/projects/$($script:proj)/sessions/dev" -AllowFail | Out-Null

        $claudearium = Get-ClaudeariumScriptPath
        $out = & $claudearium prune -Scope sessions -DryRun `
            -Name $script:distro -ProfilePath $script:profilePath -NonInteractive *>&1
        $txt = ($out -join "`n")
        $txt | Should -Match 'orphan: '
        $txt | Should -Match ([regex]::Escape($script:proj))

        # State must still have the session (we ran -DryRun).
        $state = Read-State -DistroName $script:distro
        @($state.sessions | Where-Object { $_.project -eq $script:proj -and $_.name -eq 'dev' }).Count | Should -Be 1
    }

    It 'removes the orphan record (and prunes the stale worktree ref) when run without -DryRun' {
        # -Scope all here so the next test starts from a fully-clean distro;
        # rm'ing the worktree dir leaves both a stale state.sessions record
        # AND a `prunable` entry in `git worktree list`, so we need both
        # scopes to converge.
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
