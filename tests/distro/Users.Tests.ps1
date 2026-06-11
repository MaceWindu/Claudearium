# Users.Tests.ps1 — per-project Linux user isolation, end to end.
# Adds two projects, asserts each gets its own cp-* user with a 0700 home and a
# distinct uid, that the agent-facing user has password-required (NOT passwordless)
# sudo, that one project user cannot read another's home, and that removing a
# project deletes its user. Uses an in-distro bare repo as the remote (no network).

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'modules\State.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
    $script:repoRoot    = $repoRoot
    $script:distro      = $distro
    $script:profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'users'

    Invoke-InDistroScript -Name $distro -User 'root' -Script @'
set -e
rm -rf /tmp/users-remote.git /tmp/users-seed
git init --bare /tmp/users-remote.git >/dev/null
git -C /tmp/users-remote.git symbolic-ref HEAD refs/heads/master >/dev/null
mkdir /tmp/users-seed && cd /tmp/users-seed
git init -q -b master
git config user.email t@t && git config user.name t
echo hi > README.md
git add . && git commit -qm init
git push -q /tmp/users-remote.git master
'@
    $script:remoteUrl = 'file:///tmp/users-remote.git'

    Invoke-Claudearium -DistroName $distro -ProfilePath $script:profilePath `
        -Args @{ Verb='project'; SubVerb='add'; Arg='usertest-a'; Remote=$script:remoteUrl; DefaultBranch='master' }
    Invoke-Claudearium -DistroName $distro -ProfilePath $script:profilePath `
        -Args @{ Verb='project'; SubVerb='add'; Arg='usertest-b'; Remote=$script:remoteUrl; DefaultBranch='master' }
}

AfterAll {
    foreach ($p in @('usertest-a', 'usertest-b')) {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='project'; SubVerb='remove'; Arg=$p; Force=$true } -AllowFail | Out-Null
    }
    # Reclaim any user a bailed assertion left behind.
    Invoke-InDistroScript -Name $script:distro -User 'root' -AllowFail -Script @'
for u in $(getent passwd | awk -F: '$1 ~ /^cp-usertest/ {print $1}'); do
  pkill -KILL -u "$u" 2>/dev/null || true
  userdel -r "$u" 2>/dev/null || true
done
'@ | Out-Null
    Invoke-InDistro -Name $script:distro -User 'root' `
        -Command 'rm -rf /tmp/users-remote.git /tmp/users-seed' -AllowFail -CaptureOutput | Out-Null
    Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
}

Describe 'per-project user allocation' -Tag 'distro' {
    It 'creates a distinct cp-* user per project, recorded in state with uid >= 30000' {
        $a = Get-TestProjectUserHome -DistroName $script:distro -Project 'usertest-a'
        $b = Get-TestProjectUserHome -DistroName $script:distro -Project 'usertest-b'
        $a.User | Should -Match '^cp-'
        $b.User | Should -Match '^cp-'
        $a.User | Should -Not -Be $b.User

        $st = Read-State -DistroName $script:distro
        [int]((Get-ProjectUser -State $st -Project 'usertest-a').uid) | Should -BeGreaterOrEqual 30000
        (Get-ProjectUser -State $st -Project 'usertest-a').uid | Should -Not -Be (Get-ProjectUser -State $st -Project 'usertest-b').uid
    }

    It 'clones the mirror into the project user home (not /home/claude)' {
        $a = Get-TestProjectUserHome -DistroName $script:distro -Project 'usertest-a'
        $r = Invoke-InDistro -Name $script:distro -User 'root' -CaptureOutput -AllowFail `
            -Command "test -d '$($a.Home)/mirrors/usertest-a.git' && echo ok"
        ($r.Output -join "`n").Trim() | Should -Be 'ok'
        # And NOT under the legacy lobby home.
        $r2 = Invoke-InDistro -Name $script:distro -User 'root' -CaptureOutput -AllowFail `
            -Command "test -d /home/claude/mirrors/usertest-a.git && echo present || echo gone"
        ($r2.Output -join "`n").Trim() | Should -Be 'gone'
    }

    It 'makes the project home 0700' {
        $a = Get-TestProjectUserHome -DistroName $script:distro -Project 'usertest-a'
        $r = Invoke-InDistro -Name $script:distro -User 'root' -CaptureOutput -AllowFail `
            -Command "stat -c '%a' '$($a.Home)'"
        ($r.Output -join "`n").Trim() | Should -Be '700'
    }
}

Describe 'isolation invariants' -Tag 'distro' {
    It 'gives the project user password-required sudo (NOT passwordless)' {
        $a = Get-TestProjectUserHome -DistroName $script:distro -Project 'usertest-a'
        # sudo -n (non-interactive) must FAIL: no NOPASSWD drop-in for cp-* users.
        $r = Invoke-InDistro -Name $script:distro -User ([string]$a.User) -CaptureOutput -AllowFail `
            -Command 'sudo -n true 2>/dev/null && echo nopasswd || echo needs-password'
        ($r.Output -join "`n").Trim() | Should -Be 'needs-password'
    }

    It 'denies one project user read access to another project user home' {
        $a = Get-TestProjectUserHome -DistroName $script:distro -Project 'usertest-a'
        $b = Get-TestProjectUserHome -DistroName $script:distro -Project 'usertest-b'
        # User A trying to list B's home should be denied by the 0700 perms.
        $r = Invoke-InDistro -Name $script:distro -User ([string]$a.User) -CaptureOutput -AllowFail `
            -Command "ls '$($b.Home)/mirrors' 2>/dev/null && echo readable || echo denied"
        ($r.Output -join "`n").Trim() | Should -Be 'denied'
    }
}

Describe 'project remove deletes the user' -Tag 'distro' {
    It 'userdel -rs the project user and drops the state record' {
        $b = Get-TestProjectUserHome -DistroName $script:distro -Project 'usertest-b'
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='project'; SubVerb='remove'; Arg='usertest-b'; Force=$true }

        $r = Invoke-InDistro -Name $script:distro -User 'root' -CaptureOutput -AllowFail `
            -Command "id -u '$($b.User)' >/dev/null 2>&1 && echo present || echo gone"
        ($r.Output -join "`n").Trim() | Should -Be 'gone'

        $st = Read-State -DistroName $script:distro
        Get-ProjectUser -State $st -Project 'usertest-b' | Should -BeNullOrEmpty
    }
}
