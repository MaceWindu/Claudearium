# Tmux.Tests.ps1 — pure helpers from modules/Tmux.psm1. Live enumeration
# (Get-TmuxSessions / Install-Tmux / Stop-TmuxSession) needs a distro and is
# exercised under tests/distro/.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Tmux.psm1') -Force
}

Describe 'Get-TmuxSessionName' {
    It 'builds the cl-project-name form' {
        Get-TmuxSessionName -Project 'acme' -Name 'feat-1234' | Should -Be 'cl-acme-feat-1234'
    }

    It 'folds tmux-special and other unsafe characters to underscore' {
        # '.' and ':' are tmux target specifiers; a dotted project name must not
        # leak them into the session name.
        Get-TmuxSessionName -Project 'my.app' -Name 'foo:bar' | Should -Be 'cl-my_app-foo_bar'
    }

    It 'is deterministic for the same inputs' {
        $a = Get-TmuxSessionName -Project 'p' -Name 's'
        $b = Get-TmuxSessionName -Project 'p' -Name 's'
        $a | Should -Be $b
    }
}

Describe 'Get-TmuxLaunchCommand' {
    It 'attaches-or-creates with new-session -A for a distro session' {
        $cmd = Get-TmuxLaunchCommand -TmuxName 'cl-acme-foo'
        $cmd | Should -Be "exec tmux new-session -A -s 'cl-acme-foo' claude"
    }

    It 'sources the init script then execs for a host session' {
        $cmd = Get-TmuxLaunchCommand -TmuxName 'cl-acme-foo' -InitScript '/home/cp-acme/host-projects/acme/init.sh'
        $cmd | Should -Be "source '/home/cp-acme/host-projects/acme/init.sh'; exec tmux new-session -A -s 'cl-acme-foo' claude"
    }

    It 'emits no bare $ (gotcha #1 / #20: nothing for the wsl argv hop to mangle)' {
        $cmd = Get-TmuxLaunchCommand -TmuxName 'cl-acme-foo' -InitScript '/x/init.sh'
        $cmd | Should -Not -Match '\$'
    }
}

Describe 'ConvertFrom-TmuxLs' {
    It 'returns an empty array for empty input' {
        (ConvertFrom-TmuxLs -Raw '').Count | Should -Be 0
        (ConvertFrom-TmuxLs -Raw $null).Count | Should -Be 0
    }

    It 'parses name|attached|windows into typed records' {
        $rows = ConvertFrom-TmuxLs -Raw "cl-acme-foo|1|2`ncl-acme-bar|0|1"
        $rows.Count | Should -Be 2
        $foo = $rows | Where-Object { $_.Name -eq 'cl-acme-foo' }
        $foo.Attached | Should -BeTrue
        $foo.Windows  | Should -Be 2
        $bar = $rows | Where-Object { $_.Name -eq 'cl-acme-bar' }
        $bar.Attached | Should -BeFalse
    }

    It 'treats attached client-count > 1 as attached' {
        $rows = ConvertFrom-TmuxLs -Raw 'cl-x-y|3|1'
        $rows[0].Attached | Should -BeTrue
    }

    It 'skips noise lines that lack a pipe delimiter' {
        $rows = ConvertFrom-TmuxLs -Raw "wsl: some warning`ncl-x-y|0|1"
        $rows.Count | Should -Be 1
        $rows[0].Name | Should -Be 'cl-x-y'
    }
}

Describe 'Resolve-SessionLiveness' {
    It 'classifies tracked sessions as attached / detached / dead' {
        $sessions = @(
            @{ project = 'acme'; name = 'a'; tmux = 'cl-acme-a' }
            @{ project = 'acme'; name = 'b'; tmux = 'cl-acme-b' }
            @{ project = 'acme'; name = 'c'; tmux = 'cl-acme-c' }
        )
        $live = @(
            @{ Name = 'cl-acme-a'; Attached = $true }
            @{ Name = 'cl-acme-b'; Attached = $false }
        )
        $res = Resolve-SessionLiveness -Sessions $sessions -LiveTmux $live
        ($res.Tracked | Where-Object { $_.Name -eq 'a' }).Status | Should -Be 'attached'
        ($res.Tracked | Where-Object { $_.Name -eq 'b' }).Status | Should -Be 'detached'
        ($res.Tracked | Where-Object { $_.Name -eq 'c' }).Status | Should -Be 'dead'
    }

    It 'derives the tmux name when a record lacks the stamped field' {
        $sessions = @(@{ project = 'acme'; name = 'a' })   # no tmux key
        $live = @(@{ Name = 'cl-acme-a'; Attached = $true })
        $res = Resolve-SessionLiveness -Sessions $sessions -LiveTmux $live
        $res.Tracked[0].Status   | Should -Be 'attached'
        $res.Tracked[0].TmuxName | Should -Be 'cl-acme-a'
    }

    It 'surfaces cl-* tmux sessions with no state record as untracked' {
        $sessions = @(@{ project = 'acme'; name = 'a'; tmux = 'cl-acme-a' })
        $live = @(
            @{ Name = 'cl-acme-a'; Attached = $true }
            @{ Name = 'cl-acme-ghost'; Attached = $false }
        )
        $res = Resolve-SessionLiveness -Sessions $sessions -LiveTmux $live
        $res.Untracked.Count | Should -Be 1
        $res.Untracked[0].TmuxName | Should -Be 'cl-acme-ghost'
    }

    It 'ignores non-cl tmux sessions when looking for untracked ones' {
        $res = Resolve-SessionLiveness -Sessions @() -LiveTmux @(@{ Name = 'scratch'; Attached = $false })
        $res.Untracked.Count | Should -Be 0
    }

    It 'handles empty inputs' {
        $res = Resolve-SessionLiveness -Sessions @() -LiveTmux @()
        $res.Tracked.Count   | Should -Be 0
        $res.Untracked.Count | Should -Be 0
    }
}
