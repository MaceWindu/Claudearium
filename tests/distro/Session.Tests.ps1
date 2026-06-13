# Session.Tests.ps1 — happy-path coverage for the `session` verbs under the
# curation-main model: `session new` registers a tmux-backed launch-pad session
# (no per-session worktree) that opens into the project's persistent main/
# checkout; `session remove` drops the record (and kills its tmux session).
# Builds on Project.Tests.ps1's in-distro bare-repo pattern.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')      -Force
    Import-Module (Join-Path $repoRoot 'modules\State.psm1')    -Force
    Import-Module (Join-Path $repoRoot 'modules\Sessions.psm1') -Force
    Import-Module (Join-Path $repoRoot 'modules\Projects.psm1') -Force
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
    # Sessions open into the project's main/ checkout under its dedicated user home.
    $script:projUH   = Get-TestProjectUserHome -DistroName $distro -Project 'sessproj'
    $script:mainPath = "$($script:projUH.Home)/projects/sessproj/main"
    $script:sessRoot = "$($script:projUH.Home)/projects/sessproj/sessions"

    function Get-TestSession {
        param([string]$Name)
        $state = Read-State -DistroName $script:distro
        return @(Get-Sessions -State $state -Project 'sessproj' | Where-Object { [string]$_.name -eq $Name })[0]
    }
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
    It 'registers a tmux-backed launch-pad session and ensures main/ — no per-session worktree' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='session'; SubVerb='new'; Arg='sess-1'; Project='sessproj' }

        # main/ checkout exists on the curation branch...
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "test -e '$($script:mainPath)/.git' && echo ok" -CaptureOutput -AllowFail
        ($r.Output -join "`n").Trim() | Should -Be 'ok'

        # ...and NO old-style per-session worktree was created.
        $w = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "test -d '$($script:sessRoot)/sess-1' && echo present || echo gone" -CaptureOutput
        ($w.Output -join "`n").Trim() | Should -Be 'gone'

        # The record carries the derived tmux name and no worktree/branch fields.
        $s = Get-TestSession -Name 'sess-1'
        $s | Should -Not -BeNullOrEmpty
        [string]$s.tmux | Should -Be 'cl-sessproj-sess-1'
        $s.ContainsKey('worktreePath') | Should -BeFalse
    }

    It 'supports a second parallel session sharing the one main/ checkout' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='session'; SubVerb='new'; Arg='sess-2'; Project='sessproj' }

        (Get-TestSession -Name 'sess-2') | Should -Not -BeNullOrEmpty

        # Worktree discovery sees exactly one worktree — the shared main/ launch
        # pad (sessions don't each get their own).
        $wts = @(Get-ProjectWorktrees -DistroName $script:distro -Project 'sessproj' `
            -User ([string]$script:projUH.User) -Home ([string]$script:projUH.Home))
        $wts.Count | Should -Be 1
        $wts[0].IsMain | Should -BeTrue
    }
}

Describe 'session remove' -Tag 'distro' {
    It 'drops the session record with -Force and leaves main/ intact' {
        # NB: in NonInteractive mode (always set by the harness) remove WITHOUT
        # -Force aborts silently (the confirm prompt defaults to false), so the
        # realistic happy path is -Force.
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='session'; SubVerb='remove'; Arg='sess-1'; Project='sessproj'; Force=$true }

        (Get-TestSession -Name 'sess-1') | Should -BeNullOrEmpty

        # The persistent main/ checkout is never torn down by session removal.
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "test -e '$($script:mainPath)/.git' && echo present || echo gone" -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'present'
    }
}
