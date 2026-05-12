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
