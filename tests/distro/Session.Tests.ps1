# Session.Tests.ps1 — happy-path coverage for the `session` verbs.
# Builds on Project.Tests.ps1's in-distro bare-repo pattern.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
    $script:repoRoot    = $repoRoot
    $script:distro      = $distro
    $script:profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'session'

    # Set up a project the session can attach to.
    Invoke-InDistroScript -Name $distro -User 'claude' -Script @'
set -e
rm -rf /tmp/session-remote.git /tmp/session-seed
git init --bare /tmp/session-remote.git >/dev/null
git -C /tmp/session-remote.git symbolic-ref HEAD refs/heads/master >/dev/null
mkdir /tmp/session-seed && cd /tmp/session-seed
git init -q -b master
git config user.email t@t && git config user.name t
echo hi > README.md
git add . && git commit -qm init
git push -q /tmp/session-remote.git master
'@
    Invoke-Claudearium -DistroName $distro -ProfilePath $script:profilePath `
        -ScriptArgs @('project', 'add', 'sessproj', '-Remote', 'file:///tmp/session-remote.git', '-DefaultBranch', 'master')
}

AfterAll {
    Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
        -ScriptArgs @('project', 'remove', 'sessproj', '-Force') -AllowFail | Out-Null
    Invoke-InDistro -Name $script:distro -User 'claude' `
        -Command 'rm -rf /tmp/session-remote.git /tmp/session-seed' -AllowFail -CaptureOutput | Out-Null
    Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
}

Describe 'session new' -Tag 'distro' {
    It 'creates a worktree on an existing branch' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs @('session', 'new', 'sess-1', '-Project', 'sessproj', '-Branch', 'master')

        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'test -d /home/claude/projects/sessproj/sessions/sess-1 && echo ok' -CaptureOutput -AllowFail
        ($r.Output -join "`n").Trim() | Should -Be 'ok'
    }

    It 'creates a fresh branch when -NewBranch is set' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs @('session', 'new', 'sess-2', '-Project', 'sessproj', '-Branch', 'feat/sess-2', '-NewBranch', '-BaseBranch', 'master')

        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'git -C /home/claude/projects/sessproj/sessions/sess-2 rev-parse --abbrev-ref HEAD' -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'feat/sess-2'
    }
}

Describe 'session remove' -Tag 'distro' {
    It 'removes a clean session without -Force' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs @('session', 'remove', 'sess-1', '-Project', 'sessproj')

        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'test -d /home/claude/projects/sessproj/sessions/sess-1 && echo present || echo gone' -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'gone'
    }

    It 'refuses to remove a dirty session without -Force, succeeds with it' {
        # Dirty the worktree.
        Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'echo dirty > /home/claude/projects/sessproj/sessions/sess-2/dirty.txt' | Out-Null

        $rc = Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs @('session', 'remove', 'sess-2', '-Project', 'sessproj') -AllowFail
        $rc | Should -Not -Be 0

        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs @('session', 'remove', 'sess-2', '-Project', 'sessproj', '-Force')

        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'test -d /home/claude/projects/sessproj/sessions/sess-2 && echo present || echo gone' -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'gone'
    }
}
