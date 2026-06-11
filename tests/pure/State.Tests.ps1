# State.Tests.ps1 — pure tests for modules/State.psm1's stateless helpers.
# Initialize-State and Add-Recent don't touch the filesystem; Get-StatePath /
# Read-State / Write-State are exercised by distro tests where they belong.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\State.psm1') -Force
}

Describe 'Initialize-State' {
    It 'returns a hashtable with schemaVersion=2 and provisioned=false' {
        $s = Initialize-State -DistroName 'test-x'
        $s.schemaVersion | Should -Be 2
        $s.distro        | Should -Be 'test-x'
        $s.provisioned   | Should -BeFalse
    }

    It 'sets createdAt and updatedAt to the same ISO-8601 timestamp' {
        $s = Initialize-State -DistroName 'test-x'
        $s.createdAt | Should -Match '^\d{4}-\d{2}-\d{2}T'
        $s.updatedAt | Should -Be $s.createdAt
    }

    It 'seeds an empty users map and the uid allocator at 30000' {
        $s = Initialize-State -DistroName 'test-x'
        $s.users               | Should -BeOfType [hashtable]
        $s.users.Count         | Should -Be 0
        $s.uidAllocator.next   | Should -Be 30000
    }
}

Describe 'Add-Recent' {
    It 'adds the first entry under the requested key' {
        $s = @{}
        Add-Recent -State $s -Key 'branches' -Value 'main'
        $s.recents.branches | Should -Be @('main')
    }

    It 'deduplicates with most-recent-wins ordering' {
        $s = @{}
        Add-Recent -State $s -Key 'branches' -Value 'main'
        Add-Recent -State $s -Key 'branches' -Value 'feat-1'
        Add-Recent -State $s -Key 'branches' -Value 'main'
        $s.recents.branches | Should -Be @('main', 'feat-1')
    }

    It 'trims to -Max entries (default 5)' {
        $s = @{}
        1..7 | ForEach-Object { Add-Recent -State $s -Key 'k' -Value "v$_" -Max 5 }
        $s.recents.k.Count | Should -Be 5
        $s.recents.k[0]    | Should -Be 'v7'
        $s.recents.k[-1]   | Should -Be 'v3'
    }
}
