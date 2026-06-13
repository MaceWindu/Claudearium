# Sessions.Tests.ps1 — pure helpers from modules/Sessions.psm1. Worktree
# creation / removal needs a distro and lives under tests/distro/.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Sessions.psm1') -Force
}

Describe 'ConvertTo-SessionNameSuggestion' {
    It 'returns the last slash-segment of a branch name' {
        ConvertTo-SessionNameSuggestion -Branch 'feature/PROJ-123-add-foo' | Should -Be 'PROJ-123-add-foo'
    }

    It 'returns the input unchanged for a plain branch' {
        ConvertTo-SessionNameSuggestion -Branch 'master' | Should -Be 'master'
    }

    It 'handles refs/heads-prefixed names' {
        ConvertTo-SessionNameSuggestion -Branch 'refs/heads/feature/foo' | Should -Be 'foo'
    }
}

Describe 'Remove-SessionByName routing' {
    # Why pure: the helper is a router. Distro/host worktree teardown and fstab
    # rewriting are exercised end-to-end under tests/distro/. Here we just want
    # to pin the routing decision (which Remove-* gets called, plus the mount
    # refresh on the host branch).
    It 'routes to Remove-Session for a distro project' {
        Mock -ModuleName Sessions Remove-Session { } -Verifiable
        Mock -ModuleName Sessions Remove-HostSession { }
        Mock -ModuleName Sessions Set-HostMountsInDistro { }

        $state = @{ sessions = @(@{ project = 'p'; name = 's' }) }
        $ps    = @{ name = 'p'; type = 'distro'; remote = 'https://example.test/p.git' }

        Remove-SessionByName -DistroName 'd' -State $state -Project 'p' -Name 's' -ProjectSpec $ps -Force

        Should -Invoke -ModuleName Sessions Remove-Session     -Times 1 -Exactly
        Should -Invoke -ModuleName Sessions Remove-HostSession -Times 0 -Exactly
        Should -Invoke -ModuleName Sessions Set-HostMountsInDistro -Times 0 -Exactly
    }

    It 'routes to Remove-HostSession and refreshes fstab for a host project' {
        Mock -ModuleName Sessions Remove-Session { }
        Mock -ModuleName Sessions Remove-HostSession { } -Verifiable
        Mock -ModuleName Sessions Set-HostMountsInDistro { } -Verifiable
        Mock -ModuleName Sessions Get-MergedDesiredMounts { @() }

        $state = @{ sessions = @(@{ project = 'p'; name = 's'; type = 'host' }) }
        $ps    = @{ name = 'p'; type = 'host'; hostCheckout = 'C:\nowhere' }

        Remove-SessionByName -DistroName 'd' -State $state -Project 'p' -Name 's' -ProjectSpec $ps -Force

        Should -Invoke -ModuleName Sessions Remove-HostSession    -Times 1 -Exactly
        Should -Invoke -ModuleName Sessions Set-HostMountsInDistro -Times 1 -Exactly
        Should -Invoke -ModuleName Sessions Remove-Session        -Times 0 -Exactly
    }

    It 'falls back to the session record type when ProjectSpec is null (orphan cleanup, distro)' {
        Mock -ModuleName Sessions Remove-Session { } -Verifiable
        Mock -ModuleName Sessions Remove-HostSession { }
        Mock -ModuleName Sessions Set-HostMountsInDistro { }

        $state = @{ sessions = @(@{ project = 'p'; name = 's' }) }   # no type => distro

        Remove-SessionByName -DistroName 'd' -State $state -Project 'p' -Name 's' -ProjectSpec $null -Force

        Should -Invoke -ModuleName Sessions Remove-Session     -Times 1 -Exactly
        Should -Invoke -ModuleName Sessions Remove-HostSession -Times 0 -Exactly
    }

    It 'throws when the session is host-typed but the profile entry is missing' {
        Mock -ModuleName Sessions Remove-Session { }
        Mock -ModuleName Sessions Remove-HostSession { }

        $state = @{ sessions = @(@{ project = 'p'; name = 's'; type = 'host' }) }

        { Remove-SessionByName -DistroName 'd' -State $state -Project 'p' -Name 's' -ProjectSpec $null -Force } |
            Should -Throw '*hostProject*missing from the profile*'
    }
}

Describe 'Get-MostRecentSession' {
    It 'returns $null when state has no sessions' {
        Get-MostRecentSession -State @{} | Should -Be $null
    }

    It 'picks the session with the most recent lastOpenedAt' {
        $state = @{
            sessions = @(
                @{ name = 'a'; createdAt = '2026-01-01T00:00:00Z'; lastOpenedAt = '2026-04-01T00:00:00Z' }
                @{ name = 'b'; createdAt = '2026-02-01T00:00:00Z'; lastOpenedAt = '2026-05-01T00:00:00Z' }
                @{ name = 'c'; createdAt = '2026-03-01T00:00:00Z' }
            )
        }
        (Get-MostRecentSession -State $state).name | Should -Be 'b'
    }

    It 'falls back to createdAt for sessions never opened' {
        $state = @{
            sessions = @(
                @{ name = 'old'; createdAt = '2026-01-01T00:00:00Z' }
                @{ name = 'new'; createdAt = '2026-04-01T00:00:00Z' }
            )
        }
        (Get-MostRecentSession -State $state).name | Should -Be 'new'
    }
}

Describe 'Register-Session' {
    It 'records a tmux-backed launch-pad session with no worktree' {
        $state = @{}
        $rec = Register-Session -State $state -Project 'acme' -Name 'feat-1234'
        $rec.project | Should -Be 'acme'
        $rec.tmux    | Should -Be 'cl-acme-feat-1234'
        $rec.ContainsKey('worktreePath') | Should -BeFalse
        $rec.ContainsKey('branch')       | Should -BeFalse
        @($state.sessions).Count | Should -Be 1
    }

    It 'stamps type=host only for host sessions' {
        $state = @{}
        (Register-Session -State $state -Project 'p' -Name 's' -Type 'distro').ContainsKey('type') | Should -BeFalse
        $state2 = @{}
        (Register-Session -State $state2 -Project 'p' -Name 's' -Type 'host').type | Should -Be 'host'
    }

    It 'rejects names with tmux-special characters' {
        { Register-Session -State @{} -Project 'p' -Name 'a.b' } | Should -Throw
        { Register-Session -State @{} -Project 'p' -Name 'a:b' } | Should -Throw
        { Register-Session -State @{} -Project 'p' -Name 'a/b' } | Should -Throw
    }

    It 'refuses a duplicate session' {
        $state = @{}
        Register-Session -State $state -Project 'p' -Name 's' | Out-Null
        { Register-Session -State $state -Project 'p' -Name 's' } | Should -Throw '*already exists*'
    }
}

Describe 'Get-SessionMainCwd' {
    It 'returns the project main/ checkout for a new-model distro session' {
        $s = @{ project = 'acme'; name = 'feat'; tmux = 'cl-acme-feat' }
        Get-SessionMainCwd -Session $s -Home '/home/cp-acme' |
            Should -Be '/home/cp-acme/projects/acme/main'
    }

    It 'keeps opening a legacy worktreePath when present' {
        $s = @{ project = 'acme'; name = 'feat'; worktreePath = '/home/claude/projects/acme/sessions/feat' }
        Get-SessionMainCwd -Session $s | Should -Be '/home/claude/projects/acme/sessions/feat'
    }
}

Describe 'Get-SessionTmuxName' {
    It 'uses the stamped tmux field when present' {
        Get-SessionTmuxName -Session @{ project = 'p'; name = 's'; tmux = 'cl-custom' } | Should -Be 'cl-custom'
    }
    It 'derives the name for a legacy record' {
        Get-SessionTmuxName -Session @{ project = 'acme'; name = 'feat' } | Should -Be 'cl-acme-feat'
    }
}
