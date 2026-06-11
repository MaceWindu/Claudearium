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
        -Args @{ Verb='project'; SubVerb='add'; Arg='sessproj'; Remote='file:///tmp/session-remote.git'; DefaultBranch='master' }
    # Sessions live under the project's dedicated user home; resolve it once.
    $script:projUH = Get-TestProjectUserHome -DistroName $distro -Project 'sessproj'
    $script:sessRoot = "$($script:projUH.Home)/projects/sessproj/sessions"
}

AfterAll {
    Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
        -Args @{ Verb='project'; SubVerb='remove'; Arg='sessproj'; Force=$true } -AllowFail | Out-Null
    Invoke-InDistro -Name $script:distro -User 'claude' `
        -Command 'rm -rf /tmp/session-remote.git /tmp/session-seed' -AllowFail -CaptureOutput | Out-Null
    # Reclaim the project user if `project remove` above didn't run.
    Invoke-InDistroScript -Name $script:distro -User 'root' -AllowFail -Script @'
for u in $(getent passwd | awk -F: '$1 ~ /^cp-sessproj/ {print $1}'); do
  pkill -KILL -u "$u" 2>/dev/null || true
  userdel -r "$u" 2>/dev/null || true
done
'@ | Out-Null
    Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
}

Describe 'session new' -Tag 'distro' {
    It 'creates a worktree on an existing branch' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='session'; SubVerb='new'; Arg='sess-1'; Project='sessproj'; Branch='master' }

        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "test -d '$($script:sessRoot)/sess-1' && echo ok" -CaptureOutput -AllowFail
        ($r.Output -join "`n").Trim() | Should -Be 'ok'
    }

    It 'creates a fresh branch when -NewBranch is set' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='session'; SubVerb='new'; Arg='sess-2'; Project='sessproj'; Branch='feat/sess-2'; NewBranch=$true; BaseBranch='master' }

        # git as the owning user (root would trip git's dubious-ownership guard).
        $r = Invoke-InDistro -Name $script:distro -User ([string]$script:projUH.User) `
            -Command "git -C '$($script:sessRoot)/sess-2' rev-parse --abbrev-ref HEAD" -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'feat/sess-2'
    }
}

Describe 'session remove' -Tag 'distro' {
    It 'removes a clean session with -Force' {
        # NB: in NonInteractive mode (which the harness always sets), session
        # remove WITHOUT -Force aborts silently — the confirmation prompt
        # defaults to false. So the realistic "happy path" here is -Force.
        # The dirty-refuse-without-Force semantics live in an interactive
        # manual test (Step 4).
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='session'; SubVerb='remove'; Arg='sess-1'; Project='sessproj'; Force=$true }

        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "test -d '$($script:sessRoot)/sess-1' && echo present || echo gone" -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'gone'
    }

    It 'removes a dirty session with -Force' {
        # Dirty the worktree (as the owning user), then -Force through.
        Invoke-InDistro -Name $script:distro -User ([string]$script:projUH.User) `
            -Command "echo dirty > '$($script:sessRoot)/sess-2/dirty.txt'" | Out-Null

        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='session'; SubVerb='remove'; Arg='sess-2'; Project='sessproj'; Force=$true }

        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "test -d '$($script:sessRoot)/sess-2' && echo present || echo gone" -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'gone'
    }
}
